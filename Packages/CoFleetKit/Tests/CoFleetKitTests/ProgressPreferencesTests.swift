import CoFleetCore
import Foundation
import XCTest

@MainActor
final class ProgressPreferencesTests: XCTestCase {
    func testUserDefaultsPreferenceStoreRoundTripsNamespacedPayload() {
        let suiteName = "org.cofleet.tests.progress.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let hostID = CoFleetHostID(rawValue: "sample-host")
        let expected = CoFleetProgressPreferences(
            orderedProjectIDs: ["project-b", "project-a"],
            hiddenProjectIDs: ["project-a"],
            collapsedHostIDs: [hostID]
        )
        CoFleetUserDefaultsProgressPreferencesStore(defaults: defaults).save(expected)

        let restored = CoFleetUserDefaultsProgressPreferencesStore(defaults: defaults).load()
        XCTAssertEqual(restored, expected)
        XCTAssertNotNil(defaults.data(forKey: CoFleetProgressPreferences.storageKey))
    }

    func testFleetOrganizationPersistsVisibilityOrderAndCollapsedHosts() async {
        let alpha = CoFleetHostID(rawValue: "alpha-host")
        let beta = CoFleetHostID(rawValue: "beta-host")
        let projects = [
            CoFleetProject(id: "project-a", hostID: alpha, displayName: "A", canonicalPath: "/tmp/a", sortIndex: 0),
            CoFleetProject(id: "project-b", hostID: alpha, displayName: "B", canonicalPath: "/tmp/b", sortIndex: 1),
            CoFleetProject(id: "project-c", hostID: beta, displayName: "C", canonicalPath: "/tmp/c", sortIndex: 2),
        ]
        let repository = ProgressFleetRepositoryFake(projects: projects)
        let preferences = InMemoryProgressPreferencesStore()
        let store = FleetStore(repository: repository, preferencesStore: preferences)

        await store.refresh()
        XCTAssertEqual(store.visibleProjectGroups.map(\.hostID), [alpha, beta])
        XCTAssertTrue(store.moveProject("project-b", before: "project-a"))
        XCTAssertFalse(store.moveProject("project-b", before: "project-c"), "A project cannot move between hosts")
        store.setVisibility(false, for: "project-a")
        store.setHostCollapsed(true, hostID: alpha)

        let restored = FleetStore(repository: repository, preferencesStore: preferences)
        await restored.refresh()
        XCTAssertEqual(
            restored.allProjectGroups.first(where: { $0.hostID == alpha })?.projects.map(\.id),
            ["project-b", "project-a"]
        )
        XCTAssertEqual(
            restored.visibleProjectGroups.first(where: { $0.hostID == alpha })?.projects.map(\.id),
            ["project-b"]
        )
        XCTAssertEqual(restored.visibilityState(forHost: alpha), .some)
        XCTAssertTrue(restored.isHostCollapsed(alpha))

        restored.setVisibility(true, forHost: alpha)
        XCTAssertEqual(restored.visibilityState(forHost: alpha), .all)
        restored.setVisibility(false, forHost: alpha)
        XCTAssertEqual(restored.visibilityState(forHost: alpha), .none)
    }

    func testFirstRefreshPreservesHostVisibilityThenMakesItClientLocal() async {
        let host = CoFleetHostID(rawValue: "sample-host")
        let hidden = CoFleetProject(
            id: "project-hidden",
            hostID: host,
            displayName: "Hidden",
            canonicalPath: "/tmp/hidden",
            isVisible: false
        )
        let preferences = InMemoryProgressPreferencesStore()
        let firstStore = FleetStore(
            repository: ProgressFleetRepositoryFake(projects: [hidden]),
            preferencesStore: preferences
        )
        await firstStore.refresh()
        XCTAssertTrue(firstStore.visibleProjects.isEmpty)

        var newlyVisibleFromHost = hidden
        newlyVisibleFromHost.isVisible = true
        let restored = FleetStore(
            repository: ProgressFleetRepositoryFake(projects: [newlyVisibleFromHost]),
            preferencesStore: preferences
        )
        await restored.refresh()
        XCTAssertTrue(restored.visibleProjects.isEmpty, "Host refreshes must not erase the user's local visibility choice")
    }
}

@MainActor
private final class InMemoryProgressPreferencesStore: CoFleetProgressPreferencesStoring {
    var value: CoFleetProgressPreferences?

    func load() -> CoFleetProgressPreferences? { value }
    func save(_ preferences: CoFleetProgressPreferences) { value = preferences }
}

private actor ProgressFleetRepositoryFake: CoFleetFleetRepository {
    let projects: [CoFleetProject]

    init(projects: [CoFleetProject]) {
        self.projects = projects
    }

    func fetchHosts() async throws -> [CoFleetHostInfo] {
        let hostIDs = Set(projects.map(\.hostID))
        return hostIDs.map { hostID in
            CoFleetHostInfo(
                id: hostID,
                displayName: hostID.rawValue.replacingOccurrences(of: "-", with: " ").capitalized,
                platform: "macOS",
                canonicalHome: "/Users/sample",
                reachability: .online
            )
        }
    }

    func fetchAccount(hostID: CoFleetHostID) async throws -> CoFleetAccountInfo {
        .init(hostID: hostID, authenticationType: "chatgpt", requiresOpenAIAuthentication: false)
    }

    func fetchAccountLimits(hostID: CoFleetHostID) async throws -> [CoFleetRateLimitInfo] { [] }
    func fetchProjects() async throws -> [CoFleetProject] { projects }

    func discoverRecentRoots(hostID: CoFleetHostID, cursor: String?) async throws -> CoFleetDirectoryPage {
        .init(canonicalPath: "/Users/sample", parentPath: "/Users", entries: [])
    }

    func browseDirectories(
        hostID: CoFleetHostID,
        path: String,
        cursor: String?,
        showHidden: Bool
    ) async throws -> CoFleetDirectoryPage {
        .init(canonicalPath: path, parentPath: "/", entries: [])
    }

    func createDirectory(
        hostID: CoFleetHostID,
        parent: String,
        name: String
    ) async throws -> CoFleetDirectoryEntry {
        .init(name: name, canonicalPath: "\(parent)/\(name)")
    }

    func registerProject(
        hostID: CoFleetHostID,
        canonicalPath: String,
        displayName: String
    ) async throws -> CoFleetProject {
        .init(hostID: hostID, displayName: displayName, canonicalPath: canonicalPath)
    }

    func removeProject(id: String) async throws {}
}
