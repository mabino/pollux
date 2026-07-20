import Foundation
import Combine

@MainActor
final class ExtractionLogger: ObservableObject {
    static let shared = ExtractionLogger()

    @Published var logs: [String] = []

    var logText: String {
        logs.joined(separator: "\n")
    }

    func append(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let timestamp = formatter.string(from: Date())
        let entry = "[\(timestamp)] \(message)"
        logs.append(entry)
        print("[PolluxLog] \(entry)")
    }

    func clear() {
        logs.removeAll()
    }
}
