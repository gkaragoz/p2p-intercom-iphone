import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var controller: IntercomController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var nameDraft = ""
    @State private var pairingCodeDraft = ""

    var body: some View {
        NavigationStack {
            Form {
                nameSection
                connectionSection
                transmitSection
                audioSection
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
        case .wifiOff?, nil:
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
        case .wifiOff:
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
            Toggle("Keep screen awake", isOn: $settings.keepScreenAwake)
        } header: {
            Text("Audio")
        } footer: {
            Text("The automatic buffer follows the measured Wi‑Fi jitter; a fixed higher value survives hiccups better but adds delay. Use Compatible capture only if the microphone does not work. Voice processing removes echo from the loudspeaker; turn it off only with headphones.")
        }
    }

    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            LabeledContent("Engine", value: settings.transportKind.displayName)
            LabeledContent("Output route", value: controller.route.outputName.isEmpty ? "—" : controller.route.outputName)
            LabeledContent("Input format", value: controller.inputDescription.isEmpty ? "—" : controller.inputDescription)
            if let version = controller.connectedPeers.compactMap(\.appVersion).first {
                LabeledContent("Peer app version", value: version)
            }
            LabeledContent("Frames sent", value: controller.framesSent.formatted())
            LabeledContent("Frames received", value: controller.statistics.received.formatted())
            LabeledContent("Buffered", value: controller.statistics.bufferedFrames.formatted())
            LabeledContent("Concealed", value: controller.statistics.concealed.formatted())
            LabeledContent("Late", value: (controller.statistics.lateDropped + controller.statistics.overflowDropped + controller.statistics.trimmed).formatted())
            LabeledContent("Underruns", value: controller.statistics.underruns.formatted())
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
            LabeledContent("Protocol", value: "v\(IntercomProtocol.version) · PCM 16 kHz")
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
