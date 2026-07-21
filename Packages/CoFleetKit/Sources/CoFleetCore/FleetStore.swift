import Foundation
import Observation

@MainActor
@Observable
public final class FleetStore {
    public private(set) var hosts: [CoFleetHostInfo] = []
    public private(set) var projects: [CoFleetProject] = []
    public private(set) var accounts: [CoFleetHostID: CoFleetAccountInfo] = [:]
    public private(set) var accountLimits: [CoFleetHostID: [CoFleetRateLimitInfo]] = [:]
    public private(set) var pairedDevices: [CoFleetHostID: [CoFleetPairedDevice]] = [:]
    public private(set) var currentPairedDeviceIDs: [CoFleetHostID: String] = [:]
    public private(set) var deviceOperationHostIDs: Set<CoFleetHostID> = []
    public private(set) var deviceErrorMessage: String?
    public private(set) var collapsedHostIDs: Set<CoFleetHostID> = []
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public var selectedProjectID: String?

    @ObservationIgnored private let repository: any CoFleetFleetRepository
    @ObservationIgnored private let preferencesStore: any CoFleetProgressPreferencesStoring
    @ObservationIgnored private var preferences: CoFleetProgressPreferences
    @ObservationIgnored private var hasStoredPreferences: Bool

    public init(
        repository: any CoFleetFleetRepository,
        preferencesStore: (any CoFleetProgressPreferencesStoring)? = nil
    ) {
        self.repository = repository
        let resolvedStore = preferencesStore ?? CoFleetUserDefaultsProgressPreferencesStore()
        self.preferencesStore = resolvedStore
        if let stored = resolvedStore.load() {
            preferences = stored
            collapsedHostIDs = stored.collapsedHostIDs
            hasStoredPreferences = true
        } else {
            preferences = .init()
            hasStoredPreferences = false
        }
    }

    public var orderedProjects: [CoFleetProject] {
        projects.sorted(by: projectSort)
    }

    public var visibleProjects: [CoFleetProject] {
        orderedProjects.filter(\.isVisible)
    }

    public var visibleProjectGroups: [CoFleetProjectGroup] {
        projectGroups(includingHidden: false)
    }

    public var allProjectGroups: [CoFleetProjectGroup] {
        projectGroups(includingHidden: true)
    }

    public var selectedProject: CoFleetProject? {
        guard let selectedProjectID else { return visibleProjects.first }
        return projects.first { $0.id == selectedProjectID }
    }

    public func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            async let hosts = repository.fetchHosts()
            async let projects = repository.fetchProjects()
            self.hosts = try await hosts
            applyPreferences(to: try await projects)
            pruneDeviceState()
            normalizeSelection()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func refreshAccountState() async {
        let onlineHostIDs = hosts.lazy.filter { $0.reachability != .offline }.map(\.id)
        let repository = repository
        let results = await withTaskGroup(of: AccountRefreshResult.self) { group in
            for hostID in onlineHostIDs {
                group.addTask {
                    do {
                        async let account = repository.fetchAccount(hostID: hostID)
                        async let limits = repository.fetchAccountLimits(hostID: hostID)
                        let (resolvedAccount, resolvedLimits) = try await (account, limits)
                        return AccountRefreshResult(
                            hostID: hostID,
                            account: resolvedAccount,
                            limits: resolvedLimits
                        )
                    } catch {
                        return AccountRefreshResult(hostID: hostID, account: nil, limits: nil)
                    }
                }
            }
            var values: [AccountRefreshResult] = []
            for await value in group { values.append(value) }
            return values
        }
        for result in results {
            accounts[result.hostID] = result.account
            accountLimits[result.hostID] = result.limits
        }
    }

    public func startChatGPTLogin(hostID: CoFleetHostID) async throws -> CoFleetLoginChallenge {
        try await repository.startChatGPTLogin(hostID: hostID)
    }

    public func refreshPairedDevices(hostID: CoFleetHostID) async {
        guard !deviceOperationHostIDs.contains(hostID) else { return }
        deviceOperationHostIDs.insert(hostID)
        defer { deviceOperationHostIDs.remove(hostID) }
        do {
            let devices = try await repository.fetchPairedDevices(hostID: hostID)
            let currentDeviceID = await repository.currentPairedDeviceID(hostID: hostID)
            pairedDevices[hostID] = devices.sorted(by: deviceSort)
            currentPairedDeviceIDs[hostID] = currentDeviceID
            deviceErrorMessage = nil
        } catch {
            deviceErrorMessage = error.localizedDescription
        }
    }

    public func rotateCurrentDevice(hostID: CoFleetHostID) async {
        guard !deviceOperationHostIDs.contains(hostID) else { return }
        deviceOperationHostIDs.insert(hostID)
        defer { deviceOperationHostIDs.remove(hostID) }
        do {
            let rotated = try await repository.rotateCurrentDevice(hostID: hostID)
            if let index = pairedDevices[hostID]?.firstIndex(where: { $0.id == rotated.id }) {
                pairedDevices[hostID]?[index] = rotated
            } else {
                pairedDevices[hostID, default: []].append(rotated)
            }
            pairedDevices[hostID] = (pairedDevices[hostID] ?? []).sorted(by: deviceSort)
            deviceErrorMessage = nil
        } catch {
            deviceErrorMessage = error.localizedDescription
        }
    }

    public func revokeCurrentDevice(hostID: CoFleetHostID) async {
        guard !deviceOperationHostIDs.contains(hostID) else { return }
        deviceOperationHostIDs.insert(hostID)
        defer { deviceOperationHostIDs.remove(hostID) }
        do {
            try await repository.revokeCurrentDevice(hostID: hostID)
            removeHostFromView(hostID)
            deviceErrorMessage = nil
        } catch {
            let message = error.localizedDescription
            // A host may have accepted the revocation even if local secure-item
            // cleanup failed. Reconcile with the repository before presenting it.
            await refresh()
            deviceErrorMessage = message
        }
    }

    public func clearDeviceError() {
        deviceErrorMessage = nil
    }

    public func isManagingDevices(hostID: CoFleetHostID) -> Bool {
        deviceOperationHostIDs.contains(hostID)
    }

    public func discoverRecentRoots(
        hostID: CoFleetHostID,
        cursor: String? = nil
    ) async throws -> CoFleetDirectoryPage {
        try await repository.discoverRecentRoots(hostID: hostID, cursor: cursor)
    }

    public func browseDirectories(
        hostID: CoFleetHostID,
        path: String,
        cursor: String? = nil,
        showHidden: Bool = false
    ) async throws -> CoFleetDirectoryPage {
        try await repository.browseDirectories(
            hostID: hostID,
            path: path,
            cursor: cursor,
            showHidden: showHidden
        )
    }

    public func createDirectory(
        hostID: CoFleetHostID,
        parent: String,
        name: String
    ) async throws -> CoFleetDirectoryEntry {
        try await repository.createDirectory(hostID: hostID, parent: parent, name: name)
    }

    @discardableResult
    public func registerProject(
        hostID: CoFleetHostID,
        canonicalPath: String,
        displayName: String
    ) async throws -> CoFleetProject {
        if let existing = projects.first(where: {
            $0.hostID == hostID && $0.canonicalPath == canonicalPath
        }) {
            throw CoFleetClientError.conflict("\(existing.displayName) is already registered.")
        }
        let registeredProject = try await repository.registerProject(
            hostID: hostID,
            canonicalPath: canonicalPath,
            displayName: displayName
        )
        var project = registeredProject
        project.isVisible = true
        project.sortIndex = (orderedProjects.map(\.sortIndex).max() ?? -1) + 1
        projects.append(project)
        preferences.orderedProjectIDs.append(project.id)
        preferences.hiddenProjectIDs.remove(project.id)
        persistPreferences()
        selectedProjectID = project.id
        return project
    }

    @discardableResult
    public func renameProject(id: String, displayName: String) async throws -> CoFleetProject {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw CoFleetClientError.conflict("Project names cannot be empty.")
        }
        guard let project = projects.first(where: { $0.id == id }) else {
            throw CoFleetClientError.unavailable("The project is no longer registered.")
        }

        let renamed = try await repository.renameProject(
            hostID: project.hostID,
            id: project.id,
            displayName: name
        )
        guard let index = projects.firstIndex(where: { $0.id == id }) else {
            return renamed
        }
        var updated = renamed
        updated.isVisible = projects[index].isVisible
        updated.sortIndex = projects[index].sortIndex
        projects[index] = updated
        return updated
    }

    public func removeProject(id: String) async throws {
        try await repository.removeProject(id: id)
        projects.removeAll { $0.id == id }
        preferences.orderedProjectIDs.removeAll { $0 == id }
        preferences.hiddenProjectIDs.remove(id)
        persistPreferences()
        normalizeSelection()
    }

    public func setVisibility(_ visible: Bool, for projectID: String) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].isVisible = visible
        if visible {
            preferences.hiddenProjectIDs.remove(projectID)
        } else {
            preferences.hiddenProjectIDs.insert(projectID)
        }
        persistPreferences()
        normalizeSelection()
    }

    public func setVisibility(_ visible: Bool, forHost hostID: CoFleetHostID) {
        let projectIDs = projects.lazy.filter { $0.hostID == hostID }.map(\.id)
        for projectID in projectIDs {
            guard let index = projects.firstIndex(where: { $0.id == projectID }) else { continue }
            projects[index].isVisible = visible
            if visible {
                preferences.hiddenProjectIDs.remove(projectID)
            } else {
                preferences.hiddenProjectIDs.insert(projectID)
            }
        }
        persistPreferences()
        normalizeSelection()
    }

    public func visibilityState(forHost hostID: CoFleetHostID) -> CoFleetHostVisibilityState {
        let hostProjects = projects.filter { $0.hostID == hostID }
        let visibleCount = hostProjects.lazy.filter(\.isVisible).count
        if visibleCount == 0 { return .none }
        if visibleCount == hostProjects.count { return .all }
        return .some
    }

    public func isHostCollapsed(_ hostID: CoFleetHostID) -> Bool {
        collapsedHostIDs.contains(hostID)
    }

    public func setHostCollapsed(_ collapsed: Bool, hostID: CoFleetHostID) {
        if collapsed {
            collapsedHostIDs.insert(hostID)
        } else {
            collapsedHostIDs.remove(hostID)
        }
        preferences.collapsedHostIDs = collapsedHostIDs
        persistPreferences()
    }

    public func toggleHostCollapsed(_ hostID: CoFleetHostID) {
        setHostCollapsed(!isHostCollapsed(hostID), hostID: hostID)
    }

    public func applyProjectUpdate(_ project: CoFleetProject) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        var updated = project
        updated.isVisible = projects[index].isVisible
        updated.sortIndex = projects[index].sortIndex
        projects[index] = updated
    }

    /// Reorders a card within its host group. Host identity is immutable, so drops from
    /// another host are deliberately rejected instead of implying that a project moved.
    @discardableResult
    public func moveProject(_ projectID: String, before targetProjectID: String) -> Bool {
        guard projectID != targetProjectID,
              let source = projects.first(where: { $0.id == projectID }),
              let target = projects.first(where: { $0.id == targetProjectID }),
              source.hostID == target.hostID else { return false }

        var hostProjects = orderedProjects.filter { $0.hostID == source.hostID }
        guard let sourceIndex = hostProjects.firstIndex(where: { $0.id == projectID }),
              let originalTargetIndex = hostProjects.firstIndex(where: { $0.id == targetProjectID }) else {
            return false
        }
        let moving = hostProjects.remove(at: sourceIndex)
        let targetIndex = sourceIndex < originalTargetIndex
            ? originalTargetIndex - 1
            : originalTargetIndex
        hostProjects.insert(moving, at: targetIndex)

        for (index, project) in hostProjects.enumerated() {
            guard let storedIndex = projects.firstIndex(where: { $0.id == project.id }) else { continue }
            projects[storedIndex].sortIndex = index
        }
        captureCurrentOrder()
        persistPreferences()
        return true
    }

    private func normalizeSelection() {
        guard let selectedProjectID,
              visibleProjects.contains(where: { $0.id == selectedProjectID }) else {
            self.selectedProjectID = visibleProjects.first?.id
            return
        }
    }

    private func pruneDeviceState() {
        let knownHostIDs = Set(hosts.map(\.id))
        pairedDevices = pairedDevices.filter { knownHostIDs.contains($0.key) }
        currentPairedDeviceIDs = currentPairedDeviceIDs.filter { knownHostIDs.contains($0.key) }
        deviceOperationHostIDs.formIntersection(knownHostIDs)
    }

    private func removeHostFromView(_ hostID: CoFleetHostID) {
        hosts.removeAll { $0.id == hostID }
        projects.removeAll { $0.hostID == hostID }
        accounts[hostID] = nil
        accountLimits[hostID] = nil
        pairedDevices[hostID] = nil
        currentPairedDeviceIDs[hostID] = nil
        collapsedHostIDs.remove(hostID)
        preferences.collapsedHostIDs.remove(hostID)
        captureCurrentOrder()
        preferences.hiddenProjectIDs.formIntersection(Set(projects.map(\.id)))
        persistPreferences()
        normalizeSelection()
    }

    private func deviceSort(_ lhs: CoFleetPairedDevice, _ rhs: CoFleetPairedDevice) -> Bool {
        if lhs.isRevoked != rhs.isRevoked { return !lhs.isRevoked }
        let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
        if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
        return lhs.createdAt > rhs.createdAt
    }

    private func applyPreferences(to fetchedProjects: [CoFleetProject]) {
        var fetchedProjects = fetchedProjects
        if !hasStoredPreferences {
            preferences = .init(
                orderedProjectIDs: fetchedProjects.sorted(by: projectSort).map(\.id),
                hiddenProjectIDs: Set(fetchedProjects.lazy.filter { !$0.isVisible }.map(\.id)),
                collapsedHostIDs: []
            )
            hasStoredPreferences = true
        }

        let rank = Dictionary(
            uniqueKeysWithValues: preferences.orderedProjectIDs.enumerated().map { ($1, $0) }
        )
        fetchedProjects.sort { lhs, rhs in
            switch (rank[lhs.id], rank[rhs.id]) {
            case let (.some(left), .some(right)):
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return projectSort(lhs, rhs)
            }
        }
        for index in fetchedProjects.indices {
            fetchedProjects[index].sortIndex = index
            fetchedProjects[index].isVisible = !preferences.hiddenProjectIDs.contains(fetchedProjects[index].id)
        }
        projects = fetchedProjects
        captureCurrentOrder()
        persistPreferences()
    }

    private func projectGroups(includingHidden: Bool) -> [CoFleetProjectGroup] {
        let candidates = includingHidden ? orderedProjects : visibleProjects
        let grouped = Dictionary(grouping: candidates, by: \.hostID)
        let hostLookup = Dictionary(uniqueKeysWithValues: hosts.map { ($0.id, $0) })
        return grouped.map { hostID, projects in
            CoFleetProjectGroup(hostID: hostID, host: hostLookup[hostID], projects: projects)
        }
        .sorted { lhs, rhs in
            let left = lhs.host?.displayName ?? lhs.hostID.rawValue
            let right = rhs.host?.displayName ?? rhs.hostID.rawValue
            let comparison = left.localizedStandardCompare(right)
            return comparison == .orderedSame
                ? lhs.hostID.rawValue < rhs.hostID.rawValue
                : comparison == .orderedAscending
        }
    }

    private func captureCurrentOrder() {
        preferences.orderedProjectIDs = orderedProjects.map(\.id)
    }

    private func persistPreferences() {
        hasStoredPreferences = true
        preferencesStore.save(preferences)
    }

    private func projectSort(_ lhs: CoFleetProject, _ rhs: CoFleetProject) -> Bool {
        if lhs.sortIndex != rhs.sortIndex { return lhs.sortIndex < rhs.sortIndex }
        let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
        return lhs.id < rhs.id
    }
}

private struct AccountRefreshResult: Sendable {
    var hostID: CoFleetHostID
    var account: CoFleetAccountInfo?
    var limits: [CoFleetRateLimitInfo]?
}
