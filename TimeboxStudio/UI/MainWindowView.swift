import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HSplitView {
            DevicePickerView()
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)

            VStack(spacing: 12) {
                ConnectionPanelView()
                BrightnessControlView()
                DebugLogView()
            }
            .padding(16)
            .frame(minWidth: 620)
        }
        .onAppear {
            appState.refreshDevices()
        }
    }
}
