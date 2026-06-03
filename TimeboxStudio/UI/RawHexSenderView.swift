import SwiftUI

struct RawHexSenderView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Raw Hex Sender")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    appState.sendRawHex()
                } label: {
                    Label("Send", systemImage: "paperplane")
                }
                .disabled(!appState.isConnected || appState.isBusy)
            }

            TextEditor(text: $appState.rawHexInput)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 76, maxHeight: 110)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(.separator, lineWidth: 1)
                }

            VStack(alignment: .leading, spacing: 4) {
                Text("Last packet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(appState.lastPacketHex.isEmpty ? "-" : appState.lastPacketHex)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
