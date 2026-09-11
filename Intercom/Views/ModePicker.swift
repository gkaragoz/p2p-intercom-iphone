import SwiftUI

struct ModePicker: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: $settings.transmitMode) {
                ForEach(TransmitMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(settings.transmitMode.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
