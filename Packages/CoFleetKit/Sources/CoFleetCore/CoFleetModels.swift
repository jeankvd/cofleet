import Foundation

public struct CoFleetHostID: RawRepresentable, Codable, Hashable, Sendable, Identifiable {
    public let rawValue: String
    public var id: String { rawValue }

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if let value = try? single.decode(String.self) {
            rawValue = value
            return
        }

        // Read the object produced by early CoFleet development builds so a
        // stored pairing survives the public wire format becoming a string.
        let keyed = try decoder.container(keyedBy: CodingKeys.self)
        rawValue = try keyed.decode(String.self, forKey: .rawValue)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }
}

public enum CoFleetReachability: String, Codable, Hashable, Sendable {
    case online
    case offline
    case degraded
    case unknown
}

public struct CoFleetHostCapabilities: Codable, Hashable, Sendable {
    public var canBrowseDirectories: Bool
    public var canCreateDirectories: Bool
    public var canImportPets: Bool
    public var supportsPlasticSCM: Bool

    public init(
        canBrowseDirectories: Bool = true,
        canCreateDirectories: Bool = true,
        canImportPets: Bool = true,
        supportsPlasticSCM: Bool = false
    ) {
        self.canBrowseDirectories = canBrowseDirectories
        self.canCreateDirectories = canCreateDirectories
        self.canImportPets = canImportPets
        self.supportsPlasticSCM = supportsPlasticSCM
    }
}

public struct CoFleetHostInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: CoFleetHostID
    public var displayName: String
    public var platform: String
    public var canonicalHome: String
    public var reachability: CoFleetReachability
    public var capabilities: CoFleetHostCapabilities
    public var lastSeenAt: Date?

    public init(
        id: CoFleetHostID,
        displayName: String,
        platform: String,
        canonicalHome: String,
        reachability: CoFleetReachability,
        capabilities: CoFleetHostCapabilities = .init(),
        lastSeenAt: Date? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.platform = platform
        self.canonicalHome = canonicalHome
        self.reachability = reachability
        self.capabilities = capabilities
        self.lastSeenAt = lastSeenAt
    }
}

public struct CoFleetAccountInfo: Codable, Identifiable, Hashable, Sendable {
    public var hostID: CoFleetHostID
    public var authenticationType: String?
    public var email: String?
    public var planType: String?
    public var requiresOpenAIAuthentication: Bool

    public var id: CoFleetHostID { hostID }
    public var isSignedIn: Bool { authenticationType != nil }

    public init(
        hostID: CoFleetHostID,
        authenticationType: String? = nil,
        email: String? = nil,
        planType: String? = nil,
        requiresOpenAIAuthentication: Bool = true
    ) {
        self.hostID = hostID
        self.authenticationType = authenticationType
        self.email = email
        self.planType = planType
        self.requiresOpenAIAuthentication = requiresOpenAIAuthentication
    }
}

public struct CoFleetLoginChallenge: Codable, Identifiable, Hashable, Sendable {
    public var loginID: String
    public var verificationURL: URL
    public var userCode: String?
    public var id: String { loginID }

    public init(loginID: String, verificationURL: URL, userCode: String? = nil) {
        self.loginID = loginID
        self.verificationURL = verificationURL
        self.userCode = userCode
    }
}

public struct CoFleetRateLimitWindow: Codable, Hashable, Sendable {
    public var usedPercent: Int
    public var resetsAt: Date?
    public var windowDurationMinutes: Int?

    public init(usedPercent: Int, resetsAt: Date? = nil, windowDurationMinutes: Int? = nil) {
        self.usedPercent = min(100, max(0, usedPercent))
        self.resetsAt = resetsAt
        self.windowDurationMinutes = windowDurationMinutes
    }
}

public struct CoFleetRateLimitInfo: Codable, Identifiable, Hashable, Sendable {
    public var hostID: CoFleetHostID
    public var limitID: String
    public var displayName: String?
    public var planType: String?
    public var primary: CoFleetRateLimitWindow?
    public var secondary: CoFleetRateLimitWindow?

    public var id: String { "\(hostID.rawValue):\(limitID)" }

    public init(
        hostID: CoFleetHostID,
        limitID: String,
        displayName: String? = nil,
        planType: String? = nil,
        primary: CoFleetRateLimitWindow? = nil,
        secondary: CoFleetRateLimitWindow? = nil
    ) {
        self.hostID = hostID
        self.limitID = limitID
        self.displayName = displayName
        self.planType = planType
        self.primary = primary
        self.secondary = secondary
    }
}

public enum CoFleetProjectState: String, Codable, Hashable, Sendable {
    case idle
    case working
    case waitingForApproval
    case waitingForAnswer
    case replied
    case unavailable
}

public enum CoFleetSourceControlKind: String, Codable, Hashable, Sendable {
    case none
    case git
    case plastic
}

public enum CoFleetSourceControlState: String, Codable, Hashable, Sendable {
    case unavailable
    case clean
    case dirty
    case staged
    case unpushed
    case draftPullRequest
    case openPullRequest
}

public struct CoFleetSourceControlStatus: Codable, Hashable, Sendable {
    public var kind: CoFleetSourceControlKind
    public var state: CoFleetSourceControlState
    public var branch: String?
    public var summary: String?
    public var observedAt: Date

    public init(
        kind: CoFleetSourceControlKind,
        state: CoFleetSourceControlState,
        branch: String? = nil,
        summary: String? = nil,
        observedAt: Date = .now
    ) {
        self.kind = kind
        self.state = state
        self.branch = branch
        self.summary = summary
        self.observedAt = observedAt
    }
}

public struct CoFleetProject: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var hostID: CoFleetHostID
    public var displayName: String
    public var canonicalPath: String
    public var state: CoFleetProjectState
    public var isVisible: Bool
    public var sortIndex: Int
    public var currentSessionID: String?
    public var selectedPetID: String?
    public var sourceControl: CoFleetSourceControlStatus?

    public init(
        id: String = "project-\(UUID().uuidString)",
        hostID: CoFleetHostID,
        displayName: String,
        canonicalPath: String,
        state: CoFleetProjectState = .idle,
        isVisible: Bool = true,
        sortIndex: Int = 0,
        currentSessionID: String? = nil,
        selectedPetID: String? = nil,
        sourceControl: CoFleetSourceControlStatus? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.displayName = displayName
        self.canonicalPath = canonicalPath
        self.state = state
        self.isVisible = isVisible
        self.sortIndex = sortIndex
        self.currentSessionID = currentSessionID
        self.selectedPetID = selectedPetID
        self.sourceControl = sourceControl
    }

    public var canonicalIdentity: String {
        "\(hostID.rawValue):\(canonicalPath)"
    }
}

public enum CoFleetSessionState: String, Codable, Hashable, Sendable {
    case idle
    case active
    case waitingForInteraction
    case completed
    case interrupted
    case failed
    case archived
}

public struct CoFleetSessionSummary: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var hostID: CoFleetHostID
    public var projectID: String
    public var title: String
    public var state: CoFleetSessionState
    public var updatedAt: Date
    public var createdAt: Date
    public var preview: String?
    public var modelID: String?
    public var reasoningEffort: String?
    public var serviceTier: String?
    public var accessLevel: CoFleetAccessLevel

    public init(
        id: String,
        hostID: CoFleetHostID,
        projectID: String,
        title: String,
        state: CoFleetSessionState = .idle,
        updatedAt: Date = .now,
        createdAt: Date = .now,
        preview: String? = nil,
        modelID: String? = nil,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil,
        accessLevel: CoFleetAccessLevel = .askForApproval
    ) {
        self.id = id
        self.hostID = hostID
        self.projectID = projectID
        self.title = title
        self.state = state
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.preview = preview
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.accessLevel = accessLevel
    }

    public var settings: CoFleetSessionSettings {
        CoFleetSessionSettings(
            modelID: modelID,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            accessLevel: accessLevel
        )
    }
}

public struct CoFleetSessionPage: Codable, Hashable, Sendable {
    public var items: [CoFleetSessionSummary]
    public var nextCursor: String?

    public init(items: [CoFleetSessionSummary], nextCursor: String?) {
        self.items = Array(items.prefix(5))
        self.nextCursor = nextCursor
    }
}

public enum CoFleetTurnState: String, Codable, Hashable, Sendable {
    case queued
    case running
    case waitingForInteraction
    case completed
    case interrupted
    case failed
}

public struct CoFleetTurn: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var hostID: CoFleetHostID
    public var sessionID: String
    public var state: CoFleetTurnState
    public var startedAt: Date
    public var completedAt: Date?
    public var errorMessage: String?

    public init(
        id: String,
        hostID: CoFleetHostID,
        sessionID: String,
        state: CoFleetTurnState,
        startedAt: Date = .now,
        completedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.sessionID = sessionID
        self.state = state
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.errorMessage = errorMessage
    }
}

public enum CoFleetTurnInput: Hashable, Sendable {
    case text(String)
    case imageURL(URL)
    case localImage(path: String)
}

public enum CoFleetTurnAttachmentSource: Hashable, Sendable {
    case imageURL(URL)
    case localImage(path: String)

    public var input: CoFleetTurnInput {
        switch self {
        case let .imageURL(url): .imageURL(url)
        case let .localImage(path): .localImage(path: path)
        }
    }
}

public struct CoFleetTurnAttachment: Identifiable, Hashable, Sendable {
    public static let maximumCount = 4
    public static let maximumLocalImageByteCount = 20 * 1_024 * 1_024
    public static let maximumURLCharacterCount = 2_000
    public static let maximumLocalPathCharacterCount = 4_096

    public var id: UUID
    public var source: CoFleetTurnAttachmentSource
    public var displayName: String
    public var byteCount: Int?

    public init(
        id: UUID = UUID(),
        source: CoFleetTurnAttachmentSource,
        displayName: String,
        byteCount: Int? = nil
    ) {
        self.id = id
        self.source = source
        self.displayName = displayName
        self.byteCount = byteCount
    }

    public static func imageURL(_ url: URL, id: UUID = UUID()) throws -> Self {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil else {
            throw CoFleetTurnAttachmentError.invalidImageURL
        }
        components.scheme = scheme
        guard let normalizedURL = components.url,
              normalizedURL.absoluteString.count <= maximumURLCharacterCount else {
            throw CoFleetTurnAttachmentError.invalidImageURL
        }
        let fallbackName = normalizedURL.host ?? "Remote image"
        let lastPathComponent = normalizedURL.lastPathComponent
        return Self(
            id: id,
            source: .imageURL(normalizedURL),
            displayName: lastPathComponent.isEmpty ? fallbackName : lastPathComponent
        )
    }

    public static func localImage(
        _ fileURL: URL,
        insideProjectRoot projectRootURL: URL,
        id: UUID = UUID(),
        fileManager: FileManager = .default
    ) throws -> Self {
        guard fileURL.isFileURL, projectRootURL.isFileURL else {
            throw CoFleetTurnAttachmentError.invalidLocalImage
        }
        let resolvedFile = fileURL.resolvingSymlinksInPath().standardizedFileURL
        let resolvedRoot = projectRootURL.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = resolvedRoot.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard resolvedFile.path.hasPrefix(rootPrefix),
              resolvedFile.path.count <= maximumLocalPathCharacterCount else {
            throw CoFleetTurnAttachmentError.outsideProjectRoot
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: resolvedFile.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let attributes = try? fileManager.attributesOfItem(atPath: resolvedFile.path),
              let sizeNumber = attributes[.size] as? NSNumber else {
            throw CoFleetTurnAttachmentError.invalidLocalImage
        }
        let byteCount = sizeNumber.intValue
        guard byteCount <= maximumLocalImageByteCount else {
            throw CoFleetTurnAttachmentError.localImageTooLarge(
                maximumByteCount: maximumLocalImageByteCount
            )
        }
        return Self(
            id: id,
            source: .localImage(path: resolvedFile.path),
            displayName: resolvedFile.lastPathComponent,
            byteCount: byteCount
        )
    }

    public func validateForQueue() throws {
        switch source {
        case let .imageURL(url):
            _ = try Self.imageURL(url, id: id)
        case let .localImage(path):
            guard !path.isEmpty, path.count <= Self.maximumLocalPathCharacterCount else {
                throw CoFleetTurnAttachmentError.invalidLocalImage
            }
            if let byteCount, byteCount > Self.maximumLocalImageByteCount {
                throw CoFleetTurnAttachmentError.localImageTooLarge(
                    maximumByteCount: Self.maximumLocalImageByteCount
                )
            }
        }
    }
}

public enum CoFleetTurnAttachmentError: Error, Equatable, LocalizedError, Sendable {
    case invalidImageURL
    case invalidLocalImage
    case outsideProjectRoot
    case localImageTooLarge(maximumByteCount: Int)
    case tooManyAttachments(maximumCount: Int)
    case duplicateAttachment

    public var errorDescription: String? {
        switch self {
        case .invalidImageURL:
            "Enter a valid HTTP or HTTPS image URL without embedded credentials."
        case .invalidLocalImage:
            "The selected image is not a readable file."
        case .outsideProjectRoot:
            "Choose an image inside the selected project's folder."
        case let .localImageTooLarge(maximumByteCount):
            "Images must be \(maximumByteCount / 1_024 / 1_024) MB or smaller."
        case let .tooManyAttachments(maximumCount):
            "You can attach up to \(maximumCount) images to one turn."
        case .duplicateAttachment:
            "That image is already attached."
        }
    }
}

public enum CoFleetTurnItemKind: String, Codable, Hashable, Sendable {
    case userMessage
    case assistantMessage
    case reasoning
    case command
    case fileChange
    case tool
    case system
}

public enum CoFleetTurnItemState: String, Codable, Hashable, Sendable {
    case pending
    case streaming
    case completed
    case failed
}

public struct CoFleetTurnItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var turnID: String
    public var kind: CoFleetTurnItemKind
    public var state: CoFleetTurnItemState
    public var text: String
    public var createdAt: Date

    public init(
        id: String,
        turnID: String,
        kind: CoFleetTurnItemKind,
        state: CoFleetTurnItemState = .completed,
        text: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.turnID = turnID
        self.kind = kind
        self.state = state
        self.text = text
        self.createdAt = createdAt
    }
}

public enum CoFleetInteractionKind: String, Codable, Hashable, Sendable {
    case commandApproval
    case fileApproval
    case permissionApproval
    case question
    case mcpElicitation
}

public enum CoFleetInteractionState: String, Codable, Hashable, Sendable {
    case pending
    case resolved
    case expired
}

public enum CoFleetInteractionDecision: String, Codable, Hashable, Sendable {
    case allowOnce
    case allowForSession
    case deny
    case denyAndStop
    case submitAnswer
    case accept
    case decline
    case cancel
}

public struct CoFleetInteractionOption: Codable, Identifiable, Hashable, Sendable {
    public var label: String
    public var detail: String?

    public var id: String { label }

    public init(label: String, detail: String? = nil) {
        self.label = label
        self.detail = detail
    }
}

public struct CoFleetInteractionQuestion: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var header: String
    public var prompt: String
    public var options: [CoFleetInteractionOption]
    public var allowsFreeform: Bool
    public var isSecret: Bool

    public init(
        id: String,
        header: String,
        prompt: String,
        options: [CoFleetInteractionOption] = [],
        allowsFreeform: Bool = true,
        isSecret: Bool = false
    ) {
        self.id = id
        self.header = header
        self.prompt = prompt
        self.options = options
        self.allowsFreeform = allowsFreeform
        self.isSecret = isSecret
    }
}

public struct CoFleetInteraction: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var hostID: CoFleetHostID
    public var sessionID: String
    public var turnID: String
    public var kind: CoFleetInteractionKind
    public var state: CoFleetInteractionState
    public var title: String
    public var detail: String
    public var choices: [CoFleetInteractionDecision]
    public var questions: [CoFleetInteractionQuestion]
    public var expiresAt: Date

    public init(
        id: String,
        hostID: CoFleetHostID,
        sessionID: String,
        turnID: String,
        kind: CoFleetInteractionKind,
        state: CoFleetInteractionState = .pending,
        title: String,
        detail: String,
        choices: [CoFleetInteractionDecision],
        questions: [CoFleetInteractionQuestion] = [],
        expiresAt: Date
    ) {
        self.id = id
        self.hostID = hostID
        self.sessionID = sessionID
        self.turnID = turnID
        self.kind = kind
        self.state = state
        self.title = title
        self.detail = detail
        self.choices = choices
        self.questions = questions
        self.expiresAt = expiresAt
    }
}

public struct CoFleetModelInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var supportedReasoningEfforts: [String]
    public var supportedServiceTiers: [String]
    public var contextWindow: Int?
    public var isDefault: Bool

    public init(
        id: String,
        displayName: String,
        supportedReasoningEfforts: [String] = [],
        supportedServiceTiers: [String] = [],
        contextWindow: Int? = nil,
        isDefault: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.supportedReasoningEfforts = supportedReasoningEfforts
        self.supportedServiceTiers = supportedServiceTiers
        self.contextWindow = contextWindow
        self.isDefault = isDefault
    }
}

public struct CoFleetDirectoryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String { canonicalPath }
    public var name: String
    public var canonicalPath: String
    public var isSymbolicLink: Bool
    public var isReadable: Bool

    public init(
        name: String,
        canonicalPath: String,
        isSymbolicLink: Bool = false,
        isReadable: Bool = true
    ) {
        self.name = name
        self.canonicalPath = canonicalPath
        self.isSymbolicLink = isSymbolicLink
        self.isReadable = isReadable
    }
}

public struct CoFleetDirectoryPage: Codable, Hashable, Sendable {
    public var canonicalPath: String
    public var parentPath: String?
    public var entries: [CoFleetDirectoryEntry]
    public var nextCursor: String?

    public init(
        canonicalPath: String,
        parentPath: String?,
        entries: [CoFleetDirectoryEntry],
        nextCursor: String? = nil
    ) {
        self.canonicalPath = canonicalPath
        self.parentPath = parentPath
        self.entries = entries
        self.nextCursor = nextCursor
    }
}

public struct CoFleetPairingReceipt: Codable, Hashable, Sendable {
    public var host: CoFleetHostInfo
    public var deviceID: String
    public var token: String

    public init(host: CoFleetHostInfo, deviceID: String, token: String) {
        self.host = host
        self.deviceID = deviceID
        self.token = token
    }
}

public struct CoFleetDeviceRotationReceipt: Codable, Hashable, Sendable {
    public var device: CoFleetPairedDevice
    public var token: String

    public init(device: CoFleetPairedDevice, token: String) {
        self.device = device
        self.token = token
    }
}

public struct CoFleetPairedDevice: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var createdAt: Date
    public var lastSeenAt: Date?
    public var isRevoked: Bool
    public var revokedAt: Date?

    public init(
        id: String,
        name: String,
        createdAt: Date,
        lastSeenAt: Date? = nil,
        isRevoked: Bool = false,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.lastSeenAt = lastSeenAt
        self.isRevoked = isRevoked
        self.revokedAt = revokedAt
    }
}
