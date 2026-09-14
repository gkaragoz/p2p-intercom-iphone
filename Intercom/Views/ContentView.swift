import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: IntercomController
    @EnvironmentObject private var settings: AppSettings
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    StatusCard(showSettings: { isShowingSettings = true })
                    PeerListView()
                    MetersCard()
                    ModePicker()
                        .padding(.horizontal, 4)
                }
                .padding()
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .safeAreaInset(edge: .bottom) {
                talkControls
                    .padding(.vertical, 12)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
            }
            .navigationTitle("Intercom")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if controller.isRunning {
                        Button {
                            controller.stop()
                        } label: {
                            Label("Stop", systemImage: "power")
                        }
                        .tint(.red)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $isShowingSettings) {
                SettingsView()
                    .environmentObject(controller)
                    .environmentObject(settings)
            }
        }
        // Starting on launch and the scene phase are handled at the App level (`IntercomApp`), so they
        // also work when iOS launches the app without building this view.
    }

    private var muteLabel: LocalizedStringKey {
        controller.isMuted ? "Unmute" : "Mute"
    }

    /// The talk button is centred; the mute button is overlaid at the leading edge so the bar
    /// fits 375-pt phones (iPhone SE / mini) without pushing anything off-screen.
    private var talkControls: some View {
        TalkButton()
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                Button {
                    controller.toggleMute()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: controller.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.title3)
                        Text(muteLabel)
                            .font(.caption2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .frame(width: 48)
                }
                .buttonStyle(.bordered)
                .tint(controller.isMuted ? .red : .secondary)
                .disabled(!controller.isRunning)
                .padding(.leading, 12)
            }
    }
}
