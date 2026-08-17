import Combine
import Foundation

/// Persistent library of previously extracted streams. Records are saved on a successful extraction
/// and can be recalled to fast-path playback without launching Chromium (see
/// `PolluxAppModel.playRecord`). This is the storage scaffolding; a browsing UI can be layered on top
/// of `records` later.
///
/// Records carry the captured headers and cookies, which can include short-lived auth tokens, so they
/// are persisted in the app's user defaults (plaintext on disk). Recalled playback only succeeds while
/// those tokens remain valid.
@MainActor
final class StreamLibraryStore: ObservableObject {
    static let shared = StreamLibraryStore()

    /// Retention limits offered in Settings: keep none, 5, 20 (default), or 50 previous streams.
    static let retentionChoices = [0, 5, 20, 50]
    static let defaultRetention = 20

    private let userDefaults: UserDefaults

    /// Most-recent-first list of saved streams.
    @Published private(set) var records: [StreamRecord]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.records = Self.load(from: userDefaults)
    }

    /// How many previous streams to keep, from user defaults. Defaults to 20 when unset.
    var retentionLimit: Int {
        (userDefaults.object(forKey: PolluxPreferences.streamLibraryRetentionKey) as? Int) ?? Self.defaultRetention
    }

    /// Inserts a record at the front, de-duplicating by stream URL (a re-extraction of the same stream
    /// replaces the older entry and moves it to the top), then trims to the retention limit.
    func add(_ record: StreamRecord) {
        var updated = records.filter { $0.streamURL != record.streamURL }
        updated.insert(record, at: 0)
        records = trimmed(updated)
        persist()
    }

    /// Re-applies the current retention limit to the stored list. Call after the setting changes so a
    /// lowered limit takes effect immediately.
    func enforceRetentionLimit() {
        let capped = trimmed(records)
        guard capped.count != records.count else {
            return
        }
        records = capped
        persist()
    }

    private func trimmed(_ list: [StreamRecord]) -> [StreamRecord] {
        let limit = max(0, retentionLimit)
        return limit >= list.count ? list : Array(list.prefix(limit))
    }

    func remove(id: UUID) {
        records.removeAll { $0.id == id }
        persist()
    }

    func clear() {
        records = []
        persist()
    }

    /// The most recent saved record for a given stream URL, if any.
    func record(forStreamURL streamURL: String) -> StreamRecord? {
        records.first { $0.streamURL == streamURL }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else {
            return
        }
        userDefaults.set(data, forKey: PolluxPreferences.streamLibraryKey)
    }

    private static func load(from userDefaults: UserDefaults) -> [StreamRecord] {
        guard
            let data = userDefaults.data(forKey: PolluxPreferences.streamLibraryKey),
            let decoded = try? JSONDecoder().decode([StreamRecord].self, from: data)
        else {
            return []
        }
        return decoded
    }
}
