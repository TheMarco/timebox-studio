import SwiftUI

struct BrightnessControlView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GroupBox("Brightness") {
            HStack(spacing: 12) {
                Slider(value: $appState.brightnessPercent, in: 0...100, step: 1)
                Text("\(Int(appState.brightnessPercent.rounded()))%")
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 48, alignment: .trailing)
                Button {
                    appState.sendBrightness()
                } label: {
                    Label("Send Brightness", systemImage: "sun.max")
                }
                .disabled(!appState.isConnected || appState.isBusy)

                Button {
                    appState.clearDisplayPlaceholder()
                } label: {
                    Label("Clear Display", systemImage: "square")
                }
            }
            .padding(4)
        }
    }
}
