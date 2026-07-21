import Foundation

/// The identity of a device-local note draft. Provider-native identifiers remain scoped
/// to their host, and a project note cannot collide with a session-specific note.
public struct CoFleetNoteDraftKey: Codable, Hashable, Sendable {
    public var hostID: CoFleetHostID
    public var projectID: String
    public var sessionID: String?

    public init(hostID: CoFleetHostID, projectID: String, sessionID: String?) {
        self.hostID = hostID
        self.projectID = projectID
        self.sessionID = sessionID
    }
}

/// A recoverable local edit and the host revision it was based on.
public struct CoFleetNoteDraftRecord: Codable, Hashable, Sendable {
    public var key: CoFleetNoteDraftKey
    public var markdown: String
    public var baseRevision: Int?
    public var baseETag: String?
    public var updatedAt: Date

    public init(
        key: CoFleetNoteDraftKey,
        markdown: String,
        baseRevision: Int?,
        baseETag: String?,
        updatedAt: Date = .now
    ) {
        self.key = key
        self.markdown = markdown
        self.baseRevision = baseRevision
        self.baseETag = baseETag
        self.updatedAt = updatedAt
    }
}

@MainActor
public protocol CoFleetNoteDraftStorage: AnyObject {
    func draft(for key: CoFleetNoteDraftKey) -> CoFleetNoteDraftRecord?
    @discardableResult
    func save(_ draft: CoFleetNoteDraftRecord) -> Bool
    func removeDraft(for key: CoFleetNoteDraftKey)
}

/// A small, namespaced device-local draft cache. It deliberately stores only unsaved
/// note edits, never credentials, host responses, or todo mutations.
@MainActor
public final class CoFleetUserDefaultsNoteDraftStorage: CoFleetNoteDraftStorage {
    public static let defaultNamespace = "org.cofleet.notes.local-drafts.v1"

    private let defaults: UserDefaults
    private let namespace: String
    private let maximumEntries: Int
    private let maximumDraftBytes: Int
    private let maximumTotalDraftBytes: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        namespace: String = CoFleetUserDefaultsNoteDraftStorage.defaultNamespace,
        maximumEntries: Int = 64,
        maximumDraftBytes: Int = 512 * 1_024,
        maximumTotalDraftBytes: Int = 2 * 1_024 * 1_024
    ) {
        self.defaults = defaults
        self.namespace = namespace
        self.maximumEntries = min(max(1, maximumEntries), 256)
        self.maximumDraftBytes = min(max(1, maximumDraftBytes), 2 * 1_024 * 1_024)
        self.maximumTotalDraftBytes = min(max(1, maximumTotalDraftBytes), 8 * 1_024 * 1_024)
    }

    public func draft(for key: CoFleetNoteDraftKey) -> CoFleetNoteDraftRecord? {
        records().first { $0.key == key }
    }

    @discardableResult
    public func save(_ draft: CoFleetNoteDraftRecord) -> Bool {
        guard draft.markdown.lengthOfBytes(using: .utf8) <= maximumDraftBytes else {
            return false
        }

        var values = records().filter { $0.key != draft.key }
        values.append(draft)
        values.sort { $0.updatedAt > $1.updatedAt }
        if values.count > maximumEntries {
            values.removeLast(values.count - maximumEntries)
        }
        while totalDraftBytes(values) > maximumTotalDraftBytes, values.count > 1 {
            values.removeLast()
        }
        guard totalDraftBytes(values) <= maximumTotalDraftBytes,
              let data = try? encoder.encode(values),
              data.count <= maximumEncodedBytes else {
            return false
        }
        defaults.set(data, forKey: namespace)
        return true
    }

    public func removeDraft(for key: CoFleetNoteDraftKey) {
        let values = records().filter { $0.key != key }
        guard !values.isEmpty else {
            defaults.removeObject(forKey: namespace)
            return
        }
        guard let data = try? encoder.encode(values) else { return }
        defaults.set(data, forKey: namespace)
    }

    private func records() -> [CoFleetNoteDraftRecord] {
        guard let data = defaults.data(forKey: namespace),
              data.count <= maximumEncodedBytes,
              let values = try? decoder.decode([CoFleetNoteDraftRecord].self, from: data) else {
            return []
        }
        return values
            .filter { $0.markdown.lengthOfBytes(using: .utf8) <= maximumDraftBytes }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(maximumEntries)
            .map { $0 }
    }

    private func totalDraftBytes(_ values: [CoFleetNoteDraftRecord]) -> Int {
        values.reduce(into: 0) { total, value in
            total += value.markdown.lengthOfBytes(using: .utf8)
        }
    }

    /// JSON escaping can expand Markdown, so the serialized envelope receives a
    /// separate hard cap while remaining proportional to the configured content cap.
    private var maximumEncodedBytes: Int {
        (maximumTotalDraftBytes * 2) + (maximumEntries * 2_048)
    }
}
