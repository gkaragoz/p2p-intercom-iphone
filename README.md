# Intercom — iPhone'dan iPhone'a, internetsiz sesli konuşma

[![CI](https://github.com/gkaragoz/p2p-intercom-iphone/actions/workflows/ci.yml/badge.svg)](https://github.com/gkaragoz/p2p-intercom-iphone/actions/workflows/ci.yml)

İki iPhone'un **hücresel veri, internet ya da modem olmadan**, doğrudan cihazdan cihaza Wi‑Fi
(ya da aynı Wi‑Fi ağı) üzerinden, AirPods ile birbirine konuşmasını sağlayan telsiz / interkom
uygulaması. SwiftUI ile yazıldı, üçüncü parti bağımlılığı yok, ücretsiz bir Apple ID ile iki
telefona kurulabilir. Ekran kilitliyken de çalışır; kilit ekranında ve Dynamic Island'da bir
Canlı Etkinlik gösterir.

*(English summary at the bottom.)*

## İçindekiler

- [Neler yapar](#neler-yapar)
- [Nasıl çalışır](#nasıl-çalışır)
- [Gereksinimler](#gereksinimler)
- [Kurulum](#kurulum)
- [Uygulamayı ilk açış](#uygulamayı-ilk-açış)
- [Kullanım](#kullanım)
- [Canlı Etkinlik ve kilit ekranı denetimleri](#canlı-etkinlik-ve-kilit-ekranı-denetimleri)
- [Bildirimler ve bağlantı sesleri](#bildirimler-ve-bağlantı-sesleri)
- [Bağlantı motorları ve eşleştirme kodu](#bağlantı-motorları-ve-eşleştirme-kodu)
- [Arka plan davranışı ve sınırları](#arka-plan-davranışı-ve-sınırları)
- [Çevrimdışı (internetsiz) çalışma](#çevrimdışı-internetsiz-çalışma)
- [Cihazda henüz doğrulanmamış konular](#cihazda-henüz-doğrulanmamış-konular)
- [Test rehberi](#test-rehberi)
- [Sorun giderme](#sorun-giderme)
- [Geliştirme](#geliştirme)
- [English summary](#english-summary)

## Neler yapar

- **Otomatik başlama ve eşleşme:** Uygulamayı iki telefonda açmanız yeterli. İnterkom kendiliğinden
  başlar, telefonlar birbirini bulur ve bağlanır.
- **Kendiliğinden yeniden bağlanma:** Bağlantı koparsa uygulama vazgeçmeden yeniden dener (ilk
  denemeler hemen, sonra en fazla 2 saniye arayla). Durum kartında deneme sayısı ve geçen süre görünür.
- **Üç konuşma modu:**
  - **Bas konuş (PTT):** Büyük düğmeyi basılı tuttuğunuz sürece ses gider.
  - **Ses algılama (VOX):** Konuşmaya başlayınca otomatik gönderir; eşik ayarlanabilir. Sesin başı
    kırpılmasın diye, açılmadan önceki 40 ms de gönderilir.
  - **Açık hat:** Mikrofon sürekli açık, klasik interkom.
- **Kilit ekranı ve Dynamic Island:** Bağlantı durumu, karşı tarafın adı ve süre görünür. Buradan
  sessize alabilir, modu değiştirebilir ve PTT'yi basılı tutmadan açabilirsiniz.
- **Arka planda çalışma:** Ekran kilitliyken ya da başka bir uygulamadayken ses akışı ve bağlantı sürer.
  Bağlantı kopunca/gelince ya da ses duraklayınca sessiz bildirim ve kulağa kısa bir ton gelir.
- **Düşük gecikme:** 20 ms'lik sıkıştırılmamış PCM kareleri UDP üzerinden gider. Mikrofon, gerçek
  zamanlı bir `AVAudioSinkNode` ile alınır. Alıcıdaki oynatma tamponu, ölçülen ağ dalgalanmasına göre
  kendini 40–200 ms arasında ayarlar.
- **Şifreli bağlantı:** Ağ motoru her paketi ChaChaPoly ile şifreler. İsteğe bağlı eşleştirme kodu
  yalnızca aynı kodu kullanan telefonların bağlanmasını sağlar.
- **AirPods desteği:** AirPods sapından sessize alma hareketi uygulamadaki sessiz düğmesiyle eşlenir
  (cihazda doğrulanması gerekiyor, [bkz.](#cihazda-henüz-doğrulanmamış-konular)).
- **Tanılama:** RTT, bağlantı yolu (Doğrudan Wi‑Fi / Wi‑Fi ağı), tampon istatistikleri, ayrıntılı
  gecikme dökümü ve tahmini ağızdan kulağa gecikme.
- **Türkçe ve İngilizce arayüz** (uygulama ve Canlı Etkinlik).

## Nasıl çalışır

```
iPhone A (gönderen)                                   iPhone B (alan)

Mikrofon (AirPods / dahili)                            AirPods / hoparlör
  │ AVAudioSinkNode (gerçek zamanlı iş parçacığı)        ▲ AVAudioSourceNode (gerçek zamanlı)
  ▼ CaptureRing (kilitsiz halka tampon)                  │ PlaybackRenderer (+ bağlantı tonları)
  ▼ CaptureWorker: AVAudioConverter → 16 kHz Int16       │ JitterBuffer (uyarlanır hedef 40–200 ms)
  ▼ 20 ms kare → TransmitGate (PTT / VOX / açık hat)     │ ChaChaPoly aç + tekrar penceresi
  ▼ AudioPacket → NetDatagram, ChaChaPoly ile mühürle    │ NetDatagram çöz
  └──────────── UDP (NWConnection, .interactiveVoice) ───┘
                Bonjour keşif: _intercom-nw._udp
                Doğrudan Wi‑Fi (AWDL) veya aynı Wi‑Fi ağı; hücresel yasak
```

| Katman | Klasör | Görev |
|---|---|---|
| **Core** (platformdan bağımsız) | `Intercom/Core/` | Saf, saati dışarıdan verilen ve birim testli mantık: `LinkStateMachine` (Ağ motorunun el sıkışma, canlılık, yeniden bağlanma, tarayıcı politikası), `NetDatagram` hat biçimi, `JitterBuffer` + `PlayoutDelayEstimator`, `AudioRecoveryMachine` (ses kesinti politikası), `SessionStatusMachine` (durum, uyarı, ton ve bildirim kararları), `UpdateThrottle`, `CueTone`. Linux'ta `swift test` ile test edilir. |
| **Audio** | `Intercom/Audio/` | `AVAudioSession` (`.playAndRecord` + `.voiceChat` + Bluetooth HFP + hoparlör), `AVAudioEngine` grafiği, sink/tap kaydı, oynatma, gözetleyici (watchdog), sistem sessize alma durumu, gecikme sayaçları. |
| **Networking** | `Intercom/Networking/` | `NetworkTransport` (varsayılan; Network framework), `MultipeerTransport` (eski motor), `PairingKey` + `ChaChaPolySealer` (anahtar türetme ve şifreleme), kurulum kimliği, Wi‑Fi durumu. |
| **Model** | `Intercom/Model/` | `IntercomController` (ana aktör, tek örnek), `AudioPipeline`, `AppSettings`, `LocalNotifier`, `BackgroundActivity`. |
| **LiveActivity** | `Intercom/LiveActivity/` | `LiveActivityCoordinator`: denetleyici durumunu Canlı Etkinliğe yansıtır, düğmelerin intent'lerini çalıştırır. |
| **Views** | `Intercom/Views/` | SwiftUI ekranları. |
| **Shared** | `Shared/` | Uygulama ve uzantının ortak kodu: `IntercomActivityAttributes`, `SetMutedIntent` / `SetTransmitModeIntent` / `SetTalkLatchIntent`. |
| **Uzantı** | `IntercomLiveActivity/` | WidgetKit uzantısı: kilit ekranı ve Dynamic Island görünümleri. |

Proje Xcode'un dosya sistemiyle eşitlenen klasörlerini kullanır: `Intercom/`, `IntercomLiveActivity/`
ya da `Shared/` altına eklenen her dosya pbxproj düzenlemeden ilgili hedefe girer.

Ses **sıkıştırılmadan** (PCM 16 kHz, ≈256 kbit/s) gönderilir; Wi‑Fi için bu rahatça yeterlidir ve
kodek gecikmesi yoktur. AirPods'un mikrofonu kullanıldığında Bluetooth zaten HFP profiline (16 kHz
geniş bant) geçtiği için daha yüksek örnekleme hızı bir şey kazandırmaz.

## Gereksinimler

- macOS üzerinde **Xcode 26** (geliştirme Xcode 26.0.1 ile yapıldı; proje biçimi en az Xcode 16 ister).
- **iOS 18.0+** çalıştıran iki iPhone. Kilit ekranı düğmeleri ve `AVAudioApplication` sessize alma
  bunu gerektirir. Geliştirme telefonları iOS 26.6.1 kullanıyor.
- Ücretsiz bir **Apple ID** (ücretli geliştirici hesabı gerekmez). İkinci telefon için ikinci bir
  ücretsiz Apple ID önerilir ([bkz.](#cihaz-kotası-hatası-ve-ikinci-telefon)).
- İki telefonda **Wi‑Fi açık** olmalı. Bir ağa katılmaları, internet ya da modem gerekmez.
  Bluetooth bağlantı için kullanılmaz; yalnızca AirPods için gerekir.

## Kurulum

### Şemalar ve yapılandırmalar

Depoda iki paylaşılan şema var. Her biri uygulamayı ve Canlı Etkinlik uzantısını birlikte derleyip
uzantıyı uygulamanın içine gömer:

| Şema | Run / Profile / Archive | Test / Analyze | `APP_BUNDLE_ID` | `DEVELOPMENT_TEAM` |
|---|---|---|---|---|
| `Intercom` (1. telefon) | `Release` | `Debug` | `com.gkaragoz.p2pintercom` | `YLKU8294NU` |
| `Intercom (Phone 2)` (2. telefon) | `Release-Phone2` | `Debug-Phone2` | `com.gkaragoz.p2pintercom2` | `MSBZ3RN6Q9` |

- Uygulamanın bundle kimliği `$(APP_BUNDLE_ID)`, uzantınınki `$(APP_BUNDLE_ID).LiveActivity` olarak
  türetilir. Bu yüzden **yalnızca `APP_BUNDLE_ID`'yi değiştirin**; `PRODUCT_BUNDLE_IDENTIFIER`'ı asla
  doğrudan ezmeyin. Komut satırında ezilirse uzantı da uygulamayla aynı kimliği alır ve kurulum
  reddedilir.
- Run eylemi bilerek **Release** kullanır: gerçek zamanlı ses döngüleri optimizasyonsuz (`-Onone`)
  derlemede anlamlı ölçülemez.
- Yapılandırmalar ürünleri ayrı klasörlere koyar: `Release-iphoneos`, `Release-Phone2-iphoneos`,
  `Debug-iphonesimulator` gibi.

### Xcode ile kurulum

1. Depoyu klonlayın ve `Intercom.xcodeproj` dosyasını Xcode ile açın.
2. **Xcode ▸ Settings ▸ Accounts** bölümünden Apple ID'nizi ekleyin (yoksa).
3. iPhone'u kabloyla Mac'e bağlayın, cihazda **Bu Bilgisayara Güven** deyin. Telefonda
   **Ayarlar ▸ Gizlilik ve Güvenlik ▸ Geliştirici Modu**'nu açın (telefon yeniden başlar).
4. Araç çubuğundan şemayı (`Intercom` ya da `Intercom (Phone 2)`) ve hedef cihaz olarak iPhone'u
   seçip **Run (⌘R)** yapın.
5. İlk açılışta iOS uygulamayı engeller. Telefonda **Ayarlar ▸ Genel ▸ VPN ve Aygıt Yönetimi**
   ▸ geliştirici uygulaması (Apple ID'niz) ▸ **Güven** deyin.

> **Dikkat: Signing & Capabilities ekranı.** Orada Team ya da Bundle Identifier değiştirmek, hedef
> düzeyinde sabit değerler yazar. Bunlar yapılandırma başına ayarları ezer: iki telefonun ekip ve
> kimlikleri birbirine karışır, uzantının kimliği uygulamayla uyumsuz kalabilir. Kendi hesabınız için
> bunun yerine aşağıdaki gibi `APP_BUNDLE_ID` ve `DEVELOPMENT_TEAM`'i değiştirin. Yanlışlıkla
> değiştirdiyseniz hedefin **Build Settings ▸ Levels** görünümünde hedef düzeyindeki Development
> Team değerini silin. Product Bundle Identifier'ı uygulamada `$(APP_BUNDLE_ID)`, uzantıda
> `$(APP_BUNDLE_ID).LiveActivity` olarak geri yazın. Ya da `git checkout Intercom.xcodeproj/project.pbxproj`.

### Kendi Apple ID'nizle kurulum

Yapılandırmalardaki ekip ve kimlikler bu deponun sahibine ait. Kendi hesabınızla kurmanın iki yolu var:

- **Kalıcı olarak:** Xcode'da **Intercom projesi** (hedef değil) ▸ **Build Settings** ▸ *User-Defined*
  altındaki `APP_BUNDLE_ID` değerini ve **Development Team** ayarını her yapılandırma için
  değiştirin. Örneğin `Debug`/`Release` için `com.adiniz.intercom`, `Debug-Phone2`/`Release-Phone2`
  için `com.adiniz.intercom2`.
- **Yalnızca komut satırında:** aşağıdaki tarifte `APP_BUNDLE_ID` ve `DEVELOPMENT_TEAM`'i ezin.

**Team ID'yi bulmak:** en kolayı Build Settings'teki **Development Team** açılır listesinden ekibi adıyla
seçmektir; Xcode doğru kimliği kendisi yazar (sonra `project.pbxproj` içindeki `DEVELOPMENT_TEAM`'den
okuyabilirsiniz). Komut satırında Team ID, geliştirme sertifikasının `OU=` alanıdır:

```bash
security find-certificate -a -c "Apple Development: siz@example.com" -p | openssl x509 -noout -subject
# subject=UID=…, CN=Apple Development: siz@example.com (876HS9F6Q2), OU=YLKU8294NU, …
# Team ID = OU= değeri (burada YLKU8294NU); parantez içindeki 876HS9F6Q2 değil
```

`security find-identity -v -p codesigning` çıktısındaki **parantez içi değer Team ID değildir**
(sertifikanın kendi kimliğidir); onu `DEVELOPMENT_TEAM`'e yazarsanız imzalama "No Account for Team"
hatasıyla başarısız olur. İndirilmiş profillerden okumak için aşağıdaki
[cihaz kotası](#cihaz-kotası-hatası-ve-ikinci-telefon) döngüsü de ekip adının yanında Team ID'yi yazar.

### Komut satırıyla kurulum

```bash
# Telefonların UDID'sini öğrenin (parantez içindeki değer, ör. 00008120-001C…). xcodebuild, devicectl
# ve log collect bu UDID'yi kabul eder; `devicectl list devices`'ın gösterdiği kimlik xcodebuild'de çalışmayabilir.
xcrun xctrace list devices

# 1. telefon: Intercom şeması, Release
xcodebuild -project Intercom.xcodeproj -scheme Intercom -configuration Release \
  -destination 'id=<UDID_1>' -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -derivedDataPath build/phone1 build
xcrun devicectl device install app --device <UDID_1> \
  build/phone1/Build/Products/Release-iphoneos/Intercom.app

# 2. telefon: Intercom (Phone 2) şeması, Release-Phone2
xcodebuild -project Intercom.xcodeproj -scheme 'Intercom (Phone 2)' -configuration Release-Phone2 \
  -destination 'id=<UDID_2>' -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  -derivedDataPath build/phone2 build
xcrun devicectl device install app --device <UDID_2> \
  build/phone2/Build/Products/Release-Phone2-iphoneos/Intercom.app

# Kendi hesabınızla: kimliği ve ekibi ezin (PRODUCT_BUNDLE_IDENTIFIER'ı değil!)
xcodebuild -project Intercom.xcodeproj -scheme Intercom -configuration Release \
  -destination 'id=<UDID>' -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
  APP_BUNDLE_ID=com.adiniz.intercom DEVELOPMENT_TEAM=<TEAM_ID> \
  -derivedDataPath build/mine build
```

`build/` klasörü `.gitignore` içindedir.

### Ücretsiz hesap sınırları

Apple'ın ücretsiz "Personal Team" için belgelediği sınırlar:

| Sınır | Anlamı |
|---|---|
| **7 gün** | Ücretsiz hesapla imzalanan uygulama 7 gün sonra açılmaz. Telefonu tekrar Mac'e bağlayıp **Run** yapmak yeterlidir; ayarlar ve veriler silinmez. Uzantının profili de 7 günde dolar; uygulamayı ve uzantıyı her zaman aynı şemayla birlikte kurun. |
| **3 cihaz** | Aynı anda en fazla 3 cihaz kayıtlı olabilir. Bu kayıtların 7 gün sonra düşmesi beklenir ama pratikte güvenilmez. Kota dolduğunda Xcode şu hatayı verir: *"Your development team has reached the maximum number of registered iPhone devices."* Çözüm için aşağıdaki bölüme bakın. |
| **3 uygulama / cihaz** | Bir cihazda aynı anda en fazla 3 geliştirici uygulaması kurulu olabilir. Xcode "Maximum number of apps for free development profiles has been reached" derse o cihazdan başka bir geliştirici uygulamasını silin. Gömülü uzantının bu sayıya ayrıca girip girmediği doğrulanmadı. |
| **10 App ID / 7 gün** | Her yeni bundle identifier bir App ID harcar. Canlı Etkinlik uzantısı ayrı bir App ID'dir (`….LiveActivity`), yani her ekip ilk kurulumda **iki** App ID harcar. `APP_BUNDLE_ID`'yi gereksiz yere değiştirmeyin. |
| Push, iCloud, App Groups, TestFlight | Ücretsiz hesapta yok; bu uygulama bunları **kullanmaz**. Mikrofon, yerel ağ (Bonjour), arka plan sesi, yerel bildirimler ve Canlı Etkinlikler Info.plist anahtarıyla açılır, kısıtlı yetki (entitlement) istemez; bu yüzden ücretsiz hesapta çalışmaları beklenir (Canlı Etkinlik uzantısının ücretsiz ekiple imzalanması henüz telefonda denenmedi). |

### Cihaz kotası hatası ve ikinci telefon

Birinci telefona kurduktan sonra ikincisinde şu hatayı alırsanız:

```
Your development team has reached the maximum number of registered iPhone devices.
```

Apple ID'nizin 3 cihazlık kotası dolmuştur. Birkaç yol var.

**Çözüm A: bekleyin (bedava ama güvenilmez).** Apple'ın belgesi cihaz kayıtlarının 7 gün sonra düştüğünü söyler ve destek mühendislerinin bu hataya verdiği resmî cevap "bekleyin" olur. Ancak aylardır yeni cihaz kaydetmemiş olmasına rağmen kotası dolu kalan kullanıcılar var; bu düşme pratikte her zaman gerçekleşmiyor. Ücretsiz hesap cihaz listesini göremez ve silemez, çünkü o portal sayfası ücretli üyelik ister. Apple destek mühendisleri ücretsiz hesap için sıfırlama seçeneği olmadığını açıkça belirtiyor. Bu yüzden bu yola bel bağlamayın.

Ekibinize kayıtlı cihazları Mac'inizden görebilirsiniz. Aşağıdaki döngüyü olduğu gibi yapıştırın; Xcode'un indirdiği bütün profilleri tarar:

```bash
cd ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles
for p in *.mobileprovision; do
  plist=$(security cms -D -i "$p")
  name=$(printf '%s' "$plist" | plutil -extract Name raw -o - - 2>/dev/null)
  team=$(printf '%s' "$plist" | plutil -extract TeamName raw -o - - 2>/dev/null)
  teamid=$(printf '%s' "$plist" | plutil -extract TeamIdentifier.0 raw -o - - 2>/dev/null)
  echo "== $name  [$team $teamid]"
  printf '%s' "$plist" | plutil -extract ProvisionedDevices json -o - - 2>/dev/null \
    || echo "   (cihaz listesi yok)"
done
```

Çıkan UDID listesi kotayı neyin doldurduğunu gösterir. Sadece iPhone'lar değil, iPad'ler ve telefonunuza eşli Apple Watch gibi Xcode'un kaydettiği her cihaz sayılır.

**Çıktıyı okurken dikkat:** bir ekibin bütün profilleri aynı cihaz listesini taşır. Yani dört farklı uygulamanın profilinde aynı UDID'leri görmeniz dört ayrı kayıt olduğu anlamına gelmez. Önemli olan **benzersiz UDID sayısıdır**; kotayı o belirler. Listedeki UDID'lerin baş kısmı cihazın yonga kuşağını gösterir, dolayısıyla farklı başlangıçlar farklı fiziksel cihazlar demektir. Bugün elinizde olan telefonların UDID'lerini `xcrun xctrace list devices` ile görüp listeyle karşılaştırabilir, geri kalanların artık kullanmadığınız eski cihazlar olduğunu doğrulayabilirsiniz. Ücretsiz hesapta bunları silemezsiniz, bu yüzden kota bir kez aşıldıysa kalıcıdır ve tek pratik çıkış Çözüm B'dir.

**Xcode'da görünmek ile ekibe kayıtlı olmak aynı şey değildir.** `xcrun xctrace list devices` Mac'inizin eşleşebildiği cihazları listeler; bir telefonun orada görünmesi geliştirici ekibinize kayıtlı olduğu anlamına gelmez. Run dediğinizde Xcode o cihazı ekibe kaydetmeye çalışır ve kota doluysa tam bu adımda hata verir. Bu yüzden telefon Xcode'da görünse bile kurulum başarısız olabilir.

Köşeli parantezdeki ekip adı ve Team ID de hangi profilin hangi ekibe ait olduğunu gösterir; ikinci bir Apple ID eklediğinizde burada iki farklı ekip görürsünüz (Çözüm B'nin 3. adımında gereken Team ID budur).

**Çözüm A2: Apple destekten silmelerini isteyin.** developer.apple.com üzerindeki *Contact Us* bağlantısından telefon görüşmesi talep edip, Xcode free provisioning ile test etmeye devam edebilmek için eski cihazların listeden çıkarılmasını isteyebilirsiniz. Bunun işe yaradığını bildiren kullanıcılar var, ama ücretsiz hesap için garanti değildir ve zaman alır.

**Çözüm B: ikinci telefon için ayrı bir ücretsiz Apple ID (önerilen, hemen çalışır).** Her Apple ID'nin kendi Personal Team'i ve kendi 3 cihazlık kotası vardır. Proje bunun için hazır: `Intercom (Phone 2)` şeması ikinci ekibi ve ikinci bundle kimliğini kullanır.

1. İkinci bir ücretsiz Apple ID oluşturun (ya da elinizdeki başka bir Apple ID'yi kullanın).
2. Xcode ▸ Settings ▸ Accounts'a onu da ekleyin.
3. Bu depo dışında kendi kurulumunuzsa `Debug-Phone2` / `Release-Phone2` yapılandırmalarında
   `DEVELOPMENT_TEAM`'i ikinci hesabın Team ID'si, `APP_BUNDLE_ID`'yi farklı bir kimlik yapın
   (ör. `com.adiniz.intercom2`). Bir App ID yalnızca tek bir ekibe kayıtlı olabilir.
4. İkinci telefonu bağlayın, **`Intercom (Phone 2)`** şemasını seçip Run yapın (ya da yukarıdaki
   komut satırı tarifini kullanın).

Bundle identifier'ların farklı olması uygulamanın çalışmasını **bozmaz**. Ağ motoru eşleri Bonjour servis tipiyle (`_intercom-nw._udp`), Multipeer motoru ise `p2p-intercom` servis tipiyle bulur; ikisi de iki kurulumda aynıdır. Bağlanmak için gereken tek şey aynı motor, aynı eşleştirme kodu ve aynı protokol sürümüdür.

> **Not:** AltStore, SideStore ve Sideloadly gibi sideload araçları da aynı ücretsiz hesap kotalarını kullanır. Aynı Apple ID ile aynı 3 cihaz duvarına çarparsınız; onlarda da çözüm ikinci bir Apple ID'dir.

## Uygulamayı ilk açış

Uygulamayı ilk kez **ekrandayken** açın; izin pencereleri yalnızca ön planda çıkabilir. Şu izinleri ister:

1. **Mikrofon:** karşı tarafın sizi duyabilmesi için. Reddedilirse interkom başlamaz.
2. **Yerel Ağ:** diğer iPhone'u bulabilmek için. Reddedilirse durum kartında *"Yerel Ağ erişimi kapalı"*
   uyarısı ve **Ayarlar'ı Aç** düğmesi çıkar. İzin henüz sorulmamışken uygulama arka plandaysa iOS
   pencere göstermeden reddeder.
3. **Bildirimler** (yalnızca uyarı, ses yok): arka planda bağlantı koptu / geldi haberleri için.
   İsteğe bağlıdır.

Canlı Etkinlik için izin penceresi çıkmaz; **Ayarlar ▸ Intercom ▸ Canlı Etkinlikler** ile kapatılabilir.

Sonrasında iki telefonda da uygulama açıkken interkom kendiliğinden başlar, **"Yakındaki iPhone'lar"**
listesinde karşı taraf görünür ve genellikle birkaç saniye içinde otomatik bağlanır. Bağlanmazsa
satırdaki **Bağlan** düğmesine dokunun.

## Kullanım

**Ana ekran**

- **Durum kartı:** *"Yakındaki iPhone'lar aranıyor…"*, *"Ahmet ile bağlanılıyor…"* (2. denemeden itibaren
  deneme sayısıyla), *"Ahmet ile bağlı"* (geçen süreyle), *"Ahmet ile yeniden bağlanılıyor…"* (süre ve
  deneme sayısıyla) ya da *"Ses duraklatıldı"*. Alt satırda ses çıkışı, bağlantı yolu çipi
  (**Doğrudan Wi‑Fi** = cihazdan cihaza, **Wi‑Fi ağı** = aynı modem üzerinden) ve gidiş‑dönüş süresi
  görünür. Düzeltilebilir sorunlar turuncu kutuda gösterilir: Yerel Ağ izni, farklı eşleştirme kodu
  (**Eşleştirme kodunu kontrol et**), uyumsuz sürüm, *"Wi‑Fi açık olmalı. Bir ağa veya internete bağlanmak gerekmez."*
- **Yakındaki iPhone'lar:** her eş için durum (*Bağlı · Doğrudan Wi‑Fi*, *Zayıf bağlantı…*,
  *Yeniden bağlanıyor · deneme 3*, *Diğer iPhone bağlantıyı kesti*, *Farklı eşleştirme kodu*…) ve
  **Bağlan** / **Bağlantıyı kes** düğmeleri. **Bağlantıyı kes**'e basan telefon, siz tekrar **Bağlan**'a
  basana ya da interkomu yeniden başlatana kadar otomatik bağlanmaz; karşı telefon da kendiliğinden
  aramaz.
- **Ses göstergeleri:** kendi ve karşı tarafın seviyesi.
- **Mod seçici:** Bas konuş / Ses algılama / Açık hat.
- **Büyük düğme:** PTT modunda basılı tutun. Diğer modlarda dokunmak sessize alır / açar. PTT kilit
  ekranından sabitlendiyse düğmede kilit simgesi ve *"Durdurmak için dokun"* yazar; bir dokunuş bırakır.
  VoiceOver'da *"Basılı tutmadan konuş"* eylemi de vardır.
- **Sessize al:** büyük düğmenin solundaki mikrofon düğmesi her modda geçerlidir.
- **Durdur** (sol üstteki güç simgesi): interkomu kapatır; Canlı Etkinlik de kapanır. Tekrar açmak için
  durum kartındaki **Başlat**.

**Ayarlar (⚙︎)**

| Bölüm | Ayar | Açıklama |
|---|---|---|
| Adınız | Ad | Karşı telefonda görünen isim. Değiştirmek bağlantıyı yeniden kurar. |
| Bağlantı | Bağlantı motoru | **Ağ (önerilen)** ya da **Multipeer (eski)**. İki telefon aynısını kullanmalı. |
| | Eşleştirme kodu (isteğe bağlı) | Yalnızca Ağ motorunda. İki telefonda aynı olmalı ([bkz.](#bağlantı-motorları-ve-eşleştirme-kodu)). |
| | Arka plan bildirimleri | Varsayılan açık. |
| | Bağlantı sesleri | Bağlandı / koptu / yeniden bağlandı tonları. Varsayılan açık. |
| Gönderim | Mod, Ses eşiği | VOX modunda gösterge, normal konuşurken işaretin sağına geçmeli, sessizken solunda kalmalı. |
| Ses | Otomatik oynatma tamponu | Varsayılan açık: tampon ölçülen dalgalanmaya göre 40–200 ms arasında ayarlanır. Kapatınca **Oynatma tamponu** kaydırıcısıyla 20–300 ms sabit değer seçilir. |
| | Kayıt | **Düşük gecikme** (varsayılan, `AVAudioSinkNode`) ya da **Uyumlu** (`installTap`). Uyumlu yalnızca mikrofon çalışmazsa; iOS tap'e 100 ms'lik parçalar verebilir. Düşük gecikme yolu başlamazsa ya da 1 saniye içinde ses gelmezse uygulama kendiliğinden tap'e geçer. |
| | Ses işleme | Yankı giderme ve otomatik kazanç. Varsayılan açık; yalnızca kulaklıkla kapatın. Değiştirmek ses motorunu yeniden kurar. |
| | Ses düzeyi, Ekranı açık tut | Ekranı açık tut varsayılan olarak **kapalıdır**: ses ekran kapalıyken de akar. |
| Tanılama | | Bağlantı motoru, ses çıkışı, giriş biçimi, karşı tarafın uygulama sürümü, gönderilen/alınan kare, gizlenen kayıp, geç gelen, tampon boşalması. |
| Gecikme | | Her saniye yenilenir: ses durumu, tahmini ağızdan kulağa gecikme, gidiş-dönüş, bağlantı yolu, oynatma hedefi ve derinliği, kayıt yolu, giriş biçimi, ses işleme, örnekleme hızı, G/Ç tamponu, donanım gecikmesi, geri çağrı başına örnek, kayıt aralığı ve gecikmesi, oynatma örnekleri, saniyedeki boşalma/gizleme/geç/kilit kaçırma sayıları. |

## Canlı Etkinlik ve kilit ekranı denetimleri

- İnterkom **ön planda başladığında** Canlı Etkinlik de başlar (iOS arka planda yeni etkinlik
  başlatmaya izin vermez). İnterkom durunca hemen kapanır. Uygulama çökerse ya da kaydırılarak
  kapatılırsa kalan etkinlik bir sonraki açılışta temizlenir.
- **Kilit ekranı:** durum simgesi ve başlık (*Aranıyor…*, *Bağlanıyor…*, *Bağlı*, *Yeniden bağlanıyor…*,
  *Ses duraklatıldı*), geçen süre, karşı tarafın adı ve durumu (*konuşuyor* / *sessizde* /
  *sesi duraklatıldı*), ses çıkışı ve RTT. Altında düğmeler:
  **[Sessize al / Sesi aç] [Bas konuş | Sesle | Açık hat] [Konuş]**. **Konuş** yalnızca PTT modunda
  görünür ve PTT'yi basılı tutmadan açar ("sabitleme"). Sabitleme en fazla **60 saniye** sürer;
  sessize alınca, mod değişince, bağlantı ya da ses kesilince de kendiliğinden kalkar.
- **Dynamic Island:** solda bağlantı simgesi (yeşil bağlı, turuncu yeniden bağlanıyor, gri arıyor),
  sağda öncelik sırasıyla karşı taraf konuşuyor > siz gönderiyorsunuz > sessizde > mod. Uzun basınca
  genişletilmiş görünümde aynı düğmeler çıkar.
- **Durdur düğmesi yoktur;** etkinliğe dokunmak uygulamayı açar.
- **Kilitli telefonda düğmeler için Face ID gerekebilir.** Apple, kilitli cihazda etkileşimli
  denetimlerin kimlik doğrulaması istediğini belgeliyor; iOS 26'da bu intent'lerin Face ID'siz çalışıp
  çalışmadığı doğrulanmadı. Cepteki telefonda sessize almak için AirPods sap hareketi daha pratiktir.
- **"Bir süredir güncellenmedi"** yazıyorsa uygulama 15 dakikadır etkinliği güncelleyemedi (her
  güncelleme 15 dakikalık bir bayatlama tarihi taşır, uygulama bunu 10 dakikada bir yeniler).
  Uygulamayı açın; açılışta durum yeniden gönderilir.
- iOS her Canlı Etkinliği **8 saat** sonra bitirir. Uygulama 7 saatten eski ya da sistemin bitirdiği
  etkinliği, interkom çalışırken uygulama ön plana geldiğinde yeniler.
- Etkinliği **kaydırarak kapatırsanız**, interkomu durdurup yeniden başlatana kadar geri gelmez.
- Etkinlik hiç görünmüyorsa: **Ayarlar ▸ Intercom ▸ Canlı Etkinlikler** ve
  **Ayarlar ▸ Face ID ve Parola ▸ Kilitliyken Erişime İzin Ver ▸ Canlı Etkinlikler** açık olmalı.
- Güncellemeler sınırlıdır: bağlantı, sessiz, mod ve sabitleme değişiklikleri en fazla saniyede bir;
  "kim konuşuyor", ses çıkışı, deneme sayısı ve RTT en fazla 5 saniyede bir; ses göstergeleri hiç
  gönderilmez.
- Tanı için günlük kategorileri: `liveactivity` (her istek, güncelleme, bitiş ve hata, uygulamanın
  ön/arka plan durumuyla) ve `liveactivity.intent` (kilit ekranı düğmeleri).

## Bildirimler ve bağlantı sesleri

**Yerel bildirimler** yalnızca uygulama **ekranda değilken** gösterilir ve **sessizdir** (bildirim sesi
sesli görüşmeyi bölmesin diye). İnternet, push ya da ücretli hesap gerekmez.

| Bildirim | Ne zaman |
|---|---|
| *Bağlantı koptu – Ahmet ile yeniden bağlanılıyor* | Beklenmeyen kopuş 3 saniyeden uzun sürerse (hızlı toparlanan kopuşlar bildirim üretmez). |
| *Ahmet ile yeniden bağlanıldı* | Bağlantı geri gelince; öncekinin yerine geçer. |
| *Ses duraklatıldı – devam etmek için Intercom'u açın* | iOS sesi arka planda yeniden başlatmayı reddettiğinde hemen, ya da arka planda 5 saniyeden uzun süren bir ses kesintisinde. |

Bilerek yapılan kapanışlar (Durdur, Bağlantıyı kes, karşı tarafın Bağlantıyı kes'i, farklı kod ya da
sürüm) bildirim üretmez. Uygulama ekrana gelince bildirimler kaldırılır.

**Bağlantı sesleri** interkomun kendi ses çıkışına karışan kısa tonlardır: bağlandı (iki yükselen
nota), koptu (iki alçalan nota), yeniden bağlandı (üç yükselen nota). Yalnızca ses çalışırken çalınır.
Bağlantının kısa bir an zayıflaması (*Zayıf bağlantı…*) ton çaldırmaz.

## Bağlantı motorları ve eşleştirme kodu

| | **Ağ (önerilen, varsayılan)** | **Multipeer (eski)** |
|---|---|---|
| Altyapı | Network framework: `NWListener` + `NWBrowser` (Bonjour `_intercom-nw._udp`), eş başına bir UDP `NWConnection` | MultipeerConnectivity (`p2p-intercom`) |
| Yol | Doğrudan Wi‑Fi (AWDL) veya aynı Wi‑Fi ağı; hücresel yasak; yol çipi kesin | Çerçeve seçer; yol görünmez |
| Kim arar | Kurulum kimliği küçük olan hemen, diğeri 750 ms sonra; çakışmalar deterministik çözülür | Ada, sonra kurulum kimliğine göre seçim |
| Canlılık | Ön planda 200 ms, arka planda 500 ms kalp atışı; 0,6 s sessizlikte "zayıf", 2 s'de (arka planda 3 s) kopmuş sayılır | 1 s'de bir ping; ~4 s sessizlikte kopmuş sayılır |
| Yeniden deneme | 0 / 0,25 / 0,5 / 1 / 2 s (±%20), asla vazgeçmez; ön plana dönüşte ve ağ yolu değişince hemen | 1 / 2 / 3 / 5 s (±%20), asla vazgeçmez |
| Şifreleme | Bağlantı başına yön başına ChaChaPoly anahtarı, tekrar saldırısı penceresi | `MCSession` şifrelemesi (zorunlu) |
| Eşleştirme kodu | Var | Yok |
| Arka plan | Uygulama askıya alınmadıkça çalışır | Apple, arka planda oturumların kapandığını belgeliyor; desteklenmez |

MultipeerConnectivity iOS 27'de kullanımdan kaldırılıyor; yalnızca Ağ motoruyla sorun yaşarsanız
karşılaştırma için tutuluyor.

**Eşleştirme kodu** (Ayarlar ▸ Bağlantı, yalnızca Ağ motoru):

- İki telefonda **aynı** olmalı. Baştaki/sondaki boşluklar yok sayılır, büyük/küçük harf fark eder.
  Değiştirince bağlantı yaklaşık 1 saniye sonra yeni anahtarla yeniden kurulur.
- **Boş bırakılırsa** uygulamaya gömülü bir anahtar kullanılır: kutudan çıktığı gibi çalışır ve paketler
  bozulmaya karşı korunur, ama bu uygulamayı çalıştıran herkes dinleyebilir, yani gizlilik sağlamaz.
- Farklı kodlu telefonlar birbirini listede görür (*Farklı eşleştirme kodu*) ama otomatik bağlanmaz.
  Elle bağlanmaya çalışılırsa açıkça reddedilir ve durum kartında *"Diğer iPhone farklı bir eşleştirme
  kodu kullanıyor."* yazar.
- Anahtar koddan HKDF ile türetilir; bu yavaş bir parola özeti değildir. Ayrıca Bonjour kaydı koddan
  türetilen 32 bitlik bir etiket yayınlar. Bu yüzden **kısa bir kod, yakalanan paketlerden çevrimdışı
  kırılabilir. Gerçek gizlilik için uzun ve rastgele bir kod** (ör. 20+ karakter) kullanın.
- Kod telefonda `UserDefaults` içinde düz metin olarak saklanır (Keychain değil) ve ağa hiç gönderilmez.

İki telefon farklı protokol sürümü çalıştırıyorsa listede *Uyumsuz uygulama sürümü* görünür; iki telefona
da aynı derlemeyi kurun.

## Arka plan davranışı ve sınırları

- **İnterkom çalıştığı sürece ses girişi/çıkışı hiç durmaz:** PTT beklerken, sessizdeyken ya da eş
  yokken bile. Sessize alma ve PTT yalnızca neyin gönderileceğine karar verir. Uygulamayı arka planda
  canlı tutan budur (`audio` background mode). iOS, arka plandaki bir uygulamanın sesi yeniden
  başlatmasına izin vermez. Bunun görünen bedeli: turuncu mikrofon göstergesi sürekli yanar, AirPods
  oturum boyunca HFP profilinde kalır ve pil sürekli harcanır. Kullanmadığınızda **Durdur**'a basın.
- **Ekran kilitliyken / başka uygulamadayken:** bağlantı sürer; kalp atışları 500 ms'ye yavaşlar.
  Uygulamadan çıkınca basılı tutulan PTT bırakılır. Arka planda konuşmak için kilit ekranındaki
  **Konuş** (sabitleme), Ses algılama ya da Açık hat modunu kullanın.
- **Kopuşlar:** Uygulama arka planda da yeniden bağlanmayı sürdürür; bildirim ve ton çıkar, Canlı
  Etkinlik *Yeniden bağlanıyor…* gösterir (arka plan güncellemeleri için [bkz.](#cihazda-henüz-doğrulanmamış-konular)).
- **Ses kesintileri** (kabul edilen telefon araması, Siri, başka bir uygulamanın sesi) sesi durdurur:
  - Uygulama **ön plandaysa** artan aralıklarla (0,25 → 5 s) kendiliğinden yeniden dener. Durum
    kartındaki **Sesi devam ettir** hemen denetir.
  - Uygulama **arka plandaysa** iOS yeniden başlatmayı çoğu zaman reddeder (`!int` / `!rec` hataları).
    Uygulama denemeyi bırakır ve **"uygulamayı açın"** durumuna geçer. Karşı telefonda *"Diğer iPhone'un
    sesi duraklatıldı."*, kendi telefonunuzda *"Ses duraklatıldı – devam etmek için Intercom'u açın"*
    bildirimi ve Canlı Etkinlikte *Devam etmek için Intercom'u açın* görünür. **Uygulamayı açmak** sesi
    hemen geri getirir.
  - Kabul edilen bir aramadan sonra uygulama sistemden "bitti" haberi almadan askıya alınabilir. Bu
    durumda da 5 saniye sonra aynı bildirim gelir.
  - Uygulama `setPrefersNoInterruptionsFromSystemAlerts` ister: afiş olarak gelen bir aramanın zil sesi
    interkomu kesmemeli, yalnızca aramayı kabul etmek kesmeli. Tam ekran arama stilinde bu ayar
    etkisizdir. Cihazda doğrulanmadı.
- **Uygulama kaydırılarak kapatılırsa** karşı tarafa en iyi çabayla "ayrılıyorum" mesajı gönderilir ve
  Canlı Etkinlik kapatılmaya çalışılır.
- Arka plan davranışını **Xcode hata ayıklayıcısı bağlıyken test etmeyin:** hata ayıklayıcı askıya
  almayı engeller ve sonuçlar yanıltıcı olur ([Test rehberi](#arka-plan-testleri-hata-ayıklayıcı-olmadan)).

> **Neden CallKit / VoIP yok?** "Voice over IP" background mode'u PushKit/CallKit ile anlam kazanır.
> Arka planda kesintiden sonra kendiliğinden toparlanmayı sağlayabilecek bir CallKit denemesi yol
> haritasındadır, ama arama arayüzü getirir ve henüz denenmedi.

## Çevrimdışı (internetsiz) çalışma

- Uygulama hiçbir sunucuya, analitiğe ya da uzak ayara bağlanmaz. İnternete giden tek bağlantı
  Ayarlar ▸ Hakkında'daki, yalnızca dokununca açılan GitHub bağlantısıdır.
- **Wi‑Fi açık olmalı, bir ağa katılması gerekmez.** Telefonlar aynı ağda değilse (ya da hiçbir ağda
  değilse) Apple'ın doğrudan cihazdan cihaza Wi‑Fi'si (AWDL) kullanılır. Durum çipi o zaman
  **Doğrudan Wi‑Fi** gösterir.
- **Uçak modu** Wi‑Fi'yi kapatır; uçak modundayken Wi‑Fi'yi yeniden açın. Denetim Merkezi'nden Wi‑Fi'ye
  dokunmak yalnızca ağdan ayrılır, radyoyu açık bırakır; bu yeterlidir.
- **Ayarlar'dan Wi‑Fi tamamen kapalıysa bağlantı kurulamaz**, Bluetooth açık olsa bile. Bağlantı
  olmadan 5 saniye geçince uygulama *"Wi‑Fi açık olmalı…"* uyarısı gösterir. Bu uyarı Wi‑Fi açık ama
  bir ağa katılmamışken de çıkabilir (iOS bu ikisini ayırt ettirmez); o durumda bağlantı yine de
  kurulabilir.
- Yalnızca hücresel veri ile çalışmaz; hücresel arayüz bilerek yasaklanmıştır.
- İnterneti olmayan bir modem de çalışır. Cihazlar arası trafiği engelleyen (istemci yalıtımlı) misafir
  ağlarında uygulama, el sıkışma iki kez zaman aşımına uğrayınca o arayüzü atlayıp doğrudan Wi‑Fi dener.

## Cihazda henüz doğrulanmamış konular

Aşağıdakiler kodda ele alındı ve simülatörde ya da macOS'ta denendi, ama **gerçek iki iPhone ile
doğrulanmadı**. İlk testlerde özellikle bunlara bakın; günlükler bunları teşhis edecek şekilde yazıldı.

| Konu | Risk | Nasıl anlaşılır |
|---|---|---|
| **Arka planda Canlı Etkinlik güncellemeleri** | iOS, yalnızca arka plan sesiyle canlı tutulan bir uygulamanın `Activity.update` çağrılarını sessizce reddedebilir. Kilit ekranı eski durumda kalır, 15 dakika sonra *Bir süredir güncellenmedi* yazar. Ön plandan ve kilit ekranı düğmelerinden gelen güncellemelerin çalışması beklenir. | `liveactivity` kategorisindeki `update … app background` satırlarını kilit ekranıyla karşılaştırın; Console'da `liveactivitiesd` sürecinde *forbidden to update activity* arayın. |
| **Kilit ekranı düğmeleri** | Kilitli telefonda Face ID istenebilir; intent uygulamayı arka planda soğuk başlatırsa ses başlatılamaz. | `liveactivity.intent` satırları; soğuk başlatmada `intent … while the intercom is not running: ending activities`. |
| **AirPods sapıyla sessize alma** | Bu hareket iOS'ta CallKit kullanmayan bir `playAndRecord`/`voiceChat` uygulamasına sunulmayabilir; sunulursa `inputMuteStateChangeNotification` gelmeli ve uygulamanın sessiz düğmesi değişmeli. | AirPods ayarlarında sessize alma denetimi açıkken sapa basın; `audio` kategorisinde `system input mute changed` satırı ve ekrandaki düğme. |
| **Hücresel iPhone'larda ağsız Wi‑Fi ile doğrudan bağlantı** | iOS 26 için çözümsüz bir Apple forum bildirimi var: hücresel özellikli iPhone'lar, Wi‑Fi açık ama bir ağa katılmamışken doğrudan Wi‑Fi ile birbirini bulamayabiliyor (hücreselsiz cihazlar bulabiliyor). Network framework de bundan etkileniyor. İki test telefonunda da hücresel var. | [T3 testi](#çevrimdışı-test-listesi). Bulunamazsa geçici çözüm: iki telefonu internetsiz de olsa aynı Wi‑Fi ağına ya da modeme bağlamak. |
| **Kayıt tamponu boyutları** | Düşük gecikme (sink) yolu simülatörde 512 örnek/geri çağrı verdi; Uyumlu (tap) yol 4410 örneklik (100 ms) parçalar verdi. Cihazda, özellikle AirPods HFP rotasında tap parçaları daha büyük olabilir (200 ms bildirimi var). İstenen 10 ms G/Ç tamponunun ne kadarının verildiği de bilinmiyor. | Ayarlar ▸ Gecikme: *Kayıt yolu*, *Geri çağrı başına örnek*, *Kayıt gecikmesi*, *G/Ç tamponu*; `latency` günlük satırı. Hoparlör ve AirPods rotasında, iki kayıt modunda. |
| Arka planda bildirimler, kesinti sonrası akış | Arka planda gönderilen bildirimlerin kilit ekranında görünmesi, kabul edilen aramadan sonra karşı tarafa "ses duraklatıldı" bilgisinin gidebilmesi. | `notifications`, `background`, `controller` kategorileri. |
| Doğrudan Wi‑Fi'nin kilitli ekranda gecikmesi | Ekranlar kapalıyken AWDL'nin gecikme davranışı belgelenmemiş. | Kilitliyken `latency` satırındaki RTT ve boşalma sayıları. |

## Test rehberi

### Hazırlık ve günlük toplama

Uygulama her yaşam döngüsü geçişini `Logger(subsystem: "intercom")` ile kaydeder. Kategoriler:

| Kategori | İçerik |
|---|---|
| `controller` | Başlat/durdur, sahne fazı, bağlantı olayları, sessiz/mod/sabitleme |
| `health` | 5 saniyede bir özet: faz, bağlantı, yol, ses durumu, uygulama durumu, RTT, mod, tampon istatistikleri, uyarı |
| `transport.network` / `transport.multipeer` | Keşif, arama denemeleri, el sıkışma, yol, canlılık, kopma nedenleri |
| `audio`, `audio.session`, `audio.capture` | Motor durumu, kesintiler ve hata kodları, rota değişiklikleri, kayıt yolu |
| `latency` | 5 saniyede bir gecikme satırı (aşağıda) |
| `background`, `notifications` | Arka plan görev pencereleri, bildirimler |
| `liveactivity`, `liveactivity.intent` | Canlı Etkinlik istek/güncelleme/bitiş, kilit ekranı düğmeleri |

**A) Kabloyla, canlı konsol** (ön plan ve yeniden bağlanma testleri için):

```bash
xcrun xctrace list devices   # UDID
DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE=enable \
  xcrun devicectl device process launch --console --terminate-existing \
  --device <UDID> com.gkaragoz.p2pintercom 2>&1 | tee phone1-$(date +%Y%m%d-%H%M%S).log
```

İkinci telefon için `com.gkaragoz.p2pintercom2` kullanın. `DEVICECTL_CHILD_` ön eki ortam değişkenini
uygulamaya geçirir; `OS_ACTIVITY_DT_MODE` günlükleri konsola da yazdırır.

**B) Hata ayıklayıcısız** (arka plan testleri için): uygulamayı ana ekrandan açın, sonra:

- Mac'te **Console.app** ▸ soldan iPhone ▸ *Akışı Başlat*, arama: `subsystem:intercom`.
  Canlı Etkinlik reddi için ek olarak `process:liveactivitiesd`. **Eylem ▸ Bilgi Mesajlarını Dahil Et**
  (Action ▸ Include Info Messages) açık olsun; kapalıyken `info` düzeyindeki satırlar (tarayıcı, akış
  hazır/iptal, anahtarlama gibi ayrıntılar) görünmez.
- Ya da test bittikten **hemen sonra** kabloyla toplayın. iOS `info` satırlarını yalnızca bellekte tutar;
  beklerseniz bunlar kaybolur (bağlantı kopma nedenleri, geri çekilme süreleri ve arama denemeleri
  `notice` düzeyindedir ve diske yazılır):

  ```bash
  sudo log collect --device-udid <UDID> --last 30m --output ~/Desktop/phone1.logarchive
  log show ~/Desktop/phone1.logarchive --style compact --info \
    --predicate 'subsystem == "intercom"' > ~/Desktop/phone1-intercom.txt
  ```

Eş adları günlükte gizli (`<private>`) görünebilir; bu bilerek böyle.

**Genel hazırlık:** iki telefona aynı derleme (Release), iki telefonda Yerel Ağ izni ön planda verilmiş,
Mac'e kablosuz hata ayıklama **kullanmayın** (Wi‑Fi radyosunu paylaşır). Her test için not alın:
bağlandı mı, kaç saniyede, yol çipi, RTT ve 2 dakika konuşmadan sonra Tanılama'daki tampon boşalması /
gizlenen kayıp / geç gelen sayıları.

### Çevrimdışı test listesi

Önce iki telefonda **Ayarlar ▸ Gizlilik ve Güvenlik ▸ Uygulama Gizlilik Raporu**'nu açın; testlerden
sonra Intercom için hiçbir alan adı listelenmemeli.

| # | Koşul | Beklenen |
|---|---|---|
| T1 | Uçak modu açık, sonra Wi‑Fi açık (hiçbir ağa katılmadan), Bluetooth açık (AirPods için) | ~10 s içinde bağlanır, **Doğrudan Wi‑Fi**, temiz ses |
| T2 | Uçak modu açık, Wi‑Fi kapalı, Bluetooth açık | Bağlanmaz; 5 s sonra Wi‑Fi uyarısı (Bluetooth'un kullanılmadığının kanıtı) |
| **T3** | **Hücresel veri AÇIK, Wi‑Fi AÇIK ama hiçbir ağa katılmamış** (Ayarlar ▸ Wi‑Fi'de ağ seçili değil ya da ağ unutulmuş) | Bağlanmalı, **Doğrudan Wi‑Fi**. iOS 26 hatası nedeniyle bağlanmayabilir; sonucu mutlaka not edin ([bkz.](#cihazda-henüz-doğrulanmamış-konular)) |
| T4 | Hücresel açık, Wi‑Fi'den yalnızca Denetim Merkezi ile ayrılmış | Bağlanır |
| T5 | İki telefon da interneti olmayan bir modemde (WAN kablosu çıkarılmış) | Bağlanır; yol **Wi‑Fi ağı** ya da **Doğrudan Wi‑Fi** |
| T6 | A telefonu ev Wi‑Fi'sinde, B hiçbir ağda değil | Bağlanır, **Doğrudan Wi‑Fi** |
| T7 | İki telefon da istemci yalıtımlı misafir ağında | Bağlanır, belki daha yavaş; `transport.network`'te arayüzü atlayan arama satırı |
| T8 | Wi‑Fi ağı ve hücresel için Düşük Veri Modu açık | Değişiklik yok |

### Yeniden bağlanma testleri

| # | Adım | Beklenen |
|---|---|---|
| R1 | Konuşurken A'da Ayarlar'dan Wi‑Fi'yi 10 s kapatıp açın | *Yeniden bağlanıyor…* + koptu tonu, Wi‑Fi gelince birkaç saniyede bağlanır + yeniden bağlandı tonu, elle işlem yok |
| R2 | Birbirinden duyulmayacak kadar uzaklaşın, sonra geri dönün | Uzaktayken deneme sayısı artar; geri dönünce kendiliğinden bağlanır. Mesafeyi ve toparlanma süresini not edin |
| R3 | B'de uygulamayı kaydırarak kapatıp yeniden açın | A'da kopuş birkaç saniye içinde görülür; B açılınca kendiliğinden bağlanır |
| R4 | B'de **Durdur**, sonra **Başlat** | A yeniden bağlanmayı dener, B başlayınca bağlanır |
| R5 | A'da **Bağlantıyı kes** | İki taraf da kendiliğinden aramaz, bildirim yok; A'da **Bağlan** ile bağlanır |
| R6 | R1 ve R2'yi iki ekran da kilitliyken tekrarlayın | Bildirimler ve tonlar gelir, bağlantı kendiliğinden döner |
| R7 | Bir telefonda eşleştirme kodunu değiştirin | *Farklı eşleştirme kodu*, otomatik bağlanmaz; aynı koda dönünce bağlanır |

### Arka plan testleri (hata ayıklayıcı olmadan)

Xcode'un Run'ı hata ayıklayıcı bağlar ve uygulamanın askıya alınmasını engeller. Arka plan testleri için:
uygulamayı Xcode ya da `devicectl` ile **kurun**, sonra telefonda **ana ekrandan açın**, günlükleri
[B yöntemiyle](#hazırlık-ve-günlük-toplama) toplayın.

- İki ekran kilitli, 5 ve 30 dakika: PTT beklerken, sessizdeyken, Ses algılama ve Açık hat modunda.
  Bağlantı ve ses sürmeli; `health` satırlarında `app=background` görünmeli.
- Kilitliyken kilit ekranı düğmeleri: sessize al, mod, **Konuş** (60 s sonra kendiliğinden kalkmalı).
  Face ID istenip istenmediğini not edin.
- Kilitliyken karşı tarafın konuşması, bağlantının kopması: Canlı Etkinlik güncelleniyor mu?
  ([bkz.](#cihazda-henüz-doğrulanmamış-konular))
- Gelen arama: reddet / kabul et, afiş ve tam ekran stilinde, uygulama ön planda ve kilitliyken.
  Beklenen: kabul edince karşı tarafta *"Diğer iPhone'un sesi duraklatıldı."*, arka plandaysa
  *"Ses duraklatıldı – devam etmek için Intercom'u açın"*; uygulamayı açınca ses döner.
- Siri, alarm, Müzik uygulamasını başlatmak.
- Kilitliyken AirPods'u çıkarıp takmak, kutuyu açıp kapamak.
- **Ayarlar ▸ Geliştirici ▸ Reset Media Services** (ön planda ve arka planda).
- Uygulamayı kaydırarak kapatmak: karşı taraf hemen kopuş görmeli, Canlı Etkinlik kapanmalı
  (kapanmazsa bir sonraki açılışta temizlenmeli).

### Gecikme ölçümü

1. İki telefona **Release** derleme kurun (şemaların Run'ı zaten Release'tir), ikisi de aynı sürüm.
2. **Hızlı okuma:** Ayarlar ▸ Gecikme bölümünde *Tahmini ağızdan kulağa gecikme*, *Gidiş-dönüş*,
   *Oynatma hedefi*, *G/Ç tamponu*, *Donanım gecikmesi*, *Kayıt yolu*, *Geri çağrı başına örnek*,
   *Kayıt gecikmesi*. Tahmin; giriş gecikmesi + kayıt gecikmesi + RTT/2 + oynatma hedefi + G/Ç tamponu +
   çıkış gecikmesinin toplamıdır ve karşı telefonun kayıt yolunun bununla aynı olduğunu varsayar.
   Aynı değerler 5 saniyede bir `latency` kategorisine yazılır:
   `capture=sink in=48000Hz/1ch vp=on io=10.0ms(pref 10.0) … | jb target=… depth=… | rtt=…ms m2e=…ms`.
3. **Kayıt yolu karşılaştırması:** A telefonu Açık hat modunda sürekli konuşurken Kayıt'ı Düşük gecikme
   ve Uyumlu arasında değiştirin; hoparlör ve AirPods rotasında *Geri çağrı başına örnek* ve *Kayıt
   gecikmesi*ni not edin. B'de tampon boşalmasını izleyin.
4. **El çırpma (tık) testi, tek yön:** A Açık hat modunda; B sessizde, hoparlör orta seviyede; telefonlar
   en az 2 m ayrı. Mac'in mikrofonu (ör. Audacity, 48 kHz) A'nın alt mikrofonuna ve B'nin hoparlörüne eşit
   uzaklıkta. A'nın mikrofonunun ~5 cm yakınında 1,5 s arayla 20 keskin tık yapın. Dalga formunda her
   doğrudan tık ile B'den gelen kopyası arasındaki süreyi ölçün; medyan ve %95'lik değeri yazın. Yol
   farkı varsa metre başına ~2,9 ms çıkarın. Rolleri değiştirip tekrarlayın. AirPods için tıkı A'nın
   AirPods mikrofonunun yanında yapın, B'nin AirPods'unu küçük bir kap içinde Mac mikrofonuna tutun.
5. Ölçülen değeri uygulamanın tahminiyle karşılaştırın; fark, uygulamanın göremediği donanım ve ses
   işleme gecikmesidir. Bir kez de Ses işleme kapalı ölçün.
6. **Matris** (her biri ~2 dakika): {hoparlör, AirPods} × {aynı 5 GHz modem, Wi‑Fi açık ama ağsız
   (Doğrudan Wi‑Fi)} × {Ses işleme açık, kapalı}.
7. Hedef: hoparlör rotasında, modem üzerinden en fazla **150 ms** ağızdan kulağa (ITU‑T G.114).

## Sorun giderme

| Belirti | Yapılacak |
|---|---|
| Karşı taraf listede görünmüyor | İki telefonda da Wi‑Fi **açık** mı (ağa katılmak gerekmez)? Yerel Ağ izni **Ayarlar ▸ Gizlilik ve Güvenlik ▸ Yerel Ağ** altında açık mı? İki telefonda aynı **bağlantı motoru** mu seçili? Uygulama iki telefonda da açık ve interkom başlatılmış mı? Hücresel iPhone'da ağsız Wi‑Fi ile bulunamıyorsa iki telefonu aynı Wi‑Fi ağına bağlayın ([bkz.](#cihazda-henüz-doğrulanmamış-konular)). |
| *Farklı eşleştirme kodu* | Ayarlar ▸ Bağlantı ▸ Eşleştirme kodu iki telefonda harfi harfine aynı olmalı. |
| *Uyumsuz uygulama sürümü* | İki telefona da aynı derlemeyi kurun. 7 günlük profili dolan telefonda eski sürüm kalmış olabilir. |
| Görünüyor ama bağlanmıyor | Satırdaki **Bağlan**'a dokunun (daha önce **Bağlantıyı kes**'e basıldıysa gerekir). Cihazlar arası trafiği engelleyen ağlarda uygulama doğrudan Wi‑Fi'ye geçmeye çalışır; olmazsa o ağdan çıkın ya da ağı unutun ama **Wi‑Fi'yi kapatmayın**. |
| Sürekli *Yeniden bağlanıyor…* | Telefonları yaklaştırın. `transport.network` günlüğünde kopma nedenlerine bakın. |
| *Ses duraklatıldı* | Arama ya da başka bir uygulama sesi aldı. Uygulamayı açın ya da **Sesi devam ettir**'e dokunun. |
| Ses kesik kesik geliyor | *Otomatik oynatma tamponu* açık olsun; olmuyorsa kapatıp 100–200 ms sabit değer deneyin. Tanılama'da *Gizlenen kayıp* ve *Tampon boşalması* artıyorsa ağ zayıftır. Aynı ağdaki modem, doğrudan Wi‑Fi'den genellikle daha az dalgalanır. |
| Mikrofon hiç gitmiyor | Ayarlar ▸ Ses ▸ Kayıt: **Uyumlu** deneyin. Ayarlar ▸ Gecikme'de *Ses durumu* ve *Kayıt yolu*na bakın. |
| Yankı / uğultu | Kulaklık kullanın ya da sesi kısın. Ses işleme açık olmalı. İki telefon aynı odadaysa akustik geri besleme oluşabilir. |
| VOX hep açık / hiç açılmıyor | Ses eşiğini ayarlayın; gösterge işareti geçince gönderim başlar. |
| Canlı Etkinlik görünmüyor | İnterkomu uygulama açıkken başlatın (Durdur ▸ Başlat). Ayarlar ▸ Intercom ▸ Canlı Etkinlikler açık mı? Kaydırıp kapattıysanız interkomu yeniden başlatın. |
| Kilit ekranı *Bir süredir güncellenmedi* | Uygulamayı açın. Tekrarlıyorsa arka plan güncellemeleri reddediliyordur; `liveactivity` günlüğünü paylaşın. |
| "Mikrofon izni reddedildi" | **Ayarlar'ı Aç** düğmesiyle izni verin. |
| 7 gün sonra uygulama açılmıyor | Telefonu Mac'e bağlayıp aynı şemayla tekrar **Run** yapın. |
| "Multiple commands produce …appex/Info.plist" derleme hatası | Xcode pbxproj'yi yeniden yazıp uzantının `Info.plist` istisnasını düşürmüş olabilir: `git checkout Intercom.xcodeproj/project.pbxproj`. |

## Geliştirme

```bash
# Platformdan bağımsız çekirdeğin birim testleri (macOS veya Linux):
swift test

# iOS simülatör derlemesi (imzasız, paylaşılan şema):
xcodebuild -project Intercom.xcodeproj -scheme Intercom -configuration Debug \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  -derivedDataPath build/dd-sim -quiet build

# Cihaz derlemesi (imzasız, kurulamaz; yalnızca derlendiğini doğrular):
xcodebuild -project Intercom.xcodeproj -scheme Intercom -configuration Debug \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= \
  -derivedDataPath build/dd-dev -quiet build
```

- **Core** (`Intercom/Core`) yalnızca Foundation kullanır (`os` gibi modüller `#if canImport` ile
  korunur) ve Linux'ta derlenmelidir. Bağlantı mantığı iki `LinkStateMachine`'in simüle bir ağ üzerinden
  konuştuğu senaryolarla (eşzamanlı arama, yeniden başlatma, kayıp, bölünme, göç) ve rastgele kaos
  testleriyle sınanır.
- **Swift dil modu 5**; üçüncü parti bağımlılık yok.
- **Yerelleştirme:** uygulama `Intercom/Resources/Localizable.xcstrings`, uzantı
  `IntercomLiveActivity/Localizable.xcstrings`. Her yeni metnin Türkçesi eklenmeli. CI, kataloglardaki her
  anahtarın Türkçesini ve simülatör derlemesinden sonra koddaki her metnin katalogda olduğunu denetler.
  Anahtarlar `extractionState: manual` ile elle tutulur; `xcodebuild` kataloğa yeni anahtar yazmaz.
- **Canlı Etkinlik önizlemeleri:** `IntercomLiveActivity/IntercomLiveActivityPreviews.swift`: kilit
  ekranı ve Dynamic Island'ın üç hali. Dosya `#if DEBUG` içindedir, önizleme kanvası da `-Onone` ister;
  paylaşılan şemaların Run eylemi ise Release'tir. Kanvası kullanmak için geçici olarak
  **Product ▸ Scheme ▸ Edit Scheme ▸ Run ▸ Build Configuration**'ı `Debug` (ya da `Debug-Phone2`) yapın,
  `Intercom` şeması seçiliyken dosyayı açın. İşiniz bitince Release'e geri alın: bu değişikliği
  paylaşılan şemaya commit etmeyin ve telefonlara Debug derleme kurmayın.

**GitHub Actions** (`.github/workflows/ci.yml`) her push'ta:

- Linux'ta (`swift:6.0`) çekirdek testlerini çalıştırır;
- macOS'ta testleri, `xcodebuild -list` ile hedef/yapılandırma/şema kontrolünü, çeviri kataloglarının
  eksiksizliğini, `Intercom` şemasıyla simülatör derlemesini (ardından derleyicinin koddan çıkardığı her
  metnin katalogda olduğunu) ve `Intercom (Phone 2)` şemasıyla imzasız Release-Phone2 cihaz derlemesini
  çalıştırır;
- iki derlemede de `IntercomLiveActivityExtension.appex`'in uygulamaya gömüldüğünü, uzantı noktasını ve
  uzantı kimliğinin `<uygulama kimliği>.LiveActivity` olduğunu doğrular.

### Hat protokolü

**Ağ motoru** (`Intercom/Core/NetDatagram.swift`): her UDP datagramı 14 baytlık bir başlıkla başlar:
`"IN"` + sürüm (2) + tür + bayraklar (mühürlü, konuşuyor, sessiz, mod, ses duraklatıldı, gönderen arka
planda) + ayrılmış + bağlantı kimliği (UInt32) + gönderen dönemi (UInt32, her başlatmada rastgele).
Türler: `hello`, `helloAck`, `heartbeat`, `control`, `controlAck`, `audio`, `bye`.

- `hello` / `helloAck` açık gönderilir (anahtarlar onların taşıdığı nonce'lardan türetilir) ve eşleştirme
  kodundan türetilen HMAC etiketiyle doğrulanır.
- Diğer her şey ChaChaPoly ile mühürlenir: başlık ek doğrulanmış veridir, nonce = yön ‖ dönem ‖ sayaç,
  64'lük tekrar penceresi.
- `audio` yükü değişmeyen `AudioPacket` biçimidir: `"IC"` + sürüm + kodek + sıra no (UInt16) + zaman
  damgası (UInt32, kayıt örnek saati) + örnek sayısı (UInt16) + Int16 LE örnekler (20 ms = 320 örnek).
- `control` güvenilir iletilir (250 ms'de bir yeniden gönderim, onay, tekrar süzme).

Bonjour TXT kaydı: `v` (protokol), `id` (kurulum kimliği), `n` (ad), `k` (anahtar etiketi), `c` (yetenekler).

**Multipeer motoru** (`Intercom/Core/MultipeerFrame.swift`): her `MCSession.send` bir etiket baytıyla
başlar: `0xA1` ses (`.unreliable`), `0xC1` JSON kontrol mesajı (`.reliable`), `0xB1` bye,
`0xB2`/`0xB3` ping/pong (durum baytıyla), `0xB4` durum. Keşif bilgisi: `token` (kurulum kimliği), `name`, `v`,
`epoch` (her başlatmada rastgele). Davet bağlamı (`MultipeerInvitation`): `0xD1` bağlan ya da `0xD2` bye +
dönem (UInt32) + kurulum kimliği. *Bağlantıyı kes*'e basan telefon, bye çerçevesi yolda kaybolsa bile karşı
taraf yeniden aramayı bıraksın diye, reddettiği davetleri (eş başına en fazla 5 saniyede bir) her zaman
reddedilen bir bye davetiyle yanıtlar. Karşı tarafın bağlantı kesmesi yalnızca onu gönderen örnek için
geçerlidir: o telefon interkomu yeniden başlatırsa (yeni `epoch`) otomatik bağlanma geri gelir.

### Jitter tamponu

`Intercom/Core/JitterBuffer.swift` + `PlayoutDelayEstimator.swift`:

- Sırasız paketleri sıralar, kayıp kareyi gizler, taşarsa en eski kareleri atar.
- **Otomatik hedef:** her konuşma başında yeniden sabitlenen gecikme ölçümünün %95'lik değeri + bir kare
  + gözlenen oynatma isteği + 10 ms pay; 40–200 ms arasında. Ani artışa hemen uyar, yavaşça geri iner.
- **Kırpma:** fazla derinlik 500 ms sürerse önce sessiz kareler atılır. Sesli kareler yalnızca 1 s
  boyunca 2+ kare fazlalık varsa, 200 ms'de en fazla bir tane ve 40 örneklik geçişle atılır.
- **Gerçek zamanlı güvenlik:** tüm kareler önceden ayrılmış tek bir blokta durur; oynatma tarafı
  yalnızca `tryLock` dener, kilit meşgulse sessizlik verir ve bunu *kilit kaçırma* olarak sayar.

### Yol haritası / fikirler

- CallKit (PushKit olmadan) denemesi: arka planda aramadan sonra sesin kendiliğinden dönmesi, AirPods
  sessize alma, sistem arama arayüzü.
- Kilit ekranından "sesi devam ettir" için `AudioRecordingIntent` denemesi.
- 10 ms kareler (daha az paketleme gecikmesi, saniyede iki kat paket).
- Opus sıkıştırma; ikiden fazla cihaz.

## Lisans

MIT — bkz. [LICENSE](LICENSE).

---

## English summary

**Intercom** is a walkie‑talkie / intercom app that lets two iPhones talk to each other, typically
through AirPods, with **no cellular data, no internet, no router and no server**. It uses SwiftUI,
`AVAudioEngine` and Network framework, has no third‑party dependencies and installs on two phones with
free Apple IDs. It keeps working with the screen locked and shows a Live Activity.

**Features**

- Starts automatically on launch, discovers the other phone and connects; reconnects forever after a
  drop (0 / 0.25 / 0.5 / 1 / 2 s backoff with jitter), showing the attempt number and elapsed time.
- Push‑to‑talk, voice‑activated (with 40 ms pre‑roll) and open mic; mute in every mode.
- Lock Screen / Dynamic Island Live Activity with **Mute/Unmute**, **mode** (PTT | Voice | Open mic)
  and, in push‑to‑talk, a **Talk latch** that keeps transmitting without holding for up to 60 s (also
  released on mute, mode change, link loss or audio pause). There is no Stop button; tapping opens the app.
- Silent local notifications while the app is not active ("Connection lost – reconnecting to X" after a
  3 s grace period, replaced by "Reconnected to X"; "Audio paused – open Intercom to resume") and
  short audio cues for connected / lost / reconnected. Both can be turned off in Settings.
- Low latency: 20 ms uncompressed 16 kHz PCM over UDP, `AVAudioSinkNode` capture on the real‑time
  thread, 10 ms preferred IO buffer, adaptive playout delay (40–200 ms), and a Latency section with an
  estimated mouth‑to‑ear figure.
- English and Turkish UI.

**Requirements and install**

- Xcode 26 (the project format needs Xcode 16+), two iPhones on **iOS 18.0+**, free Apple ID(s),
  **Wi‑Fi switched on** on both phones (joining a network is not required).
- Two shared schemes: `Intercom` (phone 1; Run = `Release`, Test = `Debug`; `APP_BUNDLE_ID`
  `com.gkaragoz.p2pintercom`, team `YLKU8294NU`) and `Intercom (Phone 2)` (phone 2; `Release-Phone2` /
  `Debug-Phone2`; `com.gkaragoz.p2pintercom2`, team `MSBZ3RN6Q9`). Run uses Release because real‑time
  audio is not representative at `-Onone`.
- The app's bundle id is `$(APP_BUNDLE_ID)`, the Live Activity extension's is
  `$(APP_BUNDLE_ID).LiveActivity`, so each free team registers **two App IDs**. To use your own account,
  change `APP_BUNDLE_ID` and `DEVELOPMENT_TEAM` at project level, or on the command line:

  ```bash
  xcodebuild -project Intercom.xcodeproj -scheme Intercom -configuration Release \
    -destination 'id=<UDID>' -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    APP_BUNDLE_ID=com.you.intercom DEVELOPMENT_TEAM=<TEAM_ID> -derivedDataPath build/mine build
  xcrun devicectl device install app --device <UDID> build/mine/Build/Products/Release-iphoneos/Intercom.app
  ```

  `<TEAM_ID>` is the `OU=` field of your development certificate
  (`security find-certificate -a -c "Apple Development: you@example.com" -p | openssl x509 -noout -subject`),
  not the value in parentheses printed by `security find-identity`.
  **Never override `PRODUCT_BUNDLE_IDENTIFIER`** (the extension would get the app's id). Picking a Team
  or Bundle Identifier in Xcode's *Signing & Capabilities* tab writes target‑level literals that
  override the per‑configuration values; revert them if that happens.
- Free‑account limits: 7‑day profiles (app and extension), 3 registered devices per team (expiry is
  unreliable; sign phone 2 with a second free Apple ID through the Phone 2 scheme), 3 free apps per
  device, 10 App IDs per 7 days.

**Connection engines and pairing code**

- **Network (default):** `NWListener` + `NWBrowser` on Bonjour `_intercom-nw._udp`, one UDP flow per
  peer with peer‑to‑peer Wi‑Fi (AWDL) included, `.interactiveVoice`, cellular prohibited. Handshake,
  heartbeats (200 ms foreground / 500 ms background; dead after 2 s / 3 s), duplicate‑flow arbitration,
  backoff, path migration and a fallback around client‑isolated Wi‑Fi all live in the unit‑tested Core
  `LinkStateMachine`. Traffic is sealed with per‑link, per‑direction ChaChaPoly keys.
- **Multipeer (legacy):** MultipeerConnectivity with an app‑level watchdog, ping liveness and backoff.
  A Disconnect also travels as an always‑declined "bye" invitation, so a lost bye frame cannot leave the
  other phone redialling; it holds until the disconnecting phone restarts its intercom (new advertised epoch).
  Apple documents it as not working in the background and deprecates it in iOS 27.
- **Pairing code** (Network only): both phones must match (trimmed, case‑sensitive). Empty uses a
  built‑in key: works out of the box, integrity only, no privacy against anyone running this app.
  Phones with different codes see each other but do not connect ("Different pairing code"). Keys come
  from HKDF (not a slow password hash) and a 32‑bit key tag is advertised, so **use a long random code**;
  it is stored in plain `UserDefaults`.

**Background behaviour and limits**

- While the intercom runs, audio I/O never stops (not for PTT idle, mute or no peer); that keeps the
  process alive under the `audio` background mode. Costs: the orange mic indicator stays on, AirPods
  stay in HFP, continuous battery use. Press Stop when you are done.
- Leaving the app releases a held PTT button; use the Live Activity Talk latch, VOX or open mic.
- An accepted call, Siri or another app's audio stops audio. In the foreground the app retries
  (0.25 → 5 s) and offers **Resume audio**. In the background iOS refuses to restart audio (`!int` /
  `!rec`): the peer sees "The other iPhone's audio is paused", you get "Audio paused – open Intercom to
  resume", and **opening the app** brings audio back.
- The Live Activity carries a 15‑minute stale date (refreshed every 10 min; shows "Not updated recently"
  when stale), is renewed on foreground before iOS's 8‑hour limit, is not brought back after you swipe
  it away until the intercom restarts, and leftovers are ended at launch.

**Not yet verified on real devices** (logs are written to diagnose each):

- Whether iOS accepts Live Activity updates from an app kept alive only by background audio
  (compare `liveactivity` log lines with `liveactivitiesd` "forbidden to update activity").
- Whether Lock Screen buttons work without Face ID on a locked phone.
- Whether the AirPods stem mute gesture reaches a non‑CallKit `voiceChat` app
  (`AVAudioApplication.inputMuteStateChangeNotification`).
- Network framework peer‑to‑peer on **cellular‑capable iPhones with Wi‑Fi on but not joined to any
  network** (an unresolved iOS 26 forum report says discovery fails there); workaround: join both
  phones to any Wi‑Fi network, internet not needed.
- Capture buffer sizes on device: the tap path delivered 100 ms chunks in the simulator and may deliver
  larger ones on AirPods HFP; the sink path and the granted IO buffer need measuring on both routes.

**Testing**

- Log capture over USB:
  `DEVICECTL_CHILD_OS_ACTIVITY_DT_MODE=enable xcrun devicectl device process launch --console --terminate-existing --device <UDID> com.gkaragoz.p2pintercom`.
  For background behaviour, launch from the Home Screen (the Xcode debugger prevents suspension) and use
  Console.app (`subsystem:intercom`, with Action ▸ Include Info Messages on) or, right after the test,
  `sudo log collect --device-udid <UDID> --last 30m` read with `log show --info` (iOS keeps info lines
  in memory only; disconnect reasons, backoffs and dial attempts are logged at notice and persist).
  Categories: `controller`, `health` (5 s summary), `transport.network`, `transport.multipeer`, `audio`,
  `audio.session`, `audio.capture`, `latency` (5 s line), `background`, `notifications`,
  `liveactivity`, `liveactivity.intent`.
- Offline checklist: airplane mode + Wi‑Fi on (expect "Direct Wi‑Fi"); Wi‑Fi off (expect no link and
  the Wi‑Fi hint); **cellular ON + Wi‑Fi ON but not joined**; router without internet; one phone on
  Wi‑Fi and one not; client‑isolated guest network; App Privacy Report must list no domains.
- Reconnect tests: toggle Wi‑Fi for 10 s, walk out of range and back, swipe‑kill and relaunch the peer,
  Stop/Start, Disconnect/Connect, different pairing codes; repeat locked.
- Latency: read Settings ▸ Latency and the `latency` log line, compare Low latency vs Compatible capture
  on speaker and AirPods, then run a one‑way click test recorded by a Mac microphone (20 clicks, median
  and p95, both directions); target ≤ 150 ms mouth‑to‑ear on the speaker route over a router.

**Development:** `swift test` runs the Foundation‑only Core (also on Linux in CI). CI additionally
checks `xcodebuild -list`, Turkish translations in every string catalog, a simulator build through the
`Intercom` scheme (after which every string the compiler extracted must exist in its catalog) and an unsigned `Release-Phone2` device build through `Intercom (Phone 2)`, and asserts
the Live Activity extension is embedded with the right extension point and bundle id.
