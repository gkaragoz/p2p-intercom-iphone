import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var controller: IntercomController
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.scenePhase) private var scenePhase
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    StatusCard()
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
        .task {
            await controller.start()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase != .active {
                controller.releaseTalkButton()
            }
        }
    }

    private var talkControls: some View {
        HStack(alignment: .center, spacing: 28) {
            Button {
                controller.toggleMute()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: controller.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.title2)
                    Text(controller.isMuted ? "Unmute" : "Mute")
                        .font(.caption)
                }
                .frame(width: 64)
            }
            .buttonStyle(.bordered)
            .tint(controller.isMuted ? .red : .secondary)
            .disabled(!controller.isRunning)

            TalkButton()

            Color.clear
                .frame(width: 64, height: 1)
        }
    }
}
