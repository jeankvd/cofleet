import Foundation

/// Device-local presentation choices for the Progress workspace.
///
/// Project registration remains host-authoritative. These preferences only control how
/// the paired client arranges and filters the cards it has already fetched.
public struct CoFleetProgressPreferences: Codable, Equatable, Sendable {
    public static let storageKey = "org.cofleet.codex.progress-organization.v1"

    public var orderedProjectIDs: [String]
    public var hiddenProjectIDs: Set<String>
    public var collapsedHostIDs: Set<CoFleetHostID>

    public init(
        orderedProjectIDs: [String] = [],
        hiddenProjectIDs: Set<String> = [],
        collapsedHostIDs: Set<CoFleetHostID> = []
    ) {
        self.orderedProjectIDs = orderedProjectIDs
        self.hiddenProjectIDs = hiddenProjectIDs
        self.collapsedHostIDs = collapsedHostIDs
    }
}

@MainActor
public protocol CoFleetProgressPreferencesStoring: AnyObject {
    func load() -> CoFleetProgressPreferences?
    func save(_ preferences: CoFleetProgressPreferences)
}

@MainActor
public final class CoFleetUserDefaultsProgressPreferencesStore: CoFleetProgressPreferencesStoring {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(
        defaults: UserDefaults = .standard,
        key: String = CoFleetProgressPreferences.storageKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> CoFleetProgressPreferences? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? decoder.decode(CoFleetProgressPreferences.self, from: data)
    }

    public func save(_ preferences: CoFleetProgressPreferences) {
        guard let data = try? encoder.encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}

public struct CoFleetProjectGroup: Identifiable, Hashable, Sendable {
    public var hostID: CoFleetHostID
    public var host: CoFleetHostInfo?
    public var projects: [CoFleetProject]

    public var id: CoFleetHostID { hostID }

    public init(
        hostID: CoFleetHostID,
        host: CoFleetHostInfo?,
        projects: [CoFleetProject]
    ) {
        self.hostID = hostID
        self.host = host
        self.projects = projects
    }
}

public enum CoFleetHostVisibilityState: Equatable, Sendable {
    case all
    case some
    case none
}
