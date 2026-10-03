import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var controller: IntercomController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var nameDraft = ""
    @State private var pairingCodeDraft = ""
    @State private var journalEventCount = 0
    @State private var isConfirmingJournalClear = false

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                connectionSection
                transmitSection
                audioSection
                voiceEffectsSection
                diagnosticsSection
                latencySection
                aboutSection
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commitName()
                        commitPairingCode()
                        dismiss()
                    }
                }
            }
            .onAppear {
                nameDraft = settings.displayName
                pairingCodeDraft = settings.pairingCode
                controller.refreshNotificationPermission()
            }
            .onDisappear {
                commitName()
                commitPairingCode()
            }
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        Section {
            TextField("Name", text: $nameDraft)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .onSubmit(commitName)
        } header: {
            Text("Your name")
        } footer: {
            Text("Shown on the other iPhone. Changing it restarts discovery.")
        }
    }

    private var connectionSection: some View {
        Section {
            if let warning = connectionWarning {
                connectionWarningRow(warning)
            }
            Picker("Engine", selection: $settings.transportKind) {
                Text("Network (recommended)").tag(TransportKind.network)
                Text("Multipeer (legacy)").tag(TransportKind.multipeer)
            }
            if settings.transportKind == .network {
                TextField("Pairing code (optional)", text: $pairingCodeDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit(commitPairingCode)
            }
            Toggle("Notifications in background", isOn: $settings.notificationsEnabled)
            if settings.notificationsEnabled, controller.notificationPermissionDenied {
                // The preference stays on, so notices work again as soon as iOS allows them.
                Button(action: openSystemSettings) {
                    Label("Allow notifications in iOS Settings", systemImage: "exclamationmark.triangle.fill")
                }
                .tint(.orange)
            }
            Toggle("Connection sounds", isOn: $settings.audioCuesEnabled)
        } header: {
            Text("Connection")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if settings.transportKind == .network {
                    Text("Both iPhones must use the same engine and the same pairing code. Without a code a built-in key is used; a long random code keeps others from listening in.")
                } else {
                    Text("Both iPhones must use the same engine.")
                }
                Text("Works without internet or a router: Wi‑Fi must be on, but it does not need to join a network.")
            }
        }
    }

    /// Setup problems the Connection settings can fix.
    private var connectionWarning: SessionWarning? {
        switch controller.warning {
        case .localNetworkDenied?, .pairingMismatch?, .versionMismatch?:
            return controller.warning
        case .wifiOff?, .outOfRange?, nil:
            return nil
        }
    }

    @ViewBuilder
    private func connectionWarningRow(_ warning: SessionWarning) -> some View {
        switch warning {
        case .localNetworkDenied:
            Button(action: openSystemSettings) {
                Label("Allow Local Network access", systemImage: "exclamationmark.triangle.fill")
            }
            .tint(.orange)
        case .pairingMismatch:
            Label("The other iPhone uses a different pairing code.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .versionMismatch:
            Label("The other iPhone runs an incompatible version. Install the same build on both.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .wifiOff, .outOfRange:
            EmptyView()
        }
    }

    private var transmitSection: some View {
        Section {
            Picker("Mode", selection: $settings.transmitMode) {
                ForEach(TransmitMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            if settings.transmitMode == .voiceActivated {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Voice threshold")
                        Spacer()
                        Text(verbatim: "\(Int(settings.voxThresholdDB)) dB")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.voxThresholdDB, in: AppSettings.voxThresholdRange, step: 1)
                    LevelMeterView(level: controller.inputMeter,
                                   marker: AudioLevel.meterValue(dB: Float(settings.voxThresholdDB)))
                }
            }
        } header: {
            Text("Transmit")
        } footer: {
            if settings.transmitMode == .voiceActivated {
                Text("Lower values trigger more easily. Speak normally and check that the meter passes the marker.")
            } else {
                Text(settings.transmitMode.explanation)
            }
        }
    }

    private var audioSection: some View {
        Section {
            Picker("Audio quality", selection: $settings.wireRate) {
                ForEach(WireRate.allCases) { rate in
                    Text(rate.title).tag(rate)
                }
            }
            if controller.isWireRateLimitedByPeer {
                Label("The other iPhone's version supports standard quality only; sending at 16 kHz.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Picker("Latency profile", selection: $settings.latencyProfile) {
                ForEach(LatencyProfile.allCases) { profile in
                    Text(profile.title).tag(profile)
                }
            }
            Toggle("Automatic playout buffer", isOn: $settings.playoutAuto)
            if !settings.playoutAuto {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Playout buffer")
                        Spacer()
                        Text(verbatim: "\(Int(settings.jitterTargetMs)) ms")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.jitterTargetMs, in: AppSettings.jitterRangeMs, step: 20)
                }
            }
            Picker("Capture", selection: $settings.captureMode) {
                Text("Low latency").tag(CaptureMode.lowLatency)
                Text("Compatible").tag(CaptureMode.compatible)
            }
            Toggle("Voice processing", isOn: $settings.voiceProcessingEnabled)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Volume")
                    Spacer()
                    Text(settings.outputVolume.formatted(.percent.precision(.fractionLength(0))))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.outputVolume, in: 0...1, step: 0.05)
            }
            Toggle("Hear my voice (sidetone)", isOn: $settings.sidetone)
            if settings.sidetone {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Sidetone level")
                        Spacer()
                        Text(settings.sidetoneLevel.formatted(.percent.precision(.fractionLength(0))))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $settings.sidetoneLevel, in: 0...1, step: 0.05)
                }
            }
            Toggle("Keep screen awake", isOn: $settings.keepScreenAwake)
        } header: {
            Text("Audio")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("The automatic buffer follows the measured Wi‑Fi jitter; a fixed higher value survives hiccups better but adds delay. Use Compatible capture only if the microphone does not work. Voice processing removes echo from the loudspeaker; turn it off only with headphones.")
                Text("Higher quality sends more data (128 kbit/s at 8 kHz up to 512 kbit/s at 32 kHz) and needs this version on both iPhones; AirPods' hands-free microphone is 16 kHz anyway. Fast shrinks the playout and I/O buffers for the lowest delay; Safe absorbs more Wi‑Fi hiccups.")
                if settings.sidetone {
                    Text("Plays your microphone back to you with the lowest possible delay. Only with wired headphones or a headset: it is silenced on the loudspeaker to prevent feedback, and while muted. Bluetooth adds its own delay.")
                }
            }
        }
    }

    /// What the peer hears (effect and EQ on this microphone), what is heard here (listening EQ),
    /// and the "hear yourself" test that plays the own voice back exactly as it is sent.
    private var voiceEffectsSection: some View {
        Section {
            Picker("Microphone effect", selection: $settings.transmitEffect) {
                ForEach(VoiceEffectPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            Picker("Microphone EQ", selection: $settings.transmitEQ) {
                ForEach(EQPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            Picker("Listening EQ", selection: $settings.playbackEQ) {
                ForEach(EQPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            testLoopbackRows
        } header: {
            Text("Voice effects")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("The other iPhone hears the microphone effect and EQ; the listening EQ changes only what you hear. Pitch effects add a little delay. Effects never affect the connection.")
                Text("Records your microphone for 5 seconds exactly as it is sent (current quality, microphone effect and EQ) and plays it back through the normal playback path. Incoming audio is paused during playback. Nothing is saved.")
            }
        }
    }

    /// The test needs a running audio engine; `startTestRecording` and `playTestRecording` refuse otherwise.
    private var canRunTest: Bool {
        controller.isRunning && controller.audioState == .running
    }

    @ViewBuilder
    private var testLoopbackRows: some View {
        switch controller.testLoopback {
        case .idle:
            Button("Record 5 s and play back") { controller.startTestRecording() }
                .disabled(!canRunTest)
            if controller.hasTestRecording {
                Button("Play again") { controller.playTestRecording() }
                    .disabled(!canRunTest)
            }
        case .recording(let seconds):
            HStack {
                Label {
                    Text("Recording… \(seconds) s")
                } icon: {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                }
                Spacer()
                Button("Cancel") { controller.cancelTestLoopback() }
                    .buttonStyle(.borderless)
            }
        case .playing(let seconds):
            HStack {
                Label {
                    Text("Playing back… \(seconds) s")
                } icon: {
                    Image(systemName: "play.circle.fill")
                }
                Spacer()
                Button("Cancel") { controller.cancelTestLoopback() }
                    .buttonStyle(.borderless)
            }
        }
    }

    private var diagnosticsSection: some View {
        Section {
            LabeledContent("Engine", value: settings.transportKind.displayName)
            LabeledContent("Output route", value: controller.route.outputName.isEmpty ? "—" : controller.route.outputName)
            LabeledContent("Input format", value: controller.inputDescription.isEmpty ? "—" : controller.inputDescription)
            if let incoming = controller.incomingSampleRate, incoming != controller.effectiveWireRate.sampleRate {
                // Each side sends at its own rate; shown only when the peer's differs from ours.
                LabeledContent("Incoming audio",
                               value: "\(Self.kHz(Double(incoming))) → \(Self.kHz(Double(controller.effectiveWireRate.sampleRate)))")
            }
            if let version = controller.connectedPeers.compactMap(\.appVersion).first {
                LabeledContent("Peer app version", value: version)
            }
            LabeledContent("Frames sent", value: controller.framesSent.formatted())
            LabeledContent("Frames received", value: controller.statistics.received.formatted())
            LabeledContent("Buffered", value: controller.statistics.bufferedFrames.formatted())
            LabeledContent("Concealed", value: controller.statistics.concealed.formatted())
            LabeledContent("Late", value: (controller.statistics.lateDropped + controller.statistics.overflowDropped + controller.statistics.trimmed).formatted())
            LabeledContent("Underruns", value: controller.statistics.underruns.formatted())
            journalRows
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("The link journal records drops, reconnects and phone conditions on this iPhone, so a ride can be analysed afterwards. Share it after the ride.")
        }
    }

    /// The on-device link journal: events, share, marker, clear.
    @ViewBuilder
    private var journalRows: some View {
        LabeledContent("Link journal events", value: journalEventCount.formatted())
            .task { journalEventCount = LinkJournal.shared.count }
        ShareLink(item: LinkJournalExport(), preview: SharePreview("Intercom link journal")) {
            Label("Share link journal", systemImage: "square.and.arrow.up")
        }
        Button {
            controller.markJournal()
            journalEventCount = LinkJournal.shared.count
        } label: {
            Label("Mark this moment", systemImage: "flag")
        }
        Button(role: .destructive) {
            isConfirmingJournalClear = true
        } label: {
            Label("Clear link journal", systemImage: "trash")
        }
        .confirmationDialog("Clear the link journal?", isPresented: $isConfirmingJournalClear, titleVisibility: .visible) {
            Button("Clear link journal", role: .destructive) {
                LinkJournal.shared.clear()
                journalEventCount = 0
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every recorded event.")
        }
    }

    /// Where the delay comes from, in the order audio travels: network, playout buffer, capture, render.
    private var latencySection: some View {
        let latency = controller.latency
        let session = latency.session
        let hasPeer = !controller.connectedPeers.isEmpty
        return Section {
            LabeledContent("Audio state", value: controller.audioState.displayName)
            LabeledContent("Estimated mouth-to-ear",
                           value: hasPeer ? (latency.estimatedMouthToEarMs.map { "~\(Self.wholeMs($0))" } ?? "—") : "—")
            LabeledContent("Round trip", value: controller.roundTripMs.map(Self.wholeMs) ?? "—")
            LabeledContent("Link path", value: controller.linkPath?.displayName ?? "—")
            LabeledContent("Playout target", value: latency.jitterTargetMs > 0
                           ? String(localized: "\(Self.wholeMs(Double(latency.jitterTargetMs))) · depth \(Self.wholeMs(Double(latency.jitterDepthMs)))")
                           : "—")
            LabeledContent("Capture path", value: latency.capturePath.displayName)
            LabeledContent("Input", value: latency.inputSampleRate > 0
                           ? String(localized: "\(Self.kHz(latency.inputSampleRate)) · \(latency.inputChannels) ch")
                           : "—")
            LabeledContent("Voice processing", value: latency.capturePath == .none
                           ? "—"
                           : (latency.voiceProcessing ? String(localized: "On") : String(localized: "Off")))
            LabeledContent("Effect delay", value: latency.effectLatencyMs > 0 ? Self.ms(latency.effectLatencyMs) : "—")
            LabeledContent("Sample rate", value: session.sampleRate > 0 ? Self.kHz(session.sampleRate) : "—")
            LabeledContent("IO buffer", value: session.ioBufferDuration > 0 ? Self.ms(session.ioBufferDuration * 1000) : "—")
            LabeledContent("Hardware latency", value: session.sampleRate > 0
                           ? String(localized: "in \(Self.ms(session.inputLatency * 1000)) · out \(Self.ms(session.outputLatency * 1000))")
                           : "—")
            LabeledContent("Frames per callback", value: "\(latency.captureFramesPerCallbackMin) / \(Int(latency.captureFramesPerCallbackAverage.rounded())) / \(latency.captureFramesPerCallbackMax)")
            LabeledContent("Capture gap (max)", value: Self.ms(latency.maxCaptureIntervalMs))
            LabeledContent("Capture delay", value: String(localized: "\(Self.ms(latency.deliveryLagAverageMs)) · max \(Self.ms(latency.deliveryLagMaxMs))"))
            LabeledContent("Render frames", value: String(localized: "\(latency.renderFramesMin)–\(latency.renderFramesMax) · gap \(Self.ms(latency.maxRenderIntervalMs))"))
            LabeledContent("Underruns / s", value: Self.rate(latency.underrunsPerSecond))
            LabeledContent("Concealed / s", value: Self.rate(latency.concealedPerSecond))
            LabeledContent("Late / s", value: Self.rate(latency.latePerSecond + latency.trimmedPerSecond))
            LabeledContent("Lock misses / s", value: Self.rate(latency.lockMissesPerSecond))
        } header: {
            Text("Latency")
        } footer: {
            Text("Refreshed every second. Mouth-to-ear assumes the other iPhone's microphone path matches this one.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("Version", value: IntercomController.appVersion)
            LabeledContent("Protocol", value: "v\(IntercomProtocol.version) · PCM \(Self.kHz(Double(controller.effectiveWireRate.sampleRate)))")
            if let url = URL(string: "https://github.com/gkaragoz/p2p-intercom-iphone") {
                Link("Source code on GitHub", destination: url)
            }
        }
    }

    // MARK: - Formatting (locale-aware decimal separators)

    private static func ms(_ value: Double) -> String {
        "\(value.formatted(.number.precision(.fractionLength(1)))) ms"
    }

    private static func wholeMs(_ value: Double) -> String {
        "\(Int(value.rounded())) ms"
    }

    private static func kHz(_ hertz: Double) -> String {
        "\((hertz / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz"
    }

    private static func rate(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    /// The app's page in the Settings app (Local Network and Notifications switches).
    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }

    // MARK: - Commit

    private func commitPairingCode() {
        let normalized = PairingKey.normalized(pairingCodeDraft)
        if normalized != settings.pairingCode {
            settings.pairingCode = normalized
        }
    }

    private func commitName() {
        let sanitized = DisplayName.sanitized(nameDraft)
        if sanitized != settings.displayName {
            settings.displayName = sanitized
        }
        if nameDraft != sanitized {
            nameDraft = sanitized
        }
    }
}
