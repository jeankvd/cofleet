import Foundation

/// The user-facing action currently being performed by a Codex project.
///
/// This is deliberately more specific than ``CoFleetProjectState``. Existing
/// views can continue to use the coarse state while Watch, widgets, and richer
/// status surfaces use this projection without knowing Codex wire details.
public enum CoFleetProjectActivity: String, Codable, Hashable, Sendable {
    case idle
    case thinking
    case reasoning
    case runningCommand
    case approval
    case question
    case replied

    public var projectState: CoFleetProjectState {
        switch self {
        case .idle:
            .idle
        case .thinking, .reasoning, .runningCommand:
            .working
        case .approval:
            .waitingForApproval
        case .question:
            .waitingForAnswer
        case .replied:
            .replied
        }
    }
}

public enum CoFleetProjectActivitySource: String, Codable, Hashable, Sendable {
    case codexAppServer
    case codexDesktop
    case unknown
}

/// The latest host-authoritative activity snapshot for a registered project.
public struct CoFleetProjectActivitySnapshot: Codable, Hashable, Sendable {
    public var projectID: String
    public var sessionID: String?
    public var turnID: String?
    public var activity: CoFleetProjectActivity
    public var observedAt: Date
    public var source: CoFleetProjectActivitySource

    public init(
        projectID: String,
        sessionID: String? = nil,
        turnID: String? = nil,
        activity: CoFleetProjectActivity,
        observedAt: Date = .now,
        source: CoFleetProjectActivitySource = .unknown
    ) {
        self.projectID = projectID
        self.sessionID = sessionID
        self.turnID = turnID
        self.activity = activity
        self.observedAt = observedAt
        self.source = source
    }
}

/// Coarse states carried by the provider-neutral host activity event.
public enum CoFleetHostActivityState: String, Codable, Hashable, Sendable {
    case idle
    case working
    case waitingForInteraction
    case failed
}

public struct CoFleetHostActivityUpdate: Hashable, Sendable {
    public var hostID: CoFleetHostID
    public var projectID: String
    public var sessionID: String?
    public var turnID: String?
    public var state: CoFleetHostActivityState
    public var itemKind: String?
    public var observedAt: Date
    public var source: CoFleetProjectActivitySource

    public init(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String? = nil,
        turnID: String? = nil,
        state: CoFleetHostActivityState,
        itemKind: String? = nil,
        observedAt: Date = .now,
        source: CoFleetProjectActivitySource = .unknown
    ) {
        self.hostID = hostID
        self.projectID = projectID
        self.sessionID = sessionID
        self.turnID = turnID
        self.state = state
        self.itemKind = itemKind
        self.observedAt = observedAt
        self.source = source
    }
}

public struct CoFleetSessionCatalogUpdate: Hashable, Sendable {
    public var hostID: CoFleetHostID
    public var projectID: String
    public var currentSessionID: String?

    public init(hostID: CoFleetHostID, projectID: String, currentSessionID: String?) {
        self.hostID = hostID
        self.projectID = projectID
        self.currentSessionID = currentSessionID
    }
}

/// Provider-neutral events on the single host-wide stream.
public enum CoFleetHostEvent: Hashable, Sendable {
    case activityChanged(CoFleetHostActivityUpdate)
    case sessionCatalogUpdated(CoFleetSessionCatalogUpdate)
    case turnUpdated(projectID: String?, turn: CoFleetTurn)
    case turnItem(projectID: String?, sessionID: String, item: CoFleetTurnItem)
    case interactionPending(projectID: String?, interaction: CoFleetInteraction)
    case interactionResolved(projectID: String?, sessionID: String?, interactionID: String)
    case interactionExpired(projectID: String?, sessionID: String?, interactionID: String)
    case resetRequired
    case checkpoint

    public var explicitProjectID: String? {
        switch self {
        case let .activityChanged(update): update.projectID
        case let .sessionCatalogUpdated(update): update.projectID
        case let .turnUpdated(projectID, _),
             let .turnItem(projectID, _, _),
             let .interactionPending(projectID, _),
             let .interactionResolved(projectID, _, _),
             let .interactionExpired(projectID, _, _): projectID
        case .resetRequired, .checkpoint: nil
        }
    }

    public var sessionID: String? {
        switch self {
        case let .activityChanged(update): update.sessionID
        case .sessionCatalogUpdated: nil
        case let .turnUpdated(_, turn): turn.sessionID
        case let .turnItem(_, sessionID, _): sessionID
        case let .interactionPending(_, interaction): interaction.sessionID
        case let .interactionResolved(_, sessionID, _),
             let .interactionExpired(_, sessionID, _): sessionID
        case .resetRequired, .checkpoint: nil
        }
    }
}

public struct CoFleetSequencedHostEvent: Hashable, Sendable {
    public var id: String?
    public var event: CoFleetHostEvent
    public var retryMilliseconds: Int?
    public var isReplay: Bool

    public init(
        id: String? = nil,
        event: CoFleetHostEvent,
        retryMilliseconds: Int? = nil,
        isReplay: Bool = false
    ) {
        self.id = id
        self.event = event
        self.retryMilliseconds = retryMilliseconds
        self.isReplay = isReplay
    }
}

/// Stateless projection rules shared by iPhone, Mac, Watch relay, and tests.
public enum CoFleetProjectActivityReducer {
    public static func reduce(
        current: CoFleetProjectActivitySnapshot?,
        projectID: String,
        event: CoFleetHostEvent,
        observedAt: Date = .now
    ) -> CoFleetProjectActivitySnapshot? {
        let sessionID = event.sessionID ?? current?.sessionID
        let turnID: String? = switch event {
        case let .activityChanged(update): update.turnID ?? current?.turnID
        case let .turnUpdated(_, turn): turn.id
        case let .turnItem(_, _, item): item.turnID
        case let .interactionPending(_, interaction): interaction.turnID
        default: current?.turnID
        }
        let source: CoFleetProjectActivitySource = switch event {
        case let .activityChanged(update): update.source
        default: current?.source ?? .unknown
        }
        let eventDate: Date = switch event {
        case let .activityChanged(update): update.observedAt
        case let .turnUpdated(_, turn): turn.completedAt ?? turn.startedAt
        case let .turnItem(_, _, item): item.createdAt
        default: observedAt
        }

        let projected: CoFleetProjectActivity?
        switch event {
        case let .activityChanged(update):
            projected = activity(
                state: update.state,
                itemKind: update.itemKind,
                preserving: current,
                sessionID: update.sessionID
            )
        case let .turnUpdated(_, turn):
            switch turn.state {
            case .queued, .running:
                projected = .thinking
            case .waitingForInteraction:
                projected = current?.activity == .question ? .question : .approval
            case .completed:
                projected = current?.activity == .replied ? .replied : .idle
            case .interrupted, .failed:
                projected = .idle
            }
        case let .turnItem(_, _, item):
            projected = activity(for: item)
        case let .interactionPending(_, interaction):
            switch interaction.kind {
            case .question, .mcpElicitation:
                projected = .question
            case .commandApproval, .fileApproval, .permissionApproval:
                projected = .approval
            }
        case .interactionResolved, .interactionExpired:
            projected = .thinking
        case .sessionCatalogUpdated, .resetRequired, .checkpoint:
            projected = nil
        }

        guard let projected else { return current }
        return CoFleetProjectActivitySnapshot(
            projectID: projectID,
            sessionID: sessionID,
            turnID: turnID,
            activity: projected,
            observedAt: eventDate,
            source: source
        )
    }

    private static func activity(
        state: CoFleetHostActivityState,
        itemKind: String?,
        preserving current: CoFleetProjectActivitySnapshot?,
        sessionID: String?
    ) -> CoFleetProjectActivity {
        let kind = itemKind?.lowercased() ?? ""
        switch state {
        case .idle:
            // A canonical assistant item is emitted immediately before the host
            // returns to idle. Preserve "replied" until the next turn starts so
            // a completed answer remains visible instead of flashing away.
            if current?.activity == .replied,
               sessionID == nil || current?.sessionID == sessionID {
                return .replied
            }
            // Codex Desktop writes its canonical transcript after the filesystem
            // wake reports idle. Keep the in-progress projection until the
            // targeted catalog/transcript reconciliation decides replied vs idle.
            if current?.source == .codexDesktop,
               let activity = current?.activity,
               activity == .thinking || activity == .reasoning || activity == .runningCommand,
               sessionID == nil || current?.sessionID == sessionID {
                return activity
            }
            return .idle
        case .failed:
            return .idle
        case .waitingForInteraction:
            if kind.contains("question") || kind.contains("elicitation") || kind.contains("input") {
                return .question
            }
            return .approval
        case .working:
            if kind.contains("reason") || kind.contains("plan") {
                return .reasoning
            }
            if kind.contains("command") || kind.contains("file") || kind.contains("tool") || kind.contains("mcp") {
                return .runningCommand
            }
            return .thinking
        }
    }

    private static func activity(for item: CoFleetTurnItem) -> CoFleetProjectActivity? {
        switch item.kind {
        case .assistantMessage:
            return item.state == .completed ? .replied : .thinking
        case .reasoning:
            return .reasoning
        case .command, .fileChange, .tool:
            return .runningCommand
        case .userMessage:
            return .thinking
        case .system:
            return nil
        }
    }
}

/// Exponential reconnect delay with bounded jitter. The stream cursor itself is
/// kept by the controller and sent as Last-Event-ID on every new connection.
public struct CoFleetHostEventReconnectBackoff: Sendable {
    public private(set) var attempt = 0

    public init() {}

    public mutating func reset() {
        attempt = 0
    }

    public mutating func nextDelay(
        serverRetryMilliseconds: Int? = nil,
        jitter: Double = 1
    ) -> Duration {
        if let serverRetryMilliseconds {
            attempt += 1
            return .milliseconds(min(30_000, max(250, serverRetryMilliseconds)))
        }
        let exponent = min(attempt, 6)
        attempt += 1
        let baseMilliseconds = min(30_000, 500 * (1 << exponent))
        let boundedJitter = min(1.25, max(0.75, jitter))
        return .milliseconds(Int(Double(baseMilliseconds) * boundedJitter))
    }
}
