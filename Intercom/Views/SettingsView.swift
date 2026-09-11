import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var controller: IntercomController
    @Environment(\.dismiss) private var dismiss
    @State private var nameDraft = ""

    var body: some View {
        NavigationStack {
            Form {
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

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Playout buffer")
                            Spacer()
                            Text(verbatim: "\(Int(settings.jitterTargetMs)) ms")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.jitterTargetMs, in: AppSettings.jitterRangeMs, step: 20)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Volume")
                            Spacer()
                            Text(verbatim: "\(Int((settings.outputVolume * 100).rounded())) %")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.outputVolume, in: 0...1, step: 0.05)
                    }
                    Toggle("Keep screen awake", isOn: $settings.keepScreenAwake)
                } header: {
                    Text("Audio")
                } footer: {
                    Text("Higher buffer values survive Wi‑Fi hiccups better but add delay.")
                }

                Section("Diagnostics") {
                    LabeledContent("Output route", value: controller.route.outputName.isEmpty ? "—" : controller.route.outputName)
                    LabeledContent("Input format", value: controller.inputDescription.isEmpty ? "—" : controller.inputDescription)
                    LabeledContent("Round trip", value: controller.roundTripMs.map { "\(Int($0.rounded())) ms" } ?? "—")
                    LabeledContent("Frames sent", value: "\(controller.framesSent)")
                    LabeledContent("Frames received", value: "\(controller.statistics.received)")
                    LabeledContent("Buffered", value: "\(controller.statistics.bufferedFrames)")
                    LabeledContent("Concealed", value: "\(controller.statistics.concealed)")
                    LabeledContent("Late", value: "\(controller.statistics.lateDropped + controller.statistics.overflowDropped + controller.statistics.trimmed)")
                    LabeledContent("Underruns", value: "\(controller.statistics.underruns)")
                }

                Section("About") {
                    LabeledContent("Version", value: IntercomController.appVersion)
                    LabeledContent("Protocol", value: "v\(IntercomProtocol.version) · PCM 16 kHz")
                    if let url = URL(string: "https://github.com/gkaragoz/p2p-intercom-iphone") {
                        Link("Source code on GitHub", destination: url)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        commitName()
                        dismiss()
                    }
                }
            }
            .onAppear {
                nameDraft = settings.displayName
            }
            .onDisappear(perform: commitName)
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
