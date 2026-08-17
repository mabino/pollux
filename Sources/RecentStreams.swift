import Combine
import Foundation

/// Identifies a request to open a Pollux stream window. A fresh `id` per instance guarantees the
/// value-based `WindowGroup` opens a *new* window each time (values are otherwise de-duplicated), while
/// `url` optionally seeds and auto-plays that window (used by Open Recent).
struct StreamRequest: Hashable, Codable {
    let id: UUID
    let url: String?

    init(url: String? = nil) {
        self.id = UUID()
        self.url = url
    }
}

/// Persists the most-recently opened stream page URLs for the File ▸ Open Recent menu.
@MainActor
final class RecentStreamsStore: ObservableObject {
    static let shared = RecentStreamsStore()

    private static let maxEntries = 10
    private let userDefaults: UserDefaults

    @Published private(set) var urls: [String]

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        self.urls = userDefaults.stringArray(forKey: PolluxPreferences.recentStreamsKey) ?? []
    }

    func add(_ rawURL: String) {
        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            return
        }

        // Most-recent first, case-insensitively de-duplicated, capped.
        var updated = urls.filter { $0.caseInsensitiveCompare(url) != .orderedSame }
        updated.insert(url, at: 0)
        if updated.count > Self.maxEntries {
            updated = Array(updated.prefix(Self.maxEntries))
        }

        urls = updated
        userDefaults.set(urls, forKey: PolluxPreferences.recentStreamsKey)
    }

    func clear() {
        urls = []
        userDefaults.removeObject(forKey: PolluxPreferences.recentStreamsKey)
    }
}
