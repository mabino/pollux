import SwiftUI
import AppKit

struct ExtractionLogWindowView: View {
    @ObservedObject private var logger = ExtractionLogger.shared
    @State private var copiedNotice = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Extraction Log (\(logger.logs.count) entries)")
                    .font(.headline)
                    .foregroundStyle(.secondary)

                Spacer()

                if copiedNotice {
                    Text("Copied to Clipboard!")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                        .transition(.opacity)
                }

                Button("Copy Logs") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(logger.logText, forType: .string)
                    withAnimation {
                        copiedNotice = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation {
                            copiedNotice = false
                        }
                    }
                }
                .disabled(logger.logs.isEmpty)

                Button("Clear") {
                    logger.clear()
                }
                .disabled(logger.logs.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if logger.logs.isEmpty {
                            Text("No extraction log entries yet. Play a stream URL to see extraction events here.")
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .padding(16)
                        } else {
                            ForEach(Array(logger.logs.enumerated()), id: \.offset) { index, log in
                                Text(log)
                                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                                    .textSelection(.enabled)
                                    .foregroundColor(color(for: log))
                                    .id(index)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: logger.logs.count) {
                    if let lastIndex = logger.logs.indices.last {
                        withAnimation {
                            proxy.scrollTo(lastIndex, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 550, minHeight: 350)
    }

    private func color(for log: String) -> Color {
        if log.contains("FAILED") || log.contains("Error") || log.contains("timed out") || log.contains("404") || log.contains("401") || log.contains("403") {
            return .red
        } else if log.contains("SUCCESS") || log.contains("validated successfully") || log.contains("Found stream") || log.contains("Found iframe") {
            return .green
        } else if log.contains("CDP Request") || log.contains("CDP Response") {
            return .secondary
        } else if log.contains("Navigating") || log.contains("Clicking") || log.contains("Launching") {
            return .blue
        }
        return .primary
    }
}
