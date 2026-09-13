# Intercom — iPhone'dan iPhone'a, internetsiz sesli konuşma

[![CI](https://github.com/gkaragoz/p2p-intercom-iphone/actions/workflows/ci.yml/badge.svg)](https://github.com/gkaragoz/p2p-intercom-iphone/actions/workflows/ci.yml)

İki iPhone'un **hücresel veri veya internet olmadan**, yalnızca yerel Wi‑Fi (ya da doğrudan
cihazdan cihaza Wi‑Fi/Bluetooth) üzerinden, AirPods ile birbirine konuşmasını sağlayan
telsiz / interkom uygulaması. SwiftUI ile yazıldı, üçüncü parti bağımlılığı yok, ücretsiz bir
Apple ID ile iki telefona kurulabilir.

*(English summary at the bottom.)*

## Neler yapar

- **Otomatik eşleşme:** Uygulamayı iki telefonda açmanız yeterli; birbirlerini bulup bağlanırlar.
- **Üç konuşma modu:**
  - **Bas konuş (PTT):** Büyük düğmeyi basılı tuttuğunuz sürece ses gider.
  - **Ses algılama (VOX):** Konuşmaya başlayınca otomatik gönderir; eşik ayarlanabilir.
  - **Açık hat:** Mikrofon sürekli açık, klasik interkom.
- **AirPods desteği:** Ses giriş/çıkışı otomatik olarak AirPods'a (ya da kablolu kulaklığa) yönlenir;
  kulaklık yoksa hoparlör kullanılır ve yankı bastırma (voice processing) devrededir.
- **Düşük gecikme:** 20 ms'lik ham PCM paketleri, güvenilmez (UDP benzeri) kanaldan gider;
  alıcı tarafta yeniden sıralama, kayıp gizleme ve ayarlanabilir jitter tamponu vardır.
- **Arka planda çalışma:** Ekran kilitliyken de ses akışı sürer (`audio` background mode).
- **Canlı göstergeler:** Kendi ve karşı tarafın ses seviyesi, "karşı taraf konuşuyor" bildirimi,
  gidiş‑dönüş süresi (RTT), tampon istatistikleri.
- **Türkçe ve İngilizce arayüz.**

## Nasıl çalışır

```
   iPhone A                                                   iPhone B
┌───────────────────────────┐                        ┌───────────────────────────┐
│ AirPods mikrofonu          │                        │                           │
│   ▼                        │                        │                           │
│ AVAudioEngine.inputNode    │                        │  AVAudioSourceNode        │
│   ▼ (AVAudioConverter)     │   MultipeerConnectivity│    ▲                      │
│ 16 kHz / mono / Int16      │  ───── .unreliable ───▶│  JitterBuffer             │
│   ▼ (20 ms'lik kareler)    │        ses paketleri   │    ▲                      │
│ TransmitGate (PTT/VOX/açık)│  ───── .reliable ─────▶│  WireMessage.decode       │
│   ▼                        │     kontrol mesajları  │                           │
│ AudioPacket → WireMessage  │                        │  mainMixerNode → AirPods  │
└───────────────────────────┘                        └───────────────────────────┘
```

| Katman | Dosyalar | Görev |
|---|---|---|
| **Core** (platformdan bağımsız) | `Intercom/Core/` | Paket biçimi, jitter tamponu, kare bölücü, VOX, gönderim kapısı, RTT ölçümü. Linux'ta `swift test` ile test edilir. |
| **Audio** | `Intercom/Audio/` | `AVAudioSession` yapılandırması (`.playAndRecord` + `.voiceChat` + `.allowBluetooth`), `AVAudioEngine` yakalama/çalma, rota ve kesinti yönetimi. |
| **Networking** | `Intercom/Networking/` | `MCNearbyServiceAdvertiser` + `MCNearbyServiceBrowser` ile keşif, tek taraflı davet seçimi, kopunca yeniden bağlanma. |
| **Model** | `Intercom/Model/` | `IntercomController` (ana aktör), `AudioPipeline` (gerçek zamanlı köprü), `AppSettings`. |
| **Views** | `Intercom/Views/` | SwiftUI ekranları. |

Ses **sıkıştırılmadan** (PCM 16 kHz, ≈256 kbit/s) gönderilir; Wi‑Fi için bu rahatça yeterlidir ve
kodek gecikmesi sıfırdır. AirPods'un mikrofonu kullanıldığında Bluetooth zaten HFP profiline
(16 kHz geniş bant) düştüğü için daha yüksek örnekleme hızının anlamı yoktur.

## Gereksinimler

- macOS üzerinde **Xcode 15 veya üstü**. Proje CI'da Xcode 26.6 (iOS 26.5 SDK) ile derlenmektedir.
- **iOS 16.0+** çalıştıran iki iPhone.
- Ücretsiz bir **Apple ID** (ücretli geliştirici hesabı gerekmez).
- İki telefon aynı Wi‑Fi ağında olmalı **veya** her ikisinde Wi‑Fi ve Bluetooth açık olmalı
  (MultipeerConnectivity, modem olmadan doğrudan cihazdan cihaza da bağlanabilir).

## Kurulum (ücretsiz Apple ID ile)

1. Depoyu klonlayın ve `Intercom.xcodeproj` dosyasını Xcode ile açın.
2. **Xcode ▸ Settings ▸ Accounts** bölümünden Apple ID'nizi ekleyin (yoksa).
3. Sol ağaçta **Intercom** projesini seçin ▸ **Intercom** hedefi ▸ **Signing & Capabilities**:
   - **Automatically manage signing** işaretli olsun.
   - **Team** olarak kişisel ekibinizi (*Adınız (Personal Team)*) seçin.
   - Xcode "bundle identifier is not available" derse **Bundle Identifier**'ı kendinize özgü bir
     değerle değiştirin (ör. `com.adiniz.intercom`).
4. iPhone'u kabloyla Mac'e bağlayın, cihazda **Trust This Computer** deyin. iOS 16+ için telefonda
   **Ayarlar ▸ Gizlilik ve Güvenlik ▸ Geliştirici Modu**'nu açın (telefon yeniden başlar).
5. Xcode'da hedef cihaz olarak iPhone'u seçip **Run (⌘R)** yapın.
6. İlk açılışta iOS uygulamayı engeller. Telefonda **Ayarlar ▸ Genel ▸ VPN ve Aygıt Yönetimi**
   ▸ geliştirici uygulaması (Apple ID'niz) ▸ **Güven** deyin.
7. Aynı adımları arkadaşınızın iPhone'u için tekrarlayın (onun telefonunu da kendi Mac'inize bağlayıp
   aynı Apple ID ile yükleyebilirsiniz).

### Ücretsiz hesap sınırları

Apple'ın ücretsiz "Personal Team" için belgelediği sınırlar:

| Sınır | Anlamı |
|---|---|
| **7 gün** | Ücretsiz hesapla imzalanan uygulama 7 gün sonra açılmaz. Telefonu tekrar Mac'e bağlayıp **Run** yapmak yeterlidir; ayarlar ve veriler silinmez. |
| **3 cihaz** | Aynı anda en fazla 3 cihaz kayıtlı olabilir. Bu kayıtlar da 7 gün sonra düşer. Kota dolduğunda Xcode şu hatayı verir: *"Your development team has reached the maximum number of registered iPhone devices."* Ücretsiz hesap cihaz listesini kendisi temizleyemez; çözüm için aşağıdaki bölüme bakın. |
| **3 uygulama / cihaz** | Bir cihazda aynı anda en fazla 3 geliştirici uygulaması kurulu olabilir. Xcode "Maximum number of apps for free development profiles has been reached" derse o cihazdan başka bir geliştirici uygulamasını silin. |
| **10 App ID / 7 gün** | Her yeni bundle identifier bir App ID harcar. Gereksiz yere değiştirmeyin. |
| Push, iCloud, TestFlight | Ücretsiz hesapta yok; bu uygulama bunları **kullanmaz**. Mikrofon, yerel ağ (Bonjour) ve arka plan ses izinleri ücretsiz hesapta sorunsuz çalışır: bunlar Info.plist anahtarıdır, kısıtlı yetki değil. |

### İkinci telefona kurulum ve cihaz kotası hatası

Birinci telefona kurduktan sonra ikincisinde şu hatayı alırsanız:

```
Your development team has reached the maximum number of registered iPhone devices.
```

Apple ID'nizin 3 cihazlık kotası dolmuştur. İki çözüm var.

**Çözüm A: bekleyin (bedava ama güvenilmez).** Apple'ın belgesi cihaz kayıtlarının 7 gün sonra düştüğünü söyler ve destek mühendislerinin bu hataya verdiği resmî cevap "bekleyin" olur. Ancak aylardır yeni cihaz kaydetmemiş olmasına rağmen kotası dolu kalan kullanıcılar var; bu düşme pratikte her zaman gerçekleşmiyor. Ücretsiz hesap cihaz listesini göremez ve silemez, çünkü o portal sayfası ücretli üyelik ister. Apple destek mühendisleri ücretsiz hesap için sıfırlama seçeneği olmadığını açıkça belirtiyor. Bu yüzden bu yola bel bağlamayın.

Ekibinize kayıtlı cihazları Mac'inizden görebilirsiniz. Aşağıdaki döngüyü olduğu gibi yapıştırın; Xcode'un indirdiği bütün profilleri tarar:

```bash
cd ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles
for p in *.mobileprovision; do
  plist=$(security cms -D -i "$p")
  name=$(printf '%s' "$plist" | plutil -extract Name raw -o - - 2>/dev/null)
  team=$(printf '%s' "$plist" | plutil -extract TeamName raw -o - - 2>/dev/null)
  echo "== $name  [$team]"
  printf '%s' "$plist" | plutil -extract ProvisionedDevices json -o - - 2>/dev/null \
    || echo "   (cihaz listesi yok)"
done
```

Çıkan UDID listesi kotayı neyin doldurduğunu gösterir. Sadece iPhone'lar değil, iPad'ler ve telefonunuza eşli Apple Watch gibi Xcode'un kaydettiği her cihaz sayılır. `TeamName` alanı da hangi profilin hangi ekibe ait olduğunu gösterir; ikinci bir Apple ID eklediğinizde burada iki farklı ekip görürsünüz.

**Çözüm A2: Apple destekten silmelerini isteyin.** developer.apple.com üzerindeki *Contact Us* bağlantısından telefon görüşmesi talep edip, Xcode free provisioning ile test etmeye devam edebilmek için eski cihazların listeden çıkarılmasını isteyebilirsiniz. Bunun işe yaradığını bildiren kullanıcılar var, ama ücretsiz hesap için garanti değildir ve zaman alır.

**Çözüm B: ikinci telefon için ayrı bir ücretsiz Apple ID (önerilen, hemen çalışır).** Her Apple ID'nin kendi Personal Team'i ve kendi 3 cihazlık kotası vardır. Kotası dolu hesabı hiç kurcalamadan ikinci telefonu kurabilirsiniz.

1. İkinci bir ücretsiz Apple ID oluşturun (ya da elinizdeki başka bir Apple ID'yi kullanın).
2. Xcode ▸ Settings ▸ Accounts'a onu da ekleyin.
3. İkinci telefonu bağlayın, Signing & Capabilities'te **Team** olarak yeni hesabın Personal Team'ini seçin.
4. **Bundle Identifier'ı değiştirin**, örneğin `com.adiniz.p2pintercom2`. Bir App ID yalnızca tek bir ekibe kayıtlı olabilir; birinci hesabın aldığı kimliği ikinci hesap alamaz.
5. Run yapın.

Bundle identifier'ların farklı olması uygulamanın çalışmasını **bozmaz**. MultipeerConnectivity eşleri yalnızca servis tipine göre bulur; bu projede o değer `IntercomProtocol.serviceType` içinde sabit `p2p-intercom`'dur ve iki telefonda da aynıdır. Yani farklı bundle kimliğine sahip iki kurulum birbirini normal şekilde görür ve bağlanır.

Komut satırını tercih ederseniz, depoda paylaşılan bir şema olduğu için Xcode arayüzüne hiç girmeden de kurabilirsiniz:

```bash
# Telefonun UDID'sini öğrenin
xcrun xctrace list devices

# İkinci telefona, ikinci hesabın ekibiyle ve farklı bundle id ile kurun
xcodebuild -project Intercom.xcodeproj -scheme Intercom \
  -destination 'id=<UDID>' -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=<IKINCI_TEAM_ID> \
  PRODUCT_BUNDLE_IDENTIFIER=com.adiniz.p2pintercom2 \
  build
```

Team ID'leri `security find-identity -v -p codesigning` çıktısındaki parantez içi değerlerden görebilirsiniz.

> **Not:** AltStore, SideStore ve Sideloadly gibi sideload araçları da aynı ücretsiz hesap kotalarını kullanır. Aynı Apple ID ile aynı 3 cihaz duvarına çarparsınız; onlarda da çözüm ikinci bir Apple ID'dir. Avantajları, ilk kurulumdan sonra haftalık yenilemeyi Xcode'suz (SideStore'da telefonun kendisinden) yapabilmenizdir.

## İlk çalıştırma

Uygulama ilk açılışta iki izin ister; ikisine de **İzin Ver** deyin:

1. **Mikrofon** — karşı tarafın sizi duyabilmesi için.
2. **Yerel Ağ** — diğer iPhone'u bulabilmek için (iOS 14+ zorunlu tutar).

Sonrasında iki telefonda da uygulama açıkken **"Yakındaki iPhone'lar"** listesinde karşı taraf
görünür ve birkaç saniye içinde otomatik bağlanır. Bağlanmazsa satırdaki **Bağlan** düğmesine
dokunun.

## Kullanım

- **Mod seçici** (ekranın ortasında): Bas konuş / Ses algılama / Açık hat.
- **Büyük düğme:** PTT modunda basılı tutun; diğer modlarda dokunmak sessize alır / açar.
- **Sessize al:** Sol alttaki mikrofon düğmesi her modda geçerlidir.
- **Ayarlar (⚙︎):**
  - **Adınız** — karşı telefonda görünen isim.
  - **Ses eşiği** — VOX modunda gönderimi tetikleyen seviye. Normal konuşurken gösterge
    işaretin sağına geçmeli, sessizken solunda kalmalı.
  - **Oynatma tamponu** — 20–300 ms. Wi‑Fi takılıyorsa artırın; gecikmeyi düşürmek için azaltın.
  - **Ses düzeyi, Ekranı açık tut.**
  - **Tanılama** — giriş biçimi, RTT, gönderilen/alınan kare, gizlenen kayıp, tampon boşalması.

## AirPods ve ses kalitesi

- AirPods'un **mikrofonu** kullanıldığında Bluetooth otomatik olarak A2DP'den HFP'ye geçer;
  ses kalitesi telefon görüşmesi seviyesine (16 kHz) iner. İki yönlü canlı konuşma için bu
  kaçınılmazdır ve uygulamanın hat formatı zaten bununla eşleşir.
- Kulaklık takılmadığında ses hoparlörden çalar ve yankı bastırma devreye girer
  (`setVoiceProcessingEnabled(true)`).
- Kulaklığı sonradan takıp çıkarmak güvenlidir; ses motoru rota değişiminde kendini yeniden kurar.

## Arka plan davranışı

`audio` background mode sayesinde ekran kilitliyken ya da uygulama arkadayken ses oturumu ve ses
motoru çalışmayı sürdürür; bu da MultipeerConnectivity bağlantısını canlı tutar. Apple,
MultipeerConnectivity'yi arka plan için tasarlamadığından uzun süre arkada kalınca bağlantı
zaman zaman kopabilir; uygulama keşfi yeniden başlatıp otomatik yeniden bağlanır. En güvenilir
kullanım, uygulamanın ekranda kalmasıdır (**Ekranı açık tut** ayarı varsayılan olarak açıktır).

> **Not:** Sohbet kaydında geçen "Voice over IP" background mode'u yalnızca PushKit/CallKit ile
> anlam kazanır ve App Store dağıtımı gerektirir; bu projede gerekmediği için eklenmemiştir.

## Test durumu

Kod, GitHub Actions üzerinde her push'ta derlenir (iOS Simülatör) ve çekirdek birim testleri
Linux + macOS'ta çalışır. **Gerçek iki iPhone + AirPods ile uçtan uca test henüz yapılmamıştır**;
ilk denemede sorun görürseniz *Tanılama* bölümündeki değerlerle birlikte bir issue açın.

## Sorun giderme

| Belirti | Yapılacak |
|---|---|
| Karşı taraf listede görünmüyor | İki telefonda da Wi‑Fi **ve** Bluetooth açık mı? Aynı ağda mı? Yerel Ağ iznini **Ayarlar ▸ Intercom** altından kontrol edin. Uygulamayı iki telefonda da kapatıp açın. |
| Görünüyor ama bağlanmıyor | Satırdaki **Bağlan**'a dokunun. Bazı kurumsal/otel Wi‑Fi ağları cihazlar arası trafiği engeller; bu durumda o ağdan çıkın ya da ağı unutun (Ayarlar ▸ Wi‑Fi ▸ ⓘ ▸ Bu Ağı Unut) ama **Wi‑Fi'yi kapatmayın**: cihazdan cihaza (P2P) Wi‑Fi için Wi‑Fi radyosunun açık olması gerekir. |
| Ses kesik kesik geliyor | **Oynatma tamponu**'nu 100–200 ms'ye çıkarın. Tanılama'da *Gizlenen kayıp* ve *Tampon boşalması* artıyorsa ağ zayıftır; telefonları yaklaştırın. |
| Yankı / uğultu | Kulaklık kullanın ya da sesi kısın. Hoparlör modunda yankı bastırma vardır ama iki telefon aynı odadaysa akustik geri besleme oluşabilir. |
| VOX hep açık / hiç açılmıyor | Ses eşiğini ayarlayın; gösterge işareti geçince gönderim başlar. |
| "Mikrofon izni reddedildi" | **Ayarlar'ı Aç** düğmesiyle izni verin. |
| 7 gün sonra uygulama açılmıyor | Telefonu Mac'e bağlayıp Xcode'dan tekrar **Run** yapın. |

## Geliştirme

```bash
# Platformdan bağımsız çekirdeğin birim testleri (macOS veya Linux):
swift test

# iOS derlemesi (imzasız, simülatör):
xcodebuild -project Intercom.xcodeproj -target Intercom -sdk iphonesimulator \
  -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

GitHub Actions (`.github/workflows/ci.yml`) her push'ta Linux'ta çekirdek testlerini, macOS'ta ise
hem testleri hem simülatör derlemesini çalıştırır.

### Hat protokolü

Her `MCSession.send` verisi bir etiket baytıyla başlar:

- `0xA1` **ses**: `"IC"` + sürüm + kodek + sıra no (UInt16) + zaman damgası (UInt32) + örnek sayısı
  (UInt16) + Int16 LE örnekler. 20 ms = 320 örnek = 652 bayt. `.unreliable` ile gönderilir.
- `0xC1` **kontrol**: JSON `{"type": "hello|talkState|ping|pong|bye", "payload": {...}}`.
  `.reliable` ile gönderilir.

Jitter tamponu (`Intercom/Core/JitterBuffer.swift`): hedef derinlik kadar kare biriktirip çalmaya
başlar, sırasız paketleri sıralar, kayıp kareyi sessizlikle gizler, taşarsa en eski kareleri atar,
uzun süre derin kalırsa gecikmeyi tek tek kare kırparak geri çeker, sıra numarasında büyük sıçrama
görürse (karşı uygulama yeniden başlamış) akışı yeniden senkronlar.

### Yol haritası / fikirler

- Opus sıkıştırma (`AVAudioConverter` + `kAudioFormatOpus`, iOS 17+) ile Bluetooth‑only bağlantıda
  bant genişliğini düşürmek.
- İkiden fazla cihaz (konferans): protokol zaten çoklu eşe gönderir; yalnızca karıştırma gerekir.
- CallKit entegrasyonu (arka planda daha sağlam yaşam döngüsü; ücretli hesap ve App Store gerekir).

## Lisans

MIT — bkz. [LICENSE](LICENSE).

---

## English summary

**Intercom** is a walkie‑talkie / intercom app that lets two iPhones talk to each other through
AirPods over the local network — no cellular data, no internet, no server. It is built with
SwiftUI on top of `MultipeerConnectivity` (discovery + transport) and `AVAudioEngine`
(capture + playback) and can be installed on two phones with a free Apple ID.

- **Modes:** push‑to‑talk, voice‑activated (VOX) and open mic; mute in every mode.
- **Audio path:** `AVAudioSession` `.playAndRecord` / `.voiceChat` / `.allowBluetooth` so the
  AirPods microphone is used (Bluetooth switches to the 16 kHz HFP profile); voice processing
  (echo cancellation) for loudspeaker use; automatic rebuild on route changes and interruptions.
- **Transport:** both phones advertise and browse; a random token decides which side invites and
  the other side only accepts (a non-initiator that sees no invitation re-announces itself instead
  of inviting), so a peer pair never runs two handshakes at once; discovery restarts after every
  drop for automatic reconnection.
  Audio frames (20 ms, 16 kHz mono Int16 PCM) go over `.unreliable`, control messages over `.reliable`.
- **Receiver:** a jitter buffer reorders packets, conceals losses, bounds latency and resyncs
  after a peer restart. The platform‑independent core (`Intercom/Core`) is a Swift package with
  unit tests that run on Linux and macOS (`swift test`).
- **Background:** the `audio` background mode keeps the session alive while the screen is locked.
- **Localization:** English and Turkish.

### Install with a free Apple ID

Open `Intercom.xcodeproj`, add your Apple ID under *Xcode ▸ Settings ▸ Accounts*, pick your
*Personal Team* under *Signing & Capabilities* (change the bundle identifier if Xcode says it is
taken), enable *Developer Mode* on the iPhone, plug it in and press *Run*. On the phone, trust the
developer profile under *Settings ▸ General ▸ VPN & Device Management*. Free‑account limits: a
provisioning profile expires after 7 days, a Personal Team may register 3 devices (registrations
also expire after 7 days) and each device holds at most 3 free‑provisioned apps.

If the second iPhone fails with *"Your development team has reached the maximum number of
registered iPhone devices"*, either wait a week for the registrations to lapse, or sign the second
phone with a second free Apple ID and a different bundle identifier. Different bundle identifiers
are harmless here: MultipeerConnectivity matches peers on the service type (`p2p-intercom`), not on
the bundle id.
