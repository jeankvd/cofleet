import CoFleetCore
import Foundation

public actor CoFleetHostService: CoFleetFleetRepository, CoFleetThreadRepository, CoFleetTurnRepository, CoFleetWorkspaceRepository {
    private let client: CoFleetAPIClient
    private var cachedHost: CoFleetHostInfo?

    public init(client: CoFleetAPIClient) {
        self.client = client
    }

    public func pair(code: String, deviceName: String) async throws -> CoFleetPairingReceipt {
        let response: PairingReceiptDTO = try await client.post(
            "/v1/pairings/redeem",
            body: PairRequest(code: code, deviceName: deviceName),
            authenticated: false
        )
        let host = response.host.model
        cachedHost = host
        return CoFleetPairingReceipt(host: host, deviceID: response.device.id, token: response.token)
    }

    public func fetchPairedDevices() async throws -> [CoFleetPairedDevice] {
        let response: DeviceListDTO = try await client.get("/v1/devices")
        return response.devices.map { $0.model }
    }

    public func fetchPairedDevices(hostID: CoFleetHostID) async throws -> [CoFleetPairedDevice] {
        try await requireHost(hostID)
        return try await fetchPairedDevices()
    }

    public func rotateDevice(id: String) async throws -> CoFleetDeviceRotationReceipt {
        let response: DeviceRotationReceiptDTO = try await client.post(
            "/v1/devices/\(id.pathComponent)/rotate",
            body: EmptyRequest()
        )
        return CoFleetDeviceRotationReceipt(device: response.device.model, token: response.token)
    }

    public func fetchAccount(hostID: CoFleetHostID) async throws -> CoFleetAccountInfo {
        try await requireHost(hostID)
        let response: AccountEnvelopeDTO = try await client.get("/v1/account")
        return response.account.model(hostID: hostID)
    }

    public func fetchAccountLimits(hostID: CoFleetHostID) async throws -> [CoFleetRateLimitInfo] {
        try await requireHost(hostID)
        let response: AccountLimitsEnvelopeDTO = try await client.get("/v1/account/limits")
        return response.limits.models(hostID: hostID)
    }

    public func startChatGPTLogin(hostID: CoFleetHostID) async throws -> CoFleetLoginChallenge {
        try await requireHost(hostID)
        let response: LoginEnvelopeDTO = try await client.post(
            "/v1/account/login",
            body: LoginRequest(type: "chatgptDeviceCode")
        )
        guard let loginID = response.login.loginId,
              let rawURL = response.login.verificationUrl ?? response.login.authUrl,
              let verificationURL = URL(string: rawURL),
              verificationURL.scheme == "https" else {
            throw CoFleetClientError.invalidResponse
        }
        return CoFleetLoginChallenge(
            loginID: loginID,
            verificationURL: verificationURL,
            userCode: response.login.userCode
        )
    }

    public func revokeDevice(id: String) async throws {
        try await client.delete("/v1/devices/\(id.pathComponent)")
    }

    public func fetchModels() async throws -> [CoFleetModelInfo] {
        let response: ModelListDTO = try await client.get("/v1/models")
        return response.models.map { $0.model }
    }

    public func fetchHosts() async throws -> [CoFleetHostInfo] {
        let response: HostEnvelopeDTO = try await client.get("/v1/host")
        let host = response.host.model
        cachedHost = host
        return [host]
    }

    public func fetchProjects() async throws -> [CoFleetProject] {
        let host = try await resolvedHost()
        let response: ProjectListDTO = try await client.get("/v1/projects")
        return response.projects.enumerated().map { index, project in
            project.model(hostID: host.id, sortIndex: index)
        }
    }

    public func discoverRecentRoots(cursor: String? = nil) async throws -> CoFleetDirectoryPage {
        var query = [URLQueryItem(name: "limit", value: "20")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let response: SuggestionsDTO = try await client.get("/v1/projects/suggestions", query: query)
        return CoFleetDirectoryPage(
            canonicalPath: "",
            parentPath: nil,
            entries: response.suggestions.map {
                CoFleetDirectoryEntry(name: $0.name, canonicalPath: $0.rootPath)
            },
            nextCursor: response.nextCursor
        )
    }

    public func discoverRecentRoots(
        hostID: CoFleetHostID,
        cursor: String?
    ) async throws -> CoFleetDirectoryPage {
        try await requireHost(hostID)
        return try await discoverRecentRoots(cursor: cursor)
    }

    public func browseDirectories(
        path: String,
        cursor: String? = nil,
        showHidden: Bool = false
    ) async throws -> CoFleetDirectoryPage {
        var query = [
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "showHidden", value: showHidden ? "true" : "false"),
            URLQueryItem(name: "limit", value: "100"),
        ]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let response: DirectoryPageDTO = try await client.get("/v1/directories", query: query)
        return response.model
    }

    public func browseDirectories(
        hostID: CoFleetHostID,
        path: String,
        cursor: String?,
        showHidden: Bool
    ) async throws -> CoFleetDirectoryPage {
        try await requireHost(hostID)
        return try await browseDirectories(path: path, cursor: cursor, showHidden: showHidden)
    }

    public func createDirectory(parent: String, name: String) async throws -> CoFleetDirectoryEntry {
        let response: DirectoryEnvelopeDTO = try await client.post(
            "/v1/directories",
            body: CreateDirectoryRequest(parentPath: parent, name: name)
        )
        return response.directory.model
    }

    public func createDirectory(
        hostID: CoFleetHostID,
        parent: String,
        name: String
    ) async throws -> CoFleetDirectoryEntry {
        try await requireHost(hostID)
        return try await createDirectory(parent: parent, name: name)
    }

    public func registerProject(
        hostID: CoFleetHostID,
        canonicalPath: String,
        displayName: String
    ) async throws -> CoFleetProject {
        let response: ProjectEnvelopeDTO = try await client.post(
            "/v1/projects",
            body: RegisterProjectRequest(rootPath: canonicalPath, name: displayName)
        )
        return response.project.model(hostID: hostID, sortIndex: 0)
    }

    public func renameProject(
        hostID: CoFleetHostID,
        id: String,
        displayName: String
    ) async throws -> CoFleetProject {
        let response: ProjectEnvelopeDTO = try await client.patch(
            "/v1/projects/\(id.pathComponent)",
            body: RenameProjectRequest(name: displayName)
        )
        return response.project.model(hostID: hostID, sortIndex: 0)
    }

    public func removeProject(id: String) async throws {
        try await client.delete("/v1/projects/\(id.pathComponent)")
    }

    public func fetchSessions(
        hostID: CoFleetHostID,
        projectID: String,
        cursor: String?,
        limit: Int,
        archived: Bool
    ) async throws -> CoFleetSessionPage {
        var query = [
            URLQueryItem(name: "limit", value: String(min(5, max(1, limit)))),
            URLQueryItem(name: "archived", value: archived ? "true" : "false"),
        ]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let response: SessionPageDTO = try await client.get(
            "/v1/projects/\(projectID.pathComponent)/sessions",
            query: query
        )
        return CoFleetSessionPage(
            items: response.sessions.map { $0.model(hostID: hostID, fallbackProjectID: projectID) },
            nextCursor: response.nextCursor
        )
    }

    public func createSession(hostID: CoFleetHostID, projectID: String) async throws -> CoFleetSessionSummary {
        let response: SessionEnvelopeDTO = try await client.post(
            "/v1/sessions",
            body: CreateSessionRequest(projectID: projectID)
        )
        return response.session.model(hostID: hostID, fallbackProjectID: projectID)
    }

    public func resumeSession(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String,
        settings: CoFleetSessionSettings
    ) async throws -> CoFleetSessionSummary {
        let response: SessionEnvelopeDTO = try await client.post(
            "/v1/sessions/\(sessionID.pathComponent)/resume",
            body: SessionActionRequest(projectID: projectID, settings: settings)
        )
        return response.session.model(hostID: hostID, fallbackProjectID: projectID)
    }

    public func forkSession(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String,
        settings: CoFleetSessionSettings
    ) async throws -> CoFleetSessionSummary {
        let response: SessionEnvelopeDTO = try await client.post(
            "/v1/sessions/\(sessionID.pathComponent)/fork",
            body: SessionActionRequest(projectID: projectID, settings: settings)
        )
        return response.session.model(hostID: hostID, fallbackProjectID: projectID)
    }

    public func renameSession(hostID: CoFleetHostID, sessionID: String, title: String) async throws {
        let _: SessionMutationDTO = try await client.patch(
            "/v1/sessions/\(sessionID.pathComponent)",
            body: RenameSessionRequest(title: title)
        )
    }

    public func openSessionInCodex(hostID: CoFleetHostID, sessionID: String) async throws {
        try await requireHost(hostID)
        let response: SessionDesktopOpenDTO = try await client.post(
            "/v1/sessions/\(sessionID.pathComponent)/open-in-codex",
            body: EmptyRequest()
        )
        guard response.opened, response.sessionID == sessionID else {
            throw CoFleetClientError.invalidResponse
        }
    }

    public func archiveSession(hostID: CoFleetHostID, sessionID: String) async throws {
        let _: IgnoredResponse = try await client.post(
            "/v1/sessions/\(sessionID.pathComponent)/archive",
            body: EmptyRequest()
        )
    }

    public func unarchiveSession(hostID: CoFleetHostID, sessionID: String) async throws {
        let _: IgnoredResponse = try await client.post(
            "/v1/sessions/\(sessionID.pathComponent)/unarchive",
            body: EmptyRequest()
        )
    }

    public func fetchTranscript(hostID: CoFleetHostID, sessionID: String) async throws -> [CoFleetTurnItem] {
        let response: TranscriptDTO = try await client.get(
            "/v1/sessions/\(sessionID.pathComponent)/transcript"
        )
        return response.turns.flatMap { $0.items.map(\.model) }
    }

    public func fetchInteractions(
        hostID: CoFleetHostID,
        sessionID: String
    ) async throws -> [CoFleetInteraction] {
        try await requireHost(hostID)
        let response: InteractionListDTO = try await client.get(
            "/v1/interactions",
            query: [URLQueryItem(name: "state", value: "pending")]
        )
        return response.interactions.filter { $0.sessionID == sessionID }
    }

    public func startTurn(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String,
        input: [CoFleetTurnInput],
        settings: CoFleetSessionSettings,
        idempotencyKey: UUID
    ) async throws -> CoFleetTurn {
        let response: TurnEnvelopeDTO = try await client.post(
            "/v1/sessions/\(sessionID.pathComponent)/turns",
            body: StartTurnRequest(projectID: projectID, input: input, settings: settings),
            idempotencyKey: idempotencyKey
        )
        return response.turn.model(hostID: hostID, sessionID: sessionID)
    }

    public func interruptTurn(hostID: CoFleetHostID, sessionID: String, turnID: String) async throws {
        let _: IgnoredResponse = try await client.post(
            "/v1/sessions/\(sessionID.pathComponent)/turns/\(turnID.pathComponent)/interrupt",
            body: EmptyRequest()
        )
    }

    public func resolveInteraction(
        hostID: CoFleetHostID,
        interactionID: String,
        decision: CoFleetInteractionDecision,
        answers: [String: [String]]?
    ) async throws {
        let _: IgnoredResponse = try await client.post(
            "/v1/interactions/\(interactionID.pathComponent)/resolve",
            body: ResolveInteractionRequest(decision: decision, answers: answers)
        )
    }

    public func events(
        hostID: CoFleetHostID,
        sessionID: String,
        afterEventID: String?
    ) async throws -> AsyncThrowingStream<CoFleetSequencedTurnEvent, Error> {
        let raw = try await client.eventStream(
            path: "/v1/sessions/\(sessionID.pathComponent)/events",
            lastEventID: afterEventID
        )
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let decoder = CoFleetTurnEventDecoder()
                    for try await event in raw {
                        continuation.yield(try decoder.decode(event))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func fetchNote(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String?
    ) async throws -> CoFleetNote {
        var query: [URLQueryItem] = []
        if let sessionID { query.append(URLQueryItem(name: "session_id", value: sessionID)) }
        let response: NoteEnvelopeDTO = try await client.get(
            "/v1/projects/\(projectID.pathComponent)/note",
            query: query
        )
        return response.note?.model(hostID: hostID) ?? CoFleetNote(
            hostID: hostID,
            projectID: projectID,
            sessionID: sessionID
        )
    }

    public func saveNote(_ note: CoFleetNote, expectedETag: String) async throws -> CoFleetNoteSaveResult {
        do {
            let response: NoteEnvelopeDTO = try await client.put(
                "/v1/projects/\(note.projectID.pathComponent)/note",
                body: NoteWriteDTO(markdown: note.markdown, sessionID: note.sessionID),
                ifMatch: expectedETag
            )
            guard let saved = response.note?.model(hostID: note.hostID) else {
                throw CoFleetClientError.invalidResponse
            }
            return .saved(saved)
        } catch CoFleetClientError.conflict {
            let server = try await fetchNote(
                hostID: note.hostID,
                projectID: note.projectID,
                sessionID: note.sessionID
            )
            return .conflict(server: server, localMarkdown: note.markdown)
        }
    }

    public func fetchTodos(hostID: CoFleetHostID, projectID: String) async throws -> [CoFleetTodoItem] {
        let response: TodoListDTO = try await client.get(
            "/v1/projects/\(projectID.pathComponent)/todos"
        )
        return response.todos.map { $0.model(hostID: hostID) }
    }

    public func saveTodo(_ todo: CoFleetTodoItem, expectedETag: String?) async throws -> CoFleetTodoItem {
        if let expectedETag {
            let response: TodoEnvelopeDTO = try await client.patch(
                "/v1/todos/\(todo.id.pathComponent)",
                body: TodoWriteDTO(todo: todo),
                ifMatch: expectedETag
            )
            return response.todo.model(hostID: todo.hostID)
        }
        let response: TodoEnvelopeDTO = try await client.post(
            "/v1/projects/\(todo.projectID.pathComponent)/todos",
            body: TodoWriteDTO(todo: todo)
        )
        return response.todo.model(hostID: todo.hostID)
    }

    public func deleteTodo(hostID: CoFleetHostID, id: String, expectedETag: String) async throws {
        try await client.delete("/v1/todos/\(id.pathComponent)", ifMatch: expectedETag)
    }

    public func fetchPets(hostID: CoFleetHostID) async throws -> [CoFleetPetManifest] {
        try await requireHost(hostID)
        let response: PetListDTO = try await client.get("/v1/pets")
        return try response.pets.map {
            let manifest = $0.model(hostID: hostID)
            try CoFleetPetManifestValidator.validate(manifest)
            return manifest
        }
    }

    public func discoverPets(hostID: CoFleetHostID) async throws -> [CoFleetDiscoveredPet] {
        try await requireHost(hostID)
        let response: DiscoveredPetListDTO = try await client.get("/v1/pets/discover")
        return response.pets.map { $0.model(hostID: hostID) }
    }

    public func importPet(
        hostID: CoFleetHostID,
        sourcePath: String
    ) async throws -> CoFleetPetManifest {
        try await requireHost(hostID)
        let response: PetEnvelopeDTO = try await client.post(
            "/v1/pets",
            body: ImportPetRequest(sourcePath: sourcePath)
        )
        let manifest = response.pet.model(hostID: hostID)
        try CoFleetPetManifestValidator.validate(manifest)
        return manifest
    }

    public func selectPet(
        hostID: CoFleetHostID,
        projectID: String,
        petID: String
    ) async throws -> CoFleetProject {
        try await requireHost(hostID)
        let response: ProjectEnvelopeDTO = try await client.put(
            "/v1/projects/\(projectID.pathComponent)/pet",
            body: SelectPetRequest(petID: petID)
        )
        return response.project.model(hostID: hostID, sortIndex: 0)
    }

    public func fetchPetAsset(
        hostID: CoFleetHostID,
        petID: String,
        assetName: String
    ) async throws -> CoFleetPetAsset {
        try await requireHost(hostID)
        guard assetName == "spritesheet.png" || assetName == "spritesheet.webp" else {
            throw CoFleetPetManifestError.unsafeAssetPath(assetName)
        }
        let response = try await client.getData(
            "/v1/pets/\(petID.pathComponent)/assets/\(assetName.pathComponent)",
            maximumBytes: CoFleetPetAsset.maximumByteCount
        )
        return try CoFleetPetAsset(
            hostID: hostID,
            petID: petID,
            assetName: assetName,
            mediaType: response.mediaType,
            data: response.data
        )
    }

    private func resolvedHost() async throws -> CoFleetHostInfo {
        if let cachedHost { return cachedHost }
        let response: HostEnvelopeDTO = try await client.get("/v1/host")
        let host = response.host.model
        cachedHost = host
        return host
    }

    private func requireHost(_ hostID: CoFleetHostID) async throws {
        guard (try await resolvedHost()).id == hostID else {
            throw CoFleetClientError.unavailable("The request belongs to a different paired host.")
        }
    }
}

private struct PairRequest: Codable, Sendable {
    var code: String
    var deviceName: String
}

private struct CreateDirectoryRequest: Codable, Sendable {
    var parentPath: String
    var name: String
}

private struct ImportPetRequest: Codable, Sendable { var sourcePath: String }
private struct SelectPetRequest: Codable, Sendable { var petID: String }

private struct RegisterProjectRequest: Codable, Sendable {
    var rootPath: String
    var name: String
}

private struct RenameProjectRequest: Codable, Sendable { var name: String }

private struct CreateSessionRequest: Codable, Sendable {
    var projectID: String
}

private struct SessionActionRequest: Codable, Sendable {
    var projectID: String
    var model: String?
    var reasoningEffort: String?
    var serviceTier: String?
    var accessLevel: String

    init(projectID: String, settings: CoFleetSessionSettings) {
        self.projectID = projectID
        model = settings.modelID
        reasoningEffort = settings.reasoningEffort
        serviceTier = settings.serviceTier
        switch settings.accessLevel {
        case .askForApproval: accessLevel = "ask_for_approval"
        case .approveForMe: accessLevel = "approve_for_me"
        case .fullAccess: accessLevel = "full_access"
        }
    }
}

private struct RenameSessionRequest: Codable, Sendable { var title: String }
private struct SessionMutationDTO: Decodable, Sendable {
    var sessionID: String
    var title: String
}

private struct SessionDesktopOpenDTO: Decodable, Sendable {
    var sessionID: String
    var opened: Bool
}

struct StartTurnRequest: Encodable, Sendable {
    var input: [StartTurnInputRequest]
    var projectID: String
    var model: String?
    var reasoningEffort: String?
    var serviceTier: String?
    var accessLevel: String

    init(projectID: String, input: [CoFleetTurnInput], settings: CoFleetSessionSettings) {
        self.input = input.map(StartTurnInputRequest.init)
        self.projectID = projectID
        model = settings.modelID
        reasoningEffort = settings.reasoningEffort
        serviceTier = settings.serviceTier
        switch settings.accessLevel {
        case .askForApproval: accessLevel = "ask_for_approval"
        case .approveForMe: accessLevel = "approve_for_me"
        case .fullAccess: accessLevel = "full_access"
        }
    }
}

enum StartTurnInputRequest: Encodable, Sendable {
    case text(String)
    case image(URL)
    case localImage(String)

    init(_ input: CoFleetTurnInput) {
        switch input {
        case let .text(text): self = .text(text)
        case let .imageURL(url): self = .image(url)
        case let .localImage(path): self = .localImage(path)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case url
        case path
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .text(text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case let .image(url):
            try container.encode("image", forKey: .type)
            try container.encode(url.absoluteString, forKey: .url)
        case let .localImage(path):
            try container.encode("localImage", forKey: .type)
            try container.encode(path, forKey: .path)
        }
    }
}

private struct ResolveInteractionRequest: Codable, Sendable {
    var decision: CoFleetInteractionDecision
    var answers: [String: [String]]?
}

private struct EmptyRequest: Codable, Sendable {}
private struct LoginRequest: Codable, Sendable { var type: String }

private struct LoginEnvelopeDTO: Decodable, Sendable {
    var login: LoginDTO
}

private struct LoginDTO: Decodable, Sendable {
    var type: String
    var loginId: String?
    var authUrl: String?
    var userCode: String?
    var verificationUrl: String?
}

private struct IgnoredResponse: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}

private struct HostEnvelopeDTO: Decodable, Sendable { var host: HostDTO }

private struct AccountEnvelopeDTO: Decodable, Sendable { var account: AccountReadDTO }

private struct AccountReadDTO: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        var type: String
        var email: String?
        var planType: String?
    }

    var account: Account?
    var requiresOpenaiAuth: Bool

    func model(hostID: CoFleetHostID) -> CoFleetAccountInfo {
        CoFleetAccountInfo(
            hostID: hostID,
            authenticationType: account?.type,
            email: account?.email,
            planType: account?.planType,
            requiresOpenAIAuthentication: requiresOpenaiAuth
        )
    }
}

private struct AccountLimitsEnvelopeDTO: Decodable, Sendable { var limits: AccountLimitsDTO }

private struct AccountLimitsDTO: Decodable, Sendable {
    struct Window: Decodable, Sendable {
        var usedPercent: Int
        var resetsAt: Int?
        var windowDurationMins: Int?

        var model: CoFleetRateLimitWindow {
            CoFleetRateLimitWindow(
                usedPercent: usedPercent,
                resetsAt: resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                windowDurationMinutes: windowDurationMins
            )
        }
    }

    struct Snapshot: Decodable, Sendable {
        var limitId: String?
        var limitName: String?
        var planType: String?
        var primary: Window?
        var secondary: Window?

        func model(hostID: CoFleetHostID, fallbackID: String) -> CoFleetRateLimitInfo {
            CoFleetRateLimitInfo(
                hostID: hostID,
                limitID: limitId ?? fallbackID,
                displayName: limitName,
                planType: planType,
                primary: primary?.model,
                secondary: secondary?.model
            )
        }
    }

    var rateLimits: Snapshot?
    var rateLimitsByLimitId: [String: Snapshot]?

    func models(hostID: CoFleetHostID) -> [CoFleetRateLimitInfo] {
        if let rateLimitsByLimitId, !rateLimitsByLimitId.isEmpty {
            return rateLimitsByLimitId.sorted { $0.key < $1.key }.map {
                $0.value.model(hostID: hostID, fallbackID: $0.key)
            }
        }
        return rateLimits.map { [$0.model(hostID: hostID, fallbackID: "codex")] } ?? []
    }
}

private struct HostDTO: Decodable, Sendable {
    struct Capabilities: Decodable, Sendable {
        var folderCreation: Bool?
        var pets: Bool?
        var codexDesktopOpen: Bool?
        var sourceControl: [String]?
    }

    var id: String
    var displayName: String
    var platform: String
    var homePath: String
    var codexAvailable: Bool?
    var capabilities: Capabilities

    var model: CoFleetHostInfo {
        CoFleetHostInfo(
            id: .init(rawValue: id),
            displayName: displayName,
            platform: platform,
            canonicalHome: homePath,
            reachability: codexAvailable == false ? .degraded : .online,
            capabilities: .init(
                canBrowseDirectories: true,
                canCreateDirectories: capabilities.folderCreation ?? false,
                canImportPets: capabilities.pets ?? false,
                canNavigateCodexDesktop: capabilities.codexDesktopOpen ?? false,
                supportsPlasticSCM: capabilities.sourceControl?.contains("plastic") ?? false
            ),
            lastSeenAt: .now
        )
    }
}

private struct PairingReceiptDTO: Decodable, Sendable {
    var device: DeviceDTO
    var token: String
    var host: HostDTO
}

private struct DeviceListDTO: Decodable, Sendable { var devices: [DeviceDTO] }

private struct DeviceRotationReceiptDTO: Decodable, Sendable {
    var device: DeviceDTO
    var token: String
}

private struct DeviceDTO: Decodable, Sendable {
    var id: String
    var name: String
    var createdAt: FlexibleDate
    var lastSeenAt: FlexibleDate?
    var revoked: Bool?
    var revokedAt: FlexibleDate?

    var model: CoFleetPairedDevice {
        CoFleetPairedDevice(
            id: id,
            name: name,
            createdAt: createdAt.value,
            lastSeenAt: lastSeenAt?.value,
            isRevoked: revoked ?? false,
            revokedAt: revokedAt?.value
        )
    }
}

private struct ModelListDTO: Decodable, Sendable { var models: [ModelDTO] }

private struct ModelDTO: Decodable, Sendable {
    var id: String
    var displayName: String
    var isDefault: Bool
    var reasoningEfforts: [String]?
    var serviceTiers: [String]?
    var contextWindow: Int?

    var model: CoFleetModelInfo {
        CoFleetModelInfo(
            id: id,
            displayName: displayName,
            supportedReasoningEfforts: reasoningEfforts ?? [],
            supportedServiceTiers: serviceTiers ?? [],
            contextWindow: contextWindow,
            isDefault: isDefault
        )
    }
}

private struct ProjectListDTO: Decodable, Sendable { var projects: [ProjectDTO] }
private struct ProjectEnvelopeDTO: Decodable, Sendable { var project: ProjectDTO }

private struct ProjectDTO: Decodable, Sendable {
    var id: String
    var name: String
    var canonicalPath: String
    var petID: String?
    var sourceControl: SourceControlDTO?

    func model(hostID: CoFleetHostID, sortIndex: Int) -> CoFleetProject {
        CoFleetProject(
            id: id,
            hostID: hostID,
            displayName: name,
            canonicalPath: canonicalPath,
            sortIndex: sortIndex,
            selectedPetID: petID,
            sourceControl: sourceControl?.model
        )
    }
}

private struct SourceControlDTO: Decodable, Sendable {
    var kind: CoFleetSourceControlKind
    var state: CoFleetSourceControlState
    var branch: String?
    var detail: String?
    var observedAt: FlexibleDate?

    var model: CoFleetSourceControlStatus {
        CoFleetSourceControlStatus(
            kind: kind,
            state: state,
            branch: branch,
            summary: detail,
            observedAt: observedAt?.value ?? .now
        )
    }
}

private struct SuggestionsDTO: Decodable, Sendable {
    struct Suggestion: Decodable, Sendable {
        var rootPath: String
        var name: String
    }
    var suggestions: [Suggestion]
    var nextCursor: String?
}

private struct DirectoryPageDTO: Decodable, Sendable {
    var path: String
    var parentPath: String?
    var directories: [DirectoryDTO]
    var nextCursor: String?

    var model: CoFleetDirectoryPage {
        CoFleetDirectoryPage(
            canonicalPath: path,
            parentPath: parentPath,
            entries: directories.map(\.model),
            nextCursor: nextCursor
        )
    }
}

private struct DirectoryEnvelopeDTO: Decodable, Sendable { var directory: DirectoryDTO }

private struct DirectoryDTO: Decodable, Sendable {
    var name: String
    var canonicalPath: String
    var isSymlink: Bool
    var readable: Bool

    var model: CoFleetDirectoryEntry {
        CoFleetDirectoryEntry(
            name: name,
            canonicalPath: canonicalPath,
            isSymbolicLink: isSymlink,
            isReadable: readable
        )
    }
}

private struct SessionPageDTO: Decodable, Sendable {
    var sessions: [SessionDTO]
    var nextCursor: String?
}

private struct SessionEnvelopeDTO: Decodable, Sendable { var session: SessionDTO }

private struct SessionDTO: Decodable, Sendable {
    var id: String
    var hostID: String?
    var projectID: String?
    var title: String
    var preview: String?
    var createdAt: FlexibleDate?
    var updatedAt: FlexibleDate?
    var archived: Bool?
    var model: String?
    var accessLevel: String?
    var reasoningEffort: String?
    var serviceTier: String?

    func model(hostID: CoFleetHostID, fallbackProjectID: String) -> CoFleetSessionSummary {
        CoFleetSessionSummary(
            id: id,
            hostID: hostID,
            projectID: projectID ?? fallbackProjectID,
            title: title,
            state: archived == true ? .archived : .idle,
            updatedAt: updatedAt?.value ?? .now,
            createdAt: createdAt?.value ?? .now,
            preview: preview,
            modelID: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            accessLevel: mappedAccessLevel
        )
    }

    private var mappedAccessLevel: CoFleetAccessLevel {
        switch accessLevel {
        case "approve_for_me": .approveForMe
        case "full_access": .fullAccess
        default: .askForApproval
        }
    }
}

private struct TranscriptDTO: Decodable, Sendable {
    var session: SessionDTO
    var turns: [TurnDTO]
}

private struct InteractionListDTO: Decodable, Sendable {
    var interactions: [CoFleetInteraction]
}

private struct TurnEnvelopeDTO: Decodable, Sendable { var turn: TurnDTO }

private struct TurnDTO: Decodable, Sendable {
    var id: String
    var status: String?
    var error: String?
    var items: [TurnItemDTO]

    func model(hostID: CoFleetHostID, sessionID: String) -> CoFleetTurn {
        CoFleetTurn(
            id: id,
            hostID: hostID,
            sessionID: sessionID,
            state: turnState,
            completedAt: turnState == .completed ? .now : nil,
            errorMessage: error
        )
    }

    private var turnState: CoFleetTurnState {
        switch status?.lowercased() {
        case "completed": .completed
        case "failed": .failed
        case "interrupted", "cancelled": .interrupted
        case "waiting", "waitingforinteraction": .waitingForInteraction
        default: .running
        }
    }
}

private struct TurnItemDTO: Decodable, Sendable {
    var id: String
    var turnID: String
    var type: String
    var role: String
    var text: String?
    var status: String?
    var title: String?
    var detail: String?

    var model: CoFleetTurnItem {
        CoFleetTurnItem(
            id: id,
            turnID: turnID,
            kind: kind,
            state: status?.lowercased() == "inprogress" ? .streaming : .completed,
            text: text ?? detail ?? title ?? ""
        )
    }

    private var kind: CoFleetTurnItemKind {
        if role == "user" || type == "userMessage" { return .userMessage }
        switch type {
        case "agentMessage": return .assistantMessage
        case "reasoning": return .reasoning
        case "commandExecution": return .command
        case "fileChange": return .fileChange
        default: return role == "assistant" ? .assistantMessage : .tool
        }
    }
}

private struct NoteEnvelopeDTO: Decodable, Sendable { var note: NoteDTO? }

private struct NoteDTO: Decodable, Sendable {
    var id: String
    var projectID: String
    var sessionID: String?
    var markdown: String
    var revision: Int
    var updatedAt: FlexibleDate

    func model(hostID: CoFleetHostID) -> CoFleetNote {
        CoFleetNote(
            id: id,
            hostID: hostID,
            projectID: projectID,
            sessionID: sessionID,
            markdown: markdown,
            revision: revision,
            updatedAt: updatedAt.value
        )
    }
}

private struct NoteWriteDTO: Encodable, Sendable {
    var title = "Notes"
    var markdown: String
    var sessionID: String?
}

private struct TodoListDTO: Decodable, Sendable { var todos: [TodoDTO] }
private struct TodoEnvelopeDTO: Decodable, Sendable { var todo: TodoDTO }

private struct TodoDTO: Decodable, Sendable {
    var id: String
    var projectID: String
    var text: String
    var completed: Bool
    var position: Int
    var revision: Int
    var updatedAt: FlexibleDate

    func model(hostID: CoFleetHostID) -> CoFleetTodoItem {
        CoFleetTodoItem(
            id: id,
            hostID: hostID,
            projectID: projectID,
            title: text,
            isCompleted: completed,
            sortIndex: position,
            revision: revision,
            updatedAt: updatedAt.value
        )
    }
}

private struct TodoWriteDTO: Encodable, Sendable {
    var text: String
    var completed: Bool
    var position: Int

    init(todo: CoFleetTodoItem) {
        text = todo.title
        completed = todo.isCompleted
        position = todo.sortIndex
    }
}

private struct PetListDTO: Decodable, Sendable { var pets: [PetDTO] }
private struct PetEnvelopeDTO: Decodable, Sendable { var pet: PetDTO }

private struct PetDTO: Decodable, Sendable {
    struct Manifest: Decodable, Sendable {
        var spriteVersionNumber: Int
        var spritesheetPath: String
        var frameWidth: Int
        var frameHeight: Int
        var columns: Int
        var rows: Int
    }
    var id: String
    var displayName: String
    var description: String
    var spriteVersionNumber: Int
    var digest: String
    var manifest: Manifest

    func model(hostID: CoFleetHostID) -> CoFleetPetManifest {
        CoFleetPetManifest(
            hostID: hostID,
            id: id,
            displayName: displayName,
            description: description,
            spriteVersionNumber: spriteVersionNumber,
            spritesheetPath: manifest.spritesheetPath,
            frameWidth: manifest.frameWidth,
            frameHeight: manifest.frameHeight,
            columns: manifest.columns,
            rows: manifest.rows,
            digest: digest
        )
    }
}

private struct DiscoveredPetListDTO: Decodable, Sendable {
    var pets: [DiscoveredPetDTO]
}

private struct DiscoveredPetDTO: Decodable, Sendable {
    var sourcePath: String
    var displayName: String
    var description: String
    var spriteVersionNumber: Int
    var digest: String

    func model(hostID: CoFleetHostID) -> CoFleetDiscoveredPet {
        CoFleetDiscoveredPet(
            hostID: hostID,
            sourcePath: sourcePath,
            displayName: displayName,
            description: description,
            spriteVersionNumber: spriteVersionNumber,
            digest: digest
        )
    }
}

private struct FlexibleDate: Decodable, Sendable {
    var value: Date

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = Date(timeIntervalSince1970: number > 10_000_000_000 ? number / 1_000 : number)
            return
        }
        let string = try container.decode(String.self)
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: string) else { throw CoFleetClientError.invalidResponse }
        value = date
    }
}

private extension String {
    var pathComponent: String {
        addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? self
    }
}
