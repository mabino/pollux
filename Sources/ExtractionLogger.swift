import Foundation
import Combine

@MainActor
final class ExtractionLogger: ObservableObject {
    static let shared = ExtractionLogger()

    /// Hard cap on retained entries. Extraction against a chatty page (and the CDP network firehose)
    /// can emit thousands of lines; without a bound the array — and the SwiftUI view rebuilding it —
    /// grows without limit and saturates the main thread.
    private static let maxEntries = 2000

    // A single reused formatter. Allocating a DateFormatter per append is expensive and, under a
    // burst of log lines, becomes a main-thread bottleneck on its own.
    private let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    @Published var logs: [String] = []

    var logText: String {
        logs.joined(separator: "\n")
    }

    func append(_ message: String) {
        let timestamp = timestampFormatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        logs.append(entry)
        if logs.count > Self.maxEntries {
            logs.removeFirst(logs.count - Self.maxEntries)
        }
        print("[PolluxLog] \(entry)")
    }

    func clear() {
        logs.removeAll()
    }
}
