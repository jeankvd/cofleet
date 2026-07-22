import CoFleetCore
import CoFleetTransport
import Foundation

public actor CoFleetAppRepository: CoFleetFleetRepository, CoFleetThreadRepository, CoFleetTurnRepository, CoFleetHostEventRepository, CoFleetWorkspaceRepository {
    private let tokenVault: any CoFleetTokenVault
    private let defaults: UserDefaults
    private let recordsKey = "CoFleet.hostRecords.v1"
    private var records: [CoFleetHostID: CoFleetStoredHostPairing]
    private var services: [CoFleetHostID: CoFleetHostService] = [:]
    private var credentials: [CoFleetHostID: CoFleetHostCredential] = [:]
    private var projectHosts: [String: CoFleetHostID] = [:]

    public init(
        tokenVault: any CoFleetTokenVault = CoFleetKeychainTokenVault(),
        defaultsSuiteName: String? = nil
    ) {
        self.tokenVault = tokenVault
        let defaults = defaultsSuiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.defaults = defaults
        if let data = defaults.data(forKey: recordsKey),
           let decoded = try? JSONDecoder().decode([CoFleetStoredHostPairing].self, from: data) {
            records = Dictionary(uniqueKeysWithValues: decoded.map { ($0.host.id, $0) })
        } else {
            records = [:]
        }
    }

    public func pair(_ input: CoFleetPairingInputValue) async throws -> CoFleetHostInfo {
        let endpoint = try CoFleetHostEndpoint(baseURL: input.endpoint)
        let unauthenticatedClient = CoFleetAPIClient(endpoint: endpoint) { nil }
        let service = CoFleetHostService(client: unauthenticatedClient)
        let receipt = try await service.pair(code: input.code, deviceName: input.deviceName)

        let record = CoFleetStoredHostPairing(
            host: receipt.host,
            endpoint: input.endpoint,
            deviceID: receipt.deviceID
        )
        var nextRecords = records
        nextRecords[receipt.host.id] = record
        let encodedRecords = try JSONEncoder().encode(Array(nextRecords.values))

        let credential = credentials[receipt.host.id]
            ?? CoFleetHostCredential(hostID: receipt.host.id, vault: tokenVault)
        let rollbackClient = CoFleetAPIClient(endpoint: endpoint) { receipt.token }
        let rollbackService = CoFleetHostService(client: rollbackClient)
        do {
            try await credential.installPairingToken(receipt.token) {
                try await rollbackService.revokeDevice(id: receipt.deviceID)
            }
        } catch let error as CoFleetPairingCredentialError {
            if case .recoveryRequired = error {
                // Rollback failed, so retain a usable in-process route. The token is
                // deliberately only inside CoFleetHostCredential, never UserDefaults.
                credentials[receipt.host.id] = credential
                records = nextRecords
                services[receipt.host.id] = try makeService(record: record)
                defaults.set(encodedRecords, forKey: recordsKey)
            }
            throw CoFleetClientError.transport(error.localizedDescription)
        }
        credentials[receipt.host.id] = credential
        records = nextRecords
        services[receipt.host.id] = try makeService(record: record)
        defaults.set(encodedRecords, forKey: recordsKey)
        return receipt.host
    }

    public func fetchHosts() async throws -> [CoFleetHostInfo] {
        let entries = try serviceEntries()
        let results = await withTaskGroup(of: HostFetchResult.self) { group in
            for entry in entries {
                group.addTask {
                    do {
                        let host = try await entry.service.fetchHosts().first ?? entry.record.host
                        return HostFetchResult(id: entry.id, host: host)
                    } catch {
                        var offline = entry.record.host
                        offline.reachability = .offline
                        return HostFetchResult(id: entry.id, host: offline)
                    }
                }
            }
            var values: [HostFetchResult] = []
            for await value in group { values.append(value) }
            return values
        }
        for result in results {
            records[result.id]?.host = result.host
        }
        try? persistRecords()
        return results.map(\.host).sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func fetchAccount(hostID: CoFleetHostID) async throws -> CoFleetAccountInfo {
        try await service(for: hostID).fetchAccount(hostID: hostID)
    }

    public func fetchAccountLimits(hostID: CoFleetHostID) async throws -> [CoFleetRateLimitInfo] {
        try await service(for: hostID).fetchAccountLimits(hostID: hostID)
    }

    public func startChatGPTLogin(hostID: CoFleetHostID) async throws -> CoFleetLoginChallenge {
        try await service(for: hostID).startChatGPTLogin(hostID: hostID)
    }

    public func fetchPairedDevices(hostID: CoFleetHostID) async throws -> [CoFleetPairedDevice] {
        try await service(for: hostID).fetchPairedDevices(hostID: hostID)
    }

    public func currentPairedDeviceID(hostID: CoFleetHostID) async -> String? {
        records[hostID]?.deviceID
    }

    public func rotateCurrentDevice(hostID: CoFleetHostID) async throws -> CoFleetPairedDevice {
        guard let deviceID = records[hostID]?.deviceID else {
            throw CoFleetClientError.incompatible(
                "This pairing predates device management. Remove it locally and pair the host again before rotating its token."
            )
        }

        let receipt = try await service(for: hostID).rotateDevice(id: deviceID)
        let credential = credential(for: hostID)
        do {
            // The credential exposes the new token to in-flight app work before awaiting
            // the atomic Keychain update, and this method does not report success until
            // secure persistence completes.
            try await credential.install(token: receipt.token)
        } catch {
            throw CoFleetClientError.transport(
                "The host rotated this device token, but Keychain could not save it. "
                    + "CoFleet will retain access only while this app remains open. "
                    + "Fix Keychain access and rotate again before quitting. \(error.localizedDescription)"
            )
        }
        return receipt.device
    }

    public func revokeCurrentDevice(hostID: CoFleetHostID) async throws {
        guard let record = records[hostID], let deviceID = record.deviceID else {
            throw CoFleetClientError.incompatible(
                "This pairing predates device management. Re-pair the host before removing this device."
            )
        }

        try await service(for: hostID).revokeDevice(id: deviceID)

        let credential = credential(for: hostID)
        var cleanupError: Error?
        do {
            try await credential.remove()
        } catch {
            cleanupError = error
        }

        records[hostID] = nil
        services[hostID] = nil
        credentials[hostID] = nil
        projectHosts = projectHosts.filter { $0.value != hostID }
        try persistRecords()

        if let cleanupError {
            throw CoFleetClientError.transport(
                "This device was revoked and the host was removed from CoFleet, but its obsolete Keychain item could not be deleted. "
                    + cleanupError.localizedDescription
            )
        }
    }

    public func fetchModels() async -> [CoFleetModelInfo] {
        let entries = (try? serviceEntries()) ?? []
        let pages = await withTaskGroup(of: [CoFleetModelInfo].self) { group in
            for entry in entries {
                group.addTask { (try? await entry.service.fetchModels()) ?? [] }
            }
            var values: [[CoFleetModelInfo]] = []
            for await value in group { values.append(value) }
            return values
        }
        var modelsByID: [String: CoFleetModelInfo] = [:]
        for models in pages { for model in models { modelsByID[model.id] = model } }
        return modelsByID.values.sorted { $0.displayName < $1.displayName }
    }

    public func fetchModels(hostID: CoFleetHostID) async -> [CoFleetModelInfo] {
        ((try? await service(for: hostID).fetchModels()) ?? [])
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public func localHostID() -> CoFleetHostID? {
        records.values.first { record in
            guard let host = record.endpoint.host?.lowercased() else { return false }
            return host == "localhost" || host == "127.0.0.1" || host == "::1"
        }?.host.id
    }

    public func fetchProjects() async throws -> [CoFleetProject] {
        let entries = try serviceEntries()
        let pages = await withTaskGroup(of: ProjectFetchResult.self) { group in
            for entry in entries {
                group.addTask {
                    ProjectFetchResult(
                        hostID: entry.id,
                        projects: (try? await entry.service.fetchProjects()) ?? []
                    )
                }
            }
            var values: [ProjectFetchResult] = []
            for await value in group { values.append(value) }
            return values
        }
        var projects: [CoFleetProject] = []
        for page in pages {
            for project in page.projects { projectHosts[project.id] = page.hostID }
            projects.append(contentsOf: page.projects)
        }
        return projects.sorted { $0.sortIndex < $1.sortIndex }
    }

    public func discoverRecentRoots(
        hostID: CoFleetHostID,
        cursor: String?
    ) async throws -> CoFleetDirectoryPage {
        try await service(for: hostID).discoverRecentRoots(cursor: cursor)
    }

    public func browseDirectories(
        hostID: CoFleetHostID,
        path: String,
        cursor: String?,
        showHidden: Bool
    ) async throws -> CoFleetDirectoryPage {
        try await service(for: hostID).browseDirectories(
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
        try await service(for: hostID).createDirectory(parent: parent, name: name)
    }

    public func registerProject(hostID: CoFleetHostID, canonicalPath: String, displayName: String) async throws -> CoFleetProject {
        let project = try await service(for: hostID).registerProject(
            hostID: hostID,
            canonicalPath: canonicalPath,
            displayName: displayName
        )
        projectHosts[project.id] = hostID
        return project
    }

    public func renameProject(
        hostID: CoFleetHostID,
        id: String,
        displayName: String
    ) async throws -> CoFleetProject {
        guard projectHosts[id] == hostID else { throw unknownHost() }
        let project = try await service(for: hostID).renameProject(
            hostID: hostID,
            id: id,
            displayName: displayName
        )
        projectHosts[project.id] = hostID
        return project
    }

    public func removeProject(id: String) async throws {
        guard let hostID = projectHosts[id] else { throw unknownHost() }
        try await service(for: hostID).removeProject(id: id)
        projectHosts[id] = nil
    }

    public func fetchSessions(hostID: CoFleetHostID, projectID: String, cursor: String?, limit: Int, archived: Bool) async throws -> CoFleetSessionPage {
        try await service(for: hostID).fetchSessions(
            hostID: hostID,
            projectID: projectID,
            cursor: cursor,
            limit: limit,
            archived: archived
        )
    }

    public func createSession(hostID: CoFleetHostID, projectID: String) async throws -> CoFleetSessionSummary {
        try await service(for: hostID).createSession(hostID: hostID, projectID: projectID)
    }

    public func createSession(
        hostID: CoFleetHostID,
        projectID: String,
        settings: CoFleetSessionSettings
    ) async throws -> CoFleetSessionSummary {
        try await service(for: hostID).createSession(
            hostID: hostID,
            projectID: projectID,
            settings: settings
        )
    }

    public func resumeSession(hostID: CoFleetHostID, projectID: String, sessionID: String, settings: CoFleetSessionSettings) async throws -> CoFleetSessionSummary {
        try await service(for: hostID).resumeSession(hostID: hostID, projectID: projectID, sessionID: sessionID, settings: settings)
    }

    public func forkSession(hostID: CoFleetHostID, projectID: String, sessionID: String, settings: CoFleetSessionSettings) async throws -> CoFleetSessionSummary {
        try await service(for: hostID).forkSession(hostID: hostID, projectID: projectID, sessionID: sessionID, settings: settings)
    }

    public func renameSession(hostID: CoFleetHostID, sessionID: String, title: String) async throws {
        try await service(for: hostID).renameSession(hostID: hostID, sessionID: sessionID, title: title)
    }

    public func openSessionInCodex(hostID: CoFleetHostID, sessionID: String) async throws {
        try await service(for: hostID).openSessionInCodex(hostID: hostID, sessionID: sessionID)
    }

    public func archiveSession(hostID: CoFleetHostID, sessionID: String) async throws {
        try await service(for: hostID).archiveSession(hostID: hostID, sessionID: sessionID)
    }

    public func unarchiveSession(hostID: CoFleetHostID, sessionID: String) async throws {
        try await service(for: hostID).unarchiveSession(hostID: hostID, sessionID: sessionID)
    }

    public func fetchTranscript(hostID: CoFleetHostID, sessionID: String) async throws -> [CoFleetTurnItem] {
        try await service(for: hostID).fetchTranscript(hostID: hostID, sessionID: sessionID)
    }

    public func fetchInteractions(
        hostID: CoFleetHostID,
        sessionID: String
    ) async throws -> [CoFleetInteraction] {
        try await service(for: hostID).fetchInteractions(hostID: hostID, sessionID: sessionID)
    }

    public func startTurn(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String,
        input: [CoFleetTurnInput],
        settings: CoFleetSessionSettings,
        idempotencyKey: UUID
    ) async throws -> CoFleetTurn {
        try await service(for: hostID).startTurn(
            hostID: hostID,
            projectID: projectID,
            sessionID: sessionID,
            input: input,
            settings: settings,
            idempotencyKey: idempotencyKey
        )
    }

    public func interruptTurn(hostID: CoFleetHostID, sessionID: String, turnID: String) async throws {
        try await service(for: hostID).interruptTurn(hostID: hostID, sessionID: sessionID, turnID: turnID)
    }

    public func resolveInteraction(
        hostID: CoFleetHostID,
        interactionID: String,
        decision: CoFleetInteractionDecision,
        answers: [String: [String]]?
    ) async throws {
        try await service(for: hostID).resolveInteraction(
            hostID: hostID,
            interactionID: interactionID,
            decision: decision,
            answers: answers
        )
    }

    public func events(
        hostID: CoFleetHostID,
        sessionID: String,
        afterEventID: String?
    ) async throws -> AsyncThrowingStream<CoFleetSequencedTurnEvent, Error> {
        try await service(for: hostID).events(
            hostID: hostID,
            sessionID: sessionID,
            afterEventID: afterEventID
        )
    }

    public func hostEvents(
        hostID: CoFleetHostID,
        afterEventID: String?
    ) async throws -> AsyncThrowingStream<CoFleetSequencedHostEvent, Error> {
        try await service(for: hostID).hostEvents(
            hostID: hostID,
            afterEventID: afterEventID
        )
    }

    public func fetchNote(hostID: CoFleetHostID, projectID: String, sessionID: String?) async throws -> CoFleetNote {
        try await service(for: hostID).fetchNote(hostID: hostID, projectID: projectID, sessionID: sessionID)
    }

    public func saveNote(_ note: CoFleetNote, expectedETag: String) async throws -> CoFleetNoteSaveResult {
        try await service(for: note.hostID).saveNote(note, expectedETag: expectedETag)
    }

    public func fetchTodos(hostID: CoFleetHostID, projectID: String) async throws -> [CoFleetTodoItem] {
        try await service(for: hostID).fetchTodos(hostID: hostID, projectID: projectID)
    }

    public func saveTodo(_ todo: CoFleetTodoItem, expectedETag: String?) async throws -> CoFleetTodoItem {
        try await service(for: todo.hostID).saveTodo(todo, expectedETag: expectedETag)
    }

    public func deleteTodo(hostID: CoFleetHostID, id: String, expectedETag: String) async throws {
        try await service(for: hostID).deleteTodo(hostID: hostID, id: id, expectedETag: expectedETag)
    }

    public func fetchPets(hostID: CoFleetHostID) async throws -> [CoFleetPetManifest] {
        try await service(for: hostID).fetchPets(hostID: hostID)
    }

    public func discoverPets(hostID: CoFleetHostID) async throws -> [CoFleetDiscoveredPet] {
        try await service(for: hostID).discoverPets(hostID: hostID)
    }

    public func importPet(hostID: CoFleetHostID, sourcePath: String) async throws -> CoFleetPetManifest {
        try await service(for: hostID).importPet(hostID: hostID, sourcePath: sourcePath)
    }

    public func fetchPetCatalogs(hostID: CoFleetHostID) async throws -> [CoFleetPetCatalog] {
        try await service(for: hostID).fetchPetCatalogs(hostID: hostID)
    }

    public func fetchPetCatalogPage(
        hostID: CoFleetHostID,
        catalogID: String,
        query: String,
        cursor: String?
    ) async throws -> CoFleetPetCatalogPage {
        try await service(for: hostID).fetchPetCatalogPage(
            hostID: hostID,
            catalogID: catalogID,
            query: query,
            cursor: cursor
        )
    }

    public func installCatalogPet(
        hostID: CoFleetHostID,
        catalogID: String,
        petID: String
    ) async throws -> CoFleetPetManifest {
        try await service(for: hostID).installCatalogPet(
            hostID: hostID,
            catalogID: catalogID,
            petID: petID
        )
    }

    public func selectPet(
        hostID: CoFleetHostID,
        projectID: String,
        petID: String
    ) async throws -> CoFleetProject {
        try await service(for: hostID).selectPet(
            hostID: hostID,
            projectID: projectID,
            petID: petID
        )
    }

    public func fetchPetAsset(
        hostID: CoFleetHostID,
        petID: String,
        assetName: String
    ) async throws -> CoFleetPetAsset {
        try await service(for: hostID).fetchPetAsset(
            hostID: hostID,
            petID: petID,
            assetName: assetName
        )
    }

    private func service(for hostID: CoFleetHostID) throws -> CoFleetHostService {
        if let service = services[hostID] { return service }
        guard let record = records[hostID] else { throw unknownHost() }
        let service = try makeService(record: record)
        services[hostID] = service
        return service
    }

    private func makeService(record: CoFleetStoredHostPairing) throws -> CoFleetHostService {
        let endpoint = try CoFleetHostEndpoint(baseURL: record.endpoint)
        let hostID = record.host.id
        let credential = credential(for: hostID)
        let client = CoFleetAPIClient(endpoint: endpoint) {
            try await credential.token()
        }
        return CoFleetHostService(client: client)
    }

    private func credential(for hostID: CoFleetHostID) -> CoFleetHostCredential {
        if let credential = credentials[hostID] { return credential }
        let credential = CoFleetHostCredential(hostID: hostID, vault: tokenVault)
        credentials[hostID] = credential
        return credential
    }

    private func persistRecords() throws {
        let data = try JSONEncoder().encode(Array(records.values))
        defaults.set(data, forKey: recordsKey)
    }

    private func serviceEntries() throws -> [ServiceEntry] {
        try records.values.map { record in
            ServiceEntry(id: record.host.id, record: record, service: try service(for: record.host.id))
        }
    }

    private func unknownHost() -> CoFleetClientError {
        .unavailable("The selected host is no longer paired.")
    }
}

private struct ServiceEntry: Sendable {
    var id: CoFleetHostID
    var record: CoFleetStoredHostPairing
    var service: CoFleetHostService
}

private struct HostFetchResult: Sendable {
    var id: CoFleetHostID
    var host: CoFleetHostInfo
}

private struct ProjectFetchResult: Sendable {
    var hostID: CoFleetHostID
    var projects: [CoFleetProject]
}

public struct CoFleetPairingInputValue: Hashable, Sendable {
    public var endpoint: URL
    public var code: String
    public var deviceName: String

    public init(endpoint: URL, code: String, deviceName: String) {
        self.endpoint = endpoint
        self.code = code
        self.deviceName = deviceName
    }
}
