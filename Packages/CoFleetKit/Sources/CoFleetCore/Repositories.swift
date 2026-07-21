import Foundation

public protocol CoFleetFleetRepository: Sendable {
    func fetchHosts() async throws -> [CoFleetHostInfo]
    func fetchAccount(hostID: CoFleetHostID) async throws -> CoFleetAccountInfo
    func fetchAccountLimits(hostID: CoFleetHostID) async throws -> [CoFleetRateLimitInfo]
    func startChatGPTLogin(hostID: CoFleetHostID) async throws -> CoFleetLoginChallenge
    func fetchPairedDevices(hostID: CoFleetHostID) async throws -> [CoFleetPairedDevice]
    func currentPairedDeviceID(hostID: CoFleetHostID) async -> String?
    func rotateCurrentDevice(hostID: CoFleetHostID) async throws -> CoFleetPairedDevice
    func revokeCurrentDevice(hostID: CoFleetHostID) async throws
    func fetchProjects() async throws -> [CoFleetProject]
    func discoverRecentRoots(hostID: CoFleetHostID, cursor: String?) async throws -> CoFleetDirectoryPage
    func browseDirectories(
        hostID: CoFleetHostID,
        path: String,
        cursor: String?,
        showHidden: Bool
    ) async throws -> CoFleetDirectoryPage
    func createDirectory(
        hostID: CoFleetHostID,
        parent: String,
        name: String
    ) async throws -> CoFleetDirectoryEntry
    func registerProject(hostID: CoFleetHostID, canonicalPath: String, displayName: String) async throws -> CoFleetProject
    func renameProject(hostID: CoFleetHostID, id: String, displayName: String) async throws -> CoFleetProject
    func removeProject(id: String) async throws
}

public extension CoFleetFleetRepository {
    func startChatGPTLogin(hostID: CoFleetHostID) async throws -> CoFleetLoginChallenge {
        throw CoFleetClientError.incompatible("This host does not expose the Codex sign-in flow.")
    }

    func fetchPairedDevices(hostID: CoFleetHostID) async throws -> [CoFleetPairedDevice] {
        throw CoFleetClientError.incompatible("This client does not support paired-device management.")
    }

    func currentPairedDeviceID(hostID: CoFleetHostID) async -> String? { nil }

    func rotateCurrentDevice(hostID: CoFleetHostID) async throws -> CoFleetPairedDevice {
        throw CoFleetClientError.incompatible("Re-pair this host before rotating its device token.")
    }

    func revokeCurrentDevice(hostID: CoFleetHostID) async throws {
        throw CoFleetClientError.incompatible("Re-pair this host before removing this device.")
    }

    func renameProject(
        hostID: CoFleetHostID,
        id: String,
        displayName: String
    ) async throws -> CoFleetProject {
        throw CoFleetClientError.incompatible("This host does not support renaming projects.")
    }
}

public protocol CoFleetThreadRepository: Sendable {
    func fetchSessions(
        hostID: CoFleetHostID,
        projectID: String,
        cursor: String?,
        limit: Int,
        archived: Bool
    ) async throws -> CoFleetSessionPage
    func createSession(hostID: CoFleetHostID, projectID: String) async throws -> CoFleetSessionSummary
    func resumeSession(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String,
        settings: CoFleetSessionSettings
    ) async throws -> CoFleetSessionSummary
    func forkSession(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String,
        settings: CoFleetSessionSettings
    ) async throws -> CoFleetSessionSummary
    func renameSession(hostID: CoFleetHostID, sessionID: String, title: String) async throws
    func archiveSession(hostID: CoFleetHostID, sessionID: String) async throws
    func unarchiveSession(hostID: CoFleetHostID, sessionID: String) async throws
    func openSessionInCodex(hostID: CoFleetHostID, sessionID: String) async throws
}

public extension CoFleetThreadRepository {
    func openSessionInCodex(hostID: CoFleetHostID, sessionID: String) async throws {
        throw CoFleetClientError.incompatible(
            "Update cofleet-host on this Mac to use Codex Companion mode."
        )
    }
}

public enum CoFleetTurnEvent: Hashable, Sendable {
    case turn(CoFleetTurn)
    case upsertItem(CoFleetTurnItem)
    case interaction(CoFleetInteraction)
    case interactionResolved(id: String)
    case interactionExpired(id: String)
    case resetRequired
    case checkpoint
}

public struct CoFleetSequencedTurnEvent: Hashable, Sendable {
    public var id: String?
    public var event: CoFleetTurnEvent

    public init(id: String? = nil, event: CoFleetTurnEvent) {
        self.id = id
        self.event = event
    }
}

public protocol CoFleetTurnRepository: Sendable {
    func fetchTranscript(hostID: CoFleetHostID, sessionID: String) async throws -> [CoFleetTurnItem]
    func fetchInteractions(hostID: CoFleetHostID, sessionID: String) async throws -> [CoFleetInteraction]
    func startTurn(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String,
        input: [CoFleetTurnInput],
        settings: CoFleetSessionSettings,
        idempotencyKey: UUID
    ) async throws -> CoFleetTurn
    func interruptTurn(hostID: CoFleetHostID, sessionID: String, turnID: String) async throws
    func resolveInteraction(
        hostID: CoFleetHostID,
        interactionID: String,
        decision: CoFleetInteractionDecision,
        answers: [String: [String]]?
    ) async throws
    func events(hostID: CoFleetHostID, sessionID: String, afterEventID: String?) async throws -> AsyncThrowingStream<CoFleetSequencedTurnEvent, Error>
}

public enum CoFleetNoteSaveResult: Hashable, Sendable {
    case saved(CoFleetNote)
    case conflict(server: CoFleetNote, localMarkdown: String)
}

public protocol CoFleetWorkspaceRepository: Sendable {
    func fetchNote(hostID: CoFleetHostID, projectID: String, sessionID: String?) async throws -> CoFleetNote
    func saveNote(_ note: CoFleetNote, expectedETag: String) async throws -> CoFleetNoteSaveResult
    func fetchTodos(hostID: CoFleetHostID, projectID: String) async throws -> [CoFleetTodoItem]
    func saveTodo(_ todo: CoFleetTodoItem, expectedETag: String?) async throws -> CoFleetTodoItem
    func deleteTodo(hostID: CoFleetHostID, id: String, expectedETag: String) async throws
    func fetchPets(hostID: CoFleetHostID) async throws -> [CoFleetPetManifest]
    func discoverPets(hostID: CoFleetHostID) async throws -> [CoFleetDiscoveredPet]
    func importPet(hostID: CoFleetHostID, sourcePath: String) async throws -> CoFleetPetManifest
    func selectPet(hostID: CoFleetHostID, projectID: String, petID: String) async throws -> CoFleetProject
    func fetchPetAsset(
        hostID: CoFleetHostID,
        petID: String,
        assetName: String
    ) async throws -> CoFleetPetAsset
}
