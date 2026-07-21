import CoFleetCore
import Foundation

public struct CoFleetSSEEvent: Equatable, Sendable {
    public var id: String?
    public var name: String?
    public var data: String
    public var retryMilliseconds: Int?

    public init(id: String? = nil, name: String? = nil, data: String, retryMilliseconds: Int? = nil) {
        self.id = id
        self.name = name
        self.data = data
        self.retryMilliseconds = retryMilliseconds
    }
}

public enum CoFleetTransportLimitError: Error, Equatable, LocalizedError, Sendable {
    case sseLineTooLarge(maxBytes: Int)
    case sseEventTooLarge(maxBytes: Int)
    case responseBodyTooLarge(maxBytes: Int)

    public var errorDescription: String? {
        switch self {
        case let .sseLineTooLarge(maxBytes):
            "The host sent an SSE line larger than the \(maxBytes)-byte limit."
        case let .sseEventTooLarge(maxBytes):
            "The host sent an SSE event larger than the \(maxBytes)-byte limit."
        case let .responseBodyTooLarge(maxBytes):
            "The host response exceeded the \(maxBytes)-byte limit."
        }
    }
}

public struct CoFleetSSEParser: Sendable {
    public static let defaultMaximumLineBytes = 64 * 1_024
    public static let defaultMaximumEventBytes = 1_024 * 1_024

    private let maximumLineBytes: Int
    private let maximumEventBytes: Int
    private var lineBuffer = Data()
    private var currentEventBytes = 0
    private var eventID: String?
    private var eventName: String?
    private var dataLines: [String] = []
    private var retryMilliseconds: Int?

    public init(
        maximumLineBytes: Int = CoFleetSSEParser.defaultMaximumLineBytes,
        maximumEventBytes: Int = CoFleetSSEParser.defaultMaximumEventBytes
    ) {
        self.maximumLineBytes = max(1, maximumLineBytes)
        self.maximumEventBytes = max(1, maximumEventBytes)
        lineBuffer.reserveCapacity(min(self.maximumLineBytes, 1_024))
    }

    public mutating func feed(_ data: Data) throws -> [CoFleetSSEEvent] {
        var output: [CoFleetSSEEvent] = []

        for byte in data {
            if byte == 0x0A {
                output.append(contentsOf: try consumeBufferedLine())
            } else {
                guard lineBuffer.count < maximumLineBytes else {
                    throw CoFleetTransportLimitError.sseLineTooLarge(maxBytes: maximumLineBytes)
                }
                lineBuffer.append(byte)
            }
        }
        return output
    }

    public mutating func finish() throws -> [CoFleetSSEEvent] {
        var output: [CoFleetSSEEvent] = []
        if !lineBuffer.isEmpty {
            output.append(contentsOf: try consumeBufferedLine())
        }
        if let event = dispatchEventIfPresent() {
            output.append(event)
        }
        return output
    }

    private mutating func consumeBufferedLine() throws -> [CoFleetSSEEvent] {
        var rawLine = lineBuffer
        lineBuffer.removeAll(keepingCapacity: true)
        if rawLine.last == 0x0D { rawLine.removeLast() }

        if rawLine.isEmpty {
            return dispatchEventIfPresent().map { [$0] } ?? []
        }

        let lineBytesWithDelimiter = rawLine.count + 1
        guard lineBytesWithDelimiter <= maximumEventBytes,
              currentEventBytes <= maximumEventBytes - lineBytesWithDelimiter else {
            throw CoFleetTransportLimitError.sseEventTooLarge(maxBytes: maximumEventBytes)
        }
        currentEventBytes += lineBytesWithDelimiter

        guard let line = String(data: rawLine, encoding: .utf8) else {
            throw CoFleetClientError.invalidResponse
        }
        if line.hasPrefix(":") { return [] }

        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.first == " " { value.removeFirst() }
        switch field {
        case "id": eventID = value
        case "event": eventName = value
        case "data": dataLines.append(value)
        case "retry": retryMilliseconds = Int(value)
        default: break
        }
        return []
    }

    private mutating func dispatchEventIfPresent() -> CoFleetSSEEvent? {
        defer {
            currentEventBytes = 0
            eventName = nil
            dataLines.removeAll(keepingCapacity: true)
            retryMilliseconds = nil
        }
        guard !dataLines.isEmpty || eventName != nil else { return nil }
        return CoFleetSSEEvent(
            id: eventID,
            name: eventName,
            data: dataLines.joined(separator: "\n"),
            retryMilliseconds: retryMilliseconds
        )
    }
}

public struct CoFleetBoundedBodyAccumulator: Sendable {
    public let maximumBytes: Int
    public private(set) var data: Data

    public init(maximumBytes: Int) {
        self.maximumBytes = max(1, maximumBytes)
        data = Data()
        data.reserveCapacity(min(self.maximumBytes, 64 * 1_024))
    }

    public mutating func append(_ byte: UInt8) throws {
        guard data.count < maximumBytes else {
            throw CoFleetTransportLimitError.responseBodyTooLarge(maxBytes: maximumBytes)
        }
        data.append(byte)
    }
}

public struct CoFleetTurnEventEnvelope: Codable, Sendable {
    public var type: String
    public var turn: CoFleetTurn?
    public var item: CoFleetTurnItem?
    public var interaction: CoFleetInteraction?
    public var interactionID: String?

    public init(
        type: String,
        turn: CoFleetTurn? = nil,
        item: CoFleetTurnItem? = nil,
        interaction: CoFleetInteraction? = nil,
        interactionID: String? = nil
    ) {
        self.type = type
        self.turn = turn
        self.item = item
        self.interaction = interaction
        self.interactionID = interactionID
    }

    public func event() throws -> CoFleetTurnEvent {
        switch type {
        case "turn.updated":
            guard let turn else { throw CoFleetClientError.invalidResponse }
            return .turn(turn)
        case "turn.item":
            guard let item else { throw CoFleetClientError.invalidResponse }
            return .upsertItem(item)
        case "interaction.pending":
            guard let interaction else { throw CoFleetClientError.invalidResponse }
            return .interaction(interaction)
        case "interaction.resolved":
            guard let interactionID else { throw CoFleetClientError.invalidResponse }
            return .interactionResolved(id: interactionID)
        case "interaction.expired":
            guard let interactionID else { throw CoFleetClientError.invalidResponse }
            return .interactionExpired(id: interactionID)
        case "stream.reset":
            return .resetRequired
        default:
            throw CoFleetClientError.incompatible("The host sent an unsupported event type: \(type)")
        }
    }
}

/// Converts the public CoFleet SSE contract into Core events. Provider-native
/// Codex notifications never reach this boundary. Events added by a newer host
/// become cursor checkpoints instead of terminating and replaying the stream.
public struct CoFleetTurnEventDecoder: Sendable {
    private static let supportedNames: Set<String> = [
        "turn.updated",
        "turn.item",
        "interaction.pending",
        "interaction.resolved",
        "interaction.expired",
        "stream.reset",
    ]

    public init() {}

    public func decode(_ event: CoFleetSSEEvent) throws -> CoFleetSequencedTurnEvent {
        if event.name == "resetRequired" || event.name == "stream.reset" {
            return CoFleetSequencedTurnEvent(id: event.id, event: .resetRequired)
        }
        guard let name = event.name, Self.supportedNames.contains(name) else {
            return CoFleetSequencedTurnEvent(id: event.id, event: .checkpoint)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(
            CoFleetTurnEventEnvelope.self,
            from: Data(event.data.utf8)
        )
        guard envelope.type == name else {
            throw CoFleetClientError.invalidResponse
        }
        return CoFleetSequencedTurnEvent(id: event.id, event: try envelope.event())
    }
}

/// Decodes the host-wide event log without exposing provider-native payloads.
/// Unknown events still advance the replay cursor as checkpoints so a newer
/// host cannot trap an older client in a reconnect loop.
public struct CoFleetHostEventDecoder: Sendable {
    private let hostID: CoFleetHostID

    public init(hostID: CoFleetHostID) {
        self.hostID = hostID
    }

    public func decode(_ event: CoFleetSSEEvent) throws -> CoFleetSequencedHostEvent {
        guard let name = event.name else {
            return result(event, .checkpoint)
        }
        if name == "resetRequired" || name == "stream.reset" {
            return result(event, .resetRequired)
        }

        let data = Data(event.data.utf8)
        switch name {
        case "project.activityChanged":
            let payload = try decoder.decode(ActivityPayload.self, from: data)
            guard !payload.projectID.isEmpty,
                  let state = CoFleetHostActivityState(rawValue: payload.state) else {
                throw CoFleetClientError.invalidResponse
            }
            let source = payload.source.flatMap(CoFleetProjectActivitySource.init(rawValue:)) ?? .unknown
            return result(event, .activityChanged(.init(
                hostID: payload.hostID.map(CoFleetHostID.init(rawValue:)) ?? hostID,
                projectID: payload.projectID,
                sessionID: payload.sessionID,
                turnID: payload.turnID,
                state: state,
                itemKind: payload.itemKind,
                observedAt: payload.observedAt ?? .now,
                source: source
            )))
        case "session.catalogUpdated":
            let payload = try decoder.decode(CatalogPayload.self, from: data)
            guard !payload.projectID.isEmpty else { throw CoFleetClientError.invalidResponse }
            return result(event, .sessionCatalogUpdated(.init(
                hostID: hostID,
                projectID: payload.projectID,
                currentSessionID: payload.currentSessionID
            )))
        case "turn.updated":
            let payload = try decoder.decode(TurnPayload.self, from: data)
            return result(event, .turnUpdated(projectID: payload.projectID, turn: payload.turn))
        case "turn.item":
            let payload = try decoder.decode(ItemPayload.self, from: data)
            guard !payload.sessionID.isEmpty else { throw CoFleetClientError.invalidResponse }
            return result(event, .turnItem(
                projectID: payload.projectID,
                sessionID: payload.sessionID,
                item: payload.item
            ))
        case "interaction.pending":
            let payload = try decoder.decode(InteractionPayload.self, from: data)
            return result(event, .interactionPending(
                projectID: payload.projectID,
                interaction: payload.interaction
            ))
        case "interaction.resolved":
            let payload = try decoder.decode(InteractionLifecyclePayload.self, from: data)
            guard !payload.interactionID.isEmpty else { throw CoFleetClientError.invalidResponse }
            return result(event, .interactionResolved(
                projectID: payload.projectID,
                sessionID: payload.sessionID,
                interactionID: payload.interactionID
            ))
        case "interaction.expired":
            let payload = try decoder.decode(InteractionLifecyclePayload.self, from: data)
            guard !payload.interactionID.isEmpty else { throw CoFleetClientError.invalidResponse }
            return result(event, .interactionExpired(
                projectID: payload.projectID,
                sessionID: payload.sessionID,
                interactionID: payload.interactionID
            ))
        default:
            return result(event, .checkpoint)
        }
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func result(
        _ raw: CoFleetSSEEvent,
        _ event: CoFleetHostEvent
    ) -> CoFleetSequencedHostEvent {
        CoFleetSequencedHostEvent(
            id: raw.id,
            event: event,
            retryMilliseconds: raw.retryMilliseconds
        )
    }
}

private struct ActivityPayload: Decodable {
    var hostID: String?
    var projectID: String
    var sessionID: String?
    var turnID: String?
    var state: String
    var itemKind: String?
    var observedAt: Date?
    var source: String?
}

private struct CatalogPayload: Decodable {
    var projectID: String
    var currentSessionID: String?
}

private struct TurnPayload: Decodable {
    var projectID: String?
    var turn: CoFleetTurn
}

private struct ItemPayload: Decodable {
    var projectID: String?
    var sessionID: String
    var item: CoFleetTurnItem
}

private struct InteractionPayload: Decodable {
    var projectID: String?
    var interaction: CoFleetInteraction
}

private struct InteractionLifecyclePayload: Decodable {
    var projectID: String?
    var sessionID: String?
    var interactionID: String
}
