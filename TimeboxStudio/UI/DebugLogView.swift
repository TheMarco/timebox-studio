import SwiftUI
import TimeboxUtilities

struct DebugLogView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Debug Log")
                        .font(.headline)
                    Spacer()
                    Button {
                        appState.clearLogs()
                    } label: {
                        Label("Clear", systemImage: "trash")
                    }
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(appState.logEntries) { entry in
                                Text(entry.consoleLine)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(color(for: entry.level))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(entry.id)
                            }
                        }
                        .padding(8)
                    }
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(.separator, lineWidth: 1)
                    }
                    .onChange(of: appState.logEntries.count) { _ in
                        if let lastID = appState.logEntries.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
            .padding(4)
        }
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug:
            return .secondary
        case .info:
            return .primary
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }
}
