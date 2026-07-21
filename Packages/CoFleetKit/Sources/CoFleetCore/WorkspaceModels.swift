import Foundation

public enum CoFleetAccessLevel: String, Codable, CaseIterable, Hashable, Sendable {
    case askForApproval
    case approveForMe
    case fullAccess

    public var displayName: String {
        switch self {
        case .askForApproval: "Ask for approval"
        case .approveForMe: "Approve for me"
        case .fullAccess: "Full access"
        }
    }

    public var requiresProminentWarning: Bool {
        self == .fullAccess
    }
}

public struct CoFleetCodexPermissionProfile: Codable, Equatable, Sendable {
    public enum Sandbox: String, Codable, Sendable {
        case workspaceWrite = "workspace-write"
        case dangerFullAccess = "danger-full-access"
    }

    public enum ApprovalPolicy: String, Codable, Sendable {
        case untrusted
        case onRequest = "on-request"
        case never
    }

    public enum ReviewMode: String, Codable, Sendable {
        case user
        case automatic = "auto_review"
    }

    public var sandbox: Sandbox
    public var approvalPolicy: ApprovalPolicy
    public var reviewMode: ReviewMode

    public init(sandbox: Sandbox, approvalPolicy: ApprovalPolicy, reviewMode: ReviewMode) {
        self.sandbox = sandbox
        self.approvalPolicy = approvalPolicy
        self.reviewMode = reviewMode
    }
}

public extension CoFleetAccessLevel {
    var codexPermissionProfile: CoFleetCodexPermissionProfile {
        switch self {
        case .askForApproval:
            .init(sandbox: .workspaceWrite, approvalPolicy: .untrusted, reviewMode: .user)
        case .approveForMe:
            .init(sandbox: .workspaceWrite, approvalPolicy: .onRequest, reviewMode: .automatic)
        case .fullAccess:
            .init(sandbox: .dangerFullAccess, approvalPolicy: .never, reviewMode: .user)
        }
    }
}

public struct CoFleetSessionSettings: Codable, Hashable, Sendable {
    public var modelID: String?
    public var reasoningEffort: String?
    public var serviceTier: String?
    public var accessLevel: CoFleetAccessLevel

    public init(
        modelID: String? = nil,
        reasoningEffort: String? = nil,
        serviceTier: String? = nil,
        accessLevel: CoFleetAccessLevel = .askForApproval
    ) {
        self.modelID = modelID
        self.reasoningEffort = reasoningEffort
        self.serviceTier = serviceTier
        self.accessLevel = accessLevel
    }
}

public struct CoFleetNote: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var hostID: CoFleetHostID
    public var projectID: String
    public var sessionID: String?
    public var markdown: String
    public var revision: Int
    public var updatedAt: Date

    public init(
        id: String = "note-\(UUID().uuidString)",
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String? = nil,
        markdown: String = "",
        revision: Int = 0,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.hostID = hostID
        self.projectID = projectID
        self.sessionID = sessionID
        self.markdown = markdown
        self.revision = revision
        self.updatedAt = updatedAt
    }

    public var eTag: String { "\"note-\(id)-\(revision)\"" }
}

public struct CoFleetTodoItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var hostID: CoFleetHostID
    public var projectID: String
    public var title: String
    public var isCompleted: Bool
    public var sortIndex: Int
    public var revision: Int
    public var updatedAt: Date

    public init(
        id: String = "todo-\(UUID().uuidString)",
        hostID: CoFleetHostID,
        projectID: String,
        title: String,
        isCompleted: Bool = false,
        sortIndex: Int = 0,
        revision: Int = 0,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.hostID = hostID
        self.projectID = projectID
        self.title = title
        self.isCompleted = isCompleted
        self.sortIndex = sortIndex
        self.revision = revision
        self.updatedAt = updatedAt
    }

    public var eTag: String { "\"todo-\(id)-\(revision)\"" }
}

public struct CoFleetPetManifest: Codable, Identifiable, Hashable, Sendable {
    public var hostID: CoFleetHostID
    public var id: String
    public var displayName: String
    public var description: String
    public var spriteVersionNumber: Int
    public var spritesheetPath: String
    public var frameWidth: Int
    public var frameHeight: Int
    public var columns: Int
    public var rows: Int
    public var digest: String

    public init(
        hostID: CoFleetHostID,
        id: String,
        displayName: String,
        description: String = "",
        spriteVersionNumber: Int,
        spritesheetPath: String,
        frameWidth: Int = 192,
        frameHeight: Int = 208,
        columns: Int = 8,
        rows: Int,
        digest: String
    ) {
        self.hostID = hostID
        self.id = id
        self.displayName = displayName
        self.description = description
        self.spriteVersionNumber = spriteVersionNumber
        self.spritesheetPath = spritesheetPath
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.columns = columns
        self.rows = rows
        self.digest = digest
    }

    public var canonicalIdentity: String { "\(hostID.rawValue):\(id)" }
    public var pixelWidth: Int { frameWidth * columns }
    public var pixelHeight: Int { frameHeight * rows }
}

public struct CoFleetDiscoveredPet: Codable, Identifiable, Hashable, Sendable {
    public var hostID: CoFleetHostID
    public var sourcePath: String
    public var displayName: String
    public var description: String
    public var spriteVersionNumber: Int
    public var digest: String

    public var id: String { "\(hostID.rawValue):\(digest)" }

    public init(
        hostID: CoFleetHostID,
        sourcePath: String,
        displayName: String,
        description: String = "",
        spriteVersionNumber: Int,
        digest: String
    ) {
        self.hostID = hostID
        self.sourcePath = sourcePath
        self.displayName = displayName
        self.description = description
        self.spriteVersionNumber = spriteVersionNumber
        self.digest = digest
    }
}

/// Durable handoff between a CoFleet project and the Codex task that is hatching
/// its next pet. CoFleet records the host catalog before starting the task, then
/// imports only packages that appear after the hatch begins.
public struct CoFleetPendingPetHatch: Codable, Identifiable, Hashable, Sendable {
    public static let storageIdentifier = "cofleet.petHatch.pending.v1"
    public static let readyPathPrefix = "COFLEET_PET_READY="

    public var id: UUID
    public var hostID: CoFleetHostID
    public var projectID: String
    public var sessionID: String
    public var baselineDigests: Set<String>
    public var startedAt: Date

    public init(
        id: UUID = UUID(),
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String,
        baselineDigests: Set<String>,
        startedAt: Date = .now
    ) {
        self.id = id
        self.hostID = hostID
        self.projectID = projectID
        self.sessionID = sessionID
        self.baselineDigests = baselineDigests
        self.startedAt = startedAt
    }

    /// The first turn deliberately starts with an interview. The Codex skill owns
    /// generation, deterministic validation, visual QA, and final packaging.
    public static let codexPrompt = """
    Use the $hatch-pet skill for this task.

    We are creating a new Codex-compatible v2 pet for CoFleet. Start by asking me in this chat what pet I want, including its name, appearance, style, personality, and any visual references. Do not begin image generation until I answer or explicitly ask you to choose.

    After I answer, follow the hatch-pet skill completely. Use its image-generation workflow, deterministic validation, visual QA, and packaging rules. Do not create a simplified atlas, invent a different package format, or skip QA. Install the final validated package under ~/.codex/pets/<pet-id>/ with pet.json and spritesheet.webp exactly as the skill requires.

    When packaging succeeds, state the exact absolute package path on its own line as:
    COFLEET_PET_READY=<absolute-package-path>

    CoFleet will discover, import, and select the validated package automatically.
    """

    public func newlyDiscoveredPets(in pets: [CoFleetDiscoveredPet]) -> [CoFleetDiscoveredPet] {
        pets.filter {
            $0.hostID == hostID && !baselineDigests.contains($0.digest)
        }
    }

    public func readyPackagePath(in items: [CoFleetTurnItem]) -> String? {
        items.reversed().lazy
            .filter { $0.kind == .assistantMessage }
            .flatMap { $0.text.components(separatedBy: .newlines).reversed() }
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix(Self.readyPathPrefix) }
            .map {
                String(
                    $0.trimmingCharacters(in: .whitespaces)
                        .dropFirst(Self.readyPathPrefix.count)
                ).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .flatMap { $0.isEmpty ? nil : $0 }
    }
}

public struct CoFleetPetAsset: Hashable, Sendable {
    public static let maximumByteCount = 16 * 1_024 * 1_024

    public var hostID: CoFleetHostID
    public var petID: String
    public var assetName: String
    public var mediaType: String
    public var data: Data

    public init(
        hostID: CoFleetHostID,
        petID: String,
        assetName: String,
        mediaType: String,
        data: Data
    ) throws {
        guard !data.isEmpty, data.count <= Self.maximumByteCount else {
            throw CoFleetPetManifestError.assetSize
        }
        self.hostID = hostID
        self.petID = petID
        self.assetName = assetName
        self.mediaType = mediaType
        self.data = data
    }
}

public enum CoFleetPetManifestError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case invalidIdentifier
    case invalidDisplayName
    case invalidDimensions
    case unsafeAssetPath(String)
    case invalidDigest
    case assetSize

    public var errorDescription: String? {
        switch self {
        case let .unsupportedVersion(version): "Unsupported pet manifest version \(version)."
        case .invalidIdentifier: "The pet identifier is invalid."
        case .invalidDisplayName: "The pet display name is invalid."
        case .invalidDimensions: "Codex pet atlases must use 192 x 208 cells in an 8 x 9 or 8 x 11 sheet."
        case let .unsafeAssetPath(path): "The pet contains an unsafe asset path: \(path)"
        case .invalidDigest: "The pet digest is invalid."
        case .assetSize: "The pet asset is empty or exceeds the 16 MiB limit."
        }
    }
}

public enum CoFleetPetManifestValidator {
    public static func validate(_ manifest: CoFleetPetManifest) throws {
        guard manifest.spriteVersionNumber == 1 || manifest.spriteVersionNumber == 2 else {
            throw CoFleetPetManifestError.unsupportedVersion(manifest.spriteVersionNumber)
        }
        let identifierPattern = /^[a-z0-9][a-z0-9._-]{0,79}$/
        guard manifest.id.wholeMatch(of: identifierPattern) != nil else {
            throw CoFleetPetManifestError.invalidIdentifier
        }
        let name = manifest.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CoFleetPetManifestError.invalidDisplayName
        }
        let expectedRows = manifest.spriteVersionNumber == 1 ? 9 : 11
        guard manifest.frameWidth == 192,
              manifest.frameHeight == 208,
              manifest.columns == 8,
              manifest.rows == expectedRows,
              manifest.pixelWidth == 1_536,
              manifest.pixelHeight == (manifest.spriteVersionNumber == 1 ? 1_872 : 2_288) else {
            throw CoFleetPetManifestError.invalidDimensions
        }
        let path = manifest.spritesheetPath
        guard path == "spritesheet.png" || path == "spritesheet.webp" else {
            throw CoFleetPetManifestError.unsafeAssetPath(path)
        }
        let digestPattern = /^[0-9a-f]{64}$/
        guard manifest.digest.wholeMatch(of: digestPattern) != nil else {
            throw CoFleetPetManifestError.invalidDigest
        }
    }
}

public enum CoFleetActionIndicator: String, Codable, Hashable, Sendable {
    case idle
    case thinking
    case runningCommand
    case reasoning
    case approvalNeeded
    case questionAsked
    case working
    case replied
}

/// A small, already-cropped pet frame safe to copy into the credential-free App Group snapshot.
/// Full sprite atlases remain on the paired host and are never sent to widgets or Apple Watch.
public struct CoFleetPetPreview: Codable, Hashable, Sendable {
    public static let maximumByteCount = 48 * 1_024
    public static let maximumDimension = 128

    public var petID: String
    public var mediaType: String
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var digest: String
    public var data: Data

    public init(
        petID: String,
        mediaType: String = "image/png",
        pixelWidth: Int,
        pixelHeight: Int,
        digest: String,
        data: Data
    ) {
        self.petID = petID
        self.mediaType = mediaType
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.digest = digest
        self.data = data
    }
}

public struct CoFleetWatchProjectSnapshot: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var hostID: CoFleetHostID?
    public var sessionID: String?
    public var name: String
    public var hostReachability: CoFleetReachability
    public var action: CoFleetActionIndicator
    public var latestMessage: String?
    public var pendingTodoCount: Int
    public var nextPendingTodoID: String?
    public var selectedPetID: String?
    public var petPreview: CoFleetPetPreview?
    public var sourceControl: CoFleetSourceControlStatus?

    public init(
        id: String,
        hostID: CoFleetHostID? = nil,
        sessionID: String? = nil,
        name: String,
        hostReachability: CoFleetReachability,
        action: CoFleetActionIndicator,
        latestMessage: String? = nil,
        pendingTodoCount: Int = 0,
        nextPendingTodoID: String? = nil,
        selectedPetID: String? = nil,
        petPreview: CoFleetPetPreview? = nil,
        sourceControl: CoFleetSourceControlStatus? = nil
    ) {
        self.id = id
        self.hostID = hostID
        self.sessionID = sessionID
        self.name = name
        self.hostReachability = hostReachability
        self.action = action
        self.latestMessage = latestMessage
        self.pendingTodoCount = pendingTodoCount
        self.nextPendingTodoID = nextPendingTodoID
        self.selectedPetID = selectedPetID
        self.petPreview = petPreview
        self.sourceControl = sourceControl
    }
}

public struct CoFleetWatchSnapshot: Codable, Hashable, Sendable {
    public var generatedAt: Date
    public var projects: [CoFleetWatchProjectSnapshot]
    public var focusedProjectID: String?
    public var mode: CoFleetWidgetMode

    public init(
        generatedAt: Date = .now,
        projects: [CoFleetWatchProjectSnapshot],
        focusedProjectID: String? = nil,
        mode: CoFleetWidgetMode = .focusedMessage
    ) {
        self.generatedAt = generatedAt
        self.projects = projects
        self.focusedProjectID = focusedProjectID
        self.mode = mode
    }

    public static let empty = CoFleetWatchSnapshot(projects: [])
}

public enum CoFleetWidgetMode: String, Codable, Hashable, Sendable {
    case focusedMessage
    case threePets
    case automatic

    /// Automatic widgets alternate on stable 30-minute boundaries so iOS and watchOS
    /// present the same mode without persisting another preference or polling a host.
    public func resolved(at date: Date) -> CoFleetWidgetMode {
        guard self == .automatic else { return self }
        let interval = Int(date.timeIntervalSince1970 / (30 * 60))
        return interval.isMultiple(of: 2) ? .focusedMessage : .threePets
    }
}

public enum CoFleetWatchDeliveryState: String, Codable, Hashable, Sendable {
    case pending
    case running
    case completed
    case notified
    case failed
}

public enum CoFleetWatchRequestKind: String, Codable, Hashable, Sendable {
    case startTurn
    case toggleTodo
}

/// A durable, host-scoped action created on Apple Watch and fulfilled by its paired iPhone.
/// The iPhone uses `id` as the Codex turn idempotency key, so replaying a WatchConnectivity
/// transfer cannot accidentally start the same turn twice.
public struct CoFleetWatchRequest: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var kind: CoFleetWatchRequestKind
    public var hostID: CoFleetHostID
    public var projectID: String
    public var sessionID: String?
    public var todoID: String?
    public var prompt: String?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: CoFleetWatchRequestKind,
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String? = nil,
        todoID: String? = nil,
        prompt: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.kind = kind
        self.hostID = hostID
        self.projectID = projectID
        self.sessionID = sessionID
        self.todoID = todoID
        self.prompt = prompt
        self.createdAt = createdAt
    }
}

public enum CoFleetWatchRelayPayloadKind: String, Codable, Hashable, Sendable {
    case request
    case delivery
    case snapshot
}

/// Versioned payload used for every WatchConnectivity transport. Exactly one value must match
/// `kind`; the transport validator rejects malformed or oversized payloads before routing them.
public struct CoFleetWatchRelayPayload: Codable, Hashable, Sendable {
    public var version: Int
    public var kind: CoFleetWatchRelayPayloadKind
    public var request: CoFleetWatchRequest?
    public var delivery: CoFleetWatchDelivery?
    public var snapshot: CoFleetWatchSnapshot?

    public init(request: CoFleetWatchRequest) {
        version = 1
        kind = .request
        self.request = request
        delivery = nil
        snapshot = nil
    }

    public init(delivery: CoFleetWatchDelivery) {
        version = 1
        kind = .delivery
        request = nil
        self.delivery = delivery
        snapshot = nil
    }

    public init(snapshot: CoFleetWatchSnapshot) {
        version = 1
        kind = .snapshot
        request = nil
        delivery = nil
        self.snapshot = snapshot
    }
}

public struct CoFleetWatchDelivery: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var hostID: CoFleetHostID
    public var projectID: String
    public var sessionID: String?
    public var turnID: String?
    public var state: CoFleetWatchDeliveryState
    public var responsePreview: String?
    public var errorMessage: String?
    public var request: CoFleetWatchRequest?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String? = nil,
        turnID: String? = nil,
        state: CoFleetWatchDeliveryState = .pending,
        responsePreview: String? = nil,
        errorMessage: String? = nil,
        request: CoFleetWatchRequest? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.hostID = hostID
        self.projectID = projectID
        self.sessionID = sessionID
        self.turnID = turnID
        self.state = state
        self.responsePreview = responsePreview
        self.errorMessage = errorMessage
        self.request = request
        self.updatedAt = updatedAt
    }
}
