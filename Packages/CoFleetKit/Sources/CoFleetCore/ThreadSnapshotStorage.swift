import Foundation

/// Device-local identity for a cached Codex catalog and conversation preview.
/// Provider-native identifiers remain scoped to the host that produced them.
public struct CoFleetThreadSnapshotKey: Codable, Hashable, Sendable {
    public var hostID: CoFleetHostID
    public var projectID: String

    public init(hostID: CoFleetHostID, projectID: String) {
        self.hostID = hostID
        self.projectID = projectID
    }
}

/// A deliberately small stale-while-revalidate snapshot. It contains no host
/// endpoint, bearer token, account state, or other credential material.
public struct CoFleetThreadSnapshot: Codable, Hashable, Sendable {
    public var key: CoFleetThreadSnapshotKey
    public var sessions: [CoFleetSessionSummary]
    public var preview: CoFleetProjectConversationPreview?
    public var savedAt: Date

    public init(
        key: CoFleetThreadSnapshotKey,
        sessions: [CoFleetSessionSummary],
        preview: CoFleetProjectConversationPreview?,
        savedAt: Date = .now
    ) {
        self.key = key
        self.sessions = sessions
            .filter { $0.hostID == key.hostID && $0.projectID == key.projectID }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(5)
            .map { $0 }
        if let preview,
           preview.session.hostID == key.hostID,
           preview.session.projectID == key.projectID {
            self.preview = CoFleetProjectConversationPreview(
                session: preview.session,
                messages: preview.messages
            )
        } else {
            self.preview = nil
        }
        self.savedAt = savedAt
    }

    fileprivate var normalized: Self {
        Self(key: key, sessions: sessions, preview: preview, savedAt: savedAt)
    }
}

@MainActor
public protocol CoFleetThreadSnapshotStorage: AnyObject {
    func snapshot(for key: CoFleetThreadSnapshotKey) -> CoFleetThreadSnapshot?
    @discardableResult
    func save(_ snapshot: CoFleetThreadSnapshot) -> Bool
}

/// The package default is intentionally process-local so independently-created
/// stores and unit tests cannot leak session data into one another.
@MainActor
public final class CoFleetInMemoryThreadSnapshotStorage: CoFleetThreadSnapshotStorage {
    private var snapshots: [CoFleetThreadSnapshotKey: CoFleetThreadSnapshot] = [:]
    private let maximumEntries: Int

    public init(maximumEntries: Int = 64) {
        self.maximumEntries = min(max(1, maximumEntries), 256)
    }

    public func snapshot(for key: CoFleetThreadSnapshotKey) -> CoFleetThreadSnapshot? {
        snapshots[key]?.normalized
    }

    @discardableResult
    public func save(_ snapshot: CoFleetThreadSnapshot) -> Bool {
        let value = snapshot.normalized
        snapshots[value.key] = value
        if snapshots.count > maximumEntries,
           let oldest = snapshots.values.min(by: { $0.savedAt < $1.savedAt }) {
            snapshots[oldest.key] = nil
        }
        return true
    }
}

/// A bounded, namespaced cache used by the Apple applications. Corrupt or
/// oversized payloads are ignored and replaced by the next successful refresh.
@MainActor
public final class CoFleetUserDefaultsThreadSnapshotStorage: CoFleetThreadSnapshotStorage {
    public static let defaultNamespace = "org.cofleet.threads.snapshots.v1"

    private let defaults: UserDefaults
    private let namespace: String
    private let maximumEntries: Int
    private let maximumEncodedBytes: Int
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        namespace: String = CoFleetUserDefaultsThreadSnapshotStorage.defaultNamespace,
        maximumEntries: Int = 64,
        maximumEncodedBytes: Int = 1 * 1_024 * 1_024
    ) {
        self.defaults = defaults
        self.namespace = namespace
        self.maximumEntries = min(max(1, maximumEntries), 256)
        self.maximumEncodedBytes = min(max(4_096, maximumEncodedBytes), 8 * 1_024 * 1_024)
    }

    public func snapshot(for key: CoFleetThreadSnapshotKey) -> CoFleetThreadSnapshot? {
        records().first { $0.key == key }
    }

    @discardableResult
    public func save(_ snapshot: CoFleetThreadSnapshot) -> Bool {
        let value = snapshot.normalized
        var values = records().filter { $0.key != value.key }
        values.append(value)
        values.sort { $0.savedAt > $1.savedAt }
        if values.count > maximumEntries {
            values.removeLast(values.count - maximumEntries)
        }

        while let data = try? encoder.encode(values),
              data.count > maximumEncodedBytes,
              values.count > 1 {
            values.removeLast()
        }
        guard let data = try? encoder.encode(values),
              data.count <= maximumEncodedBytes else {
            return false
        }
        defaults.set(data, forKey: namespace)
        return true
    }

    private func records() -> [CoFleetThreadSnapshot] {
        guard let data = defaults.data(forKey: namespace),
              data.count <= maximumEncodedBytes,
              let decoded = try? decoder.decode([CoFleetThreadSnapshot].self, from: data) else {
            return []
        }
        return decoded
            .map(\.normalized)
            .sorted { $0.savedAt > $1.savedAt }
            .prefix(maximumEntries)
            .map { $0 }
    }
}
