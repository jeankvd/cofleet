import Foundation
import Observation

@MainActor
@Observable
public final class TurnStore {
    public private(set) var items: [CoFleetTurnItem] = []
    public private(set) var interactions: [CoFleetInteraction] = []
    public private(set) var activeTurn: CoFleetTurn?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var attachments: [CoFleetTurnAttachment] = []
    public var draft = ""

    @ObservationIgnored private let repository: any CoFleetTurnRepository
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var hostID: CoFleetHostID?
    @ObservationIgnored private var projectID: String?
    @ObservationIgnored private var sessionID: String?
    public private(set) var lastProcessedEventID: String?

    public init(repository: any CoFleetTurnRepository) {
        self.repository = repository
    }

    deinit {
        eventTask?.cancel()
    }

    public func open(hostID: CoFleetHostID, projectID: String, sessionID: String) async {
        eventTask?.cancel()
        self.hostID = hostID
        self.projectID = projectID
        self.sessionID = sessionID
        attachments = []
        lastProcessedEventID = nil
        isLoading = true
        do {
            async let transcript = repository.fetchTranscript(hostID: hostID, sessionID: sessionID)
            async let pending = repository.fetchInteractions(hostID: hostID, sessionID: sessionID)
            items = try await transcript
            interactions = try await pending
            errorMessage = nil
            startEvents(hostID: hostID, sessionID: sessionID)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    @discardableResult
    public func send(settings: CoFleetSessionSettings) async throws -> CoFleetTurn {
        guard let hostID, let projectID, let sessionID else {
            throw CoFleetClientError.unavailable("Select a session before sending a message.")
        }
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentAttachments = attachments
        guard !prompt.isEmpty || !sentAttachments.isEmpty else {
            throw CoFleetClientError.conflict("Enter a message or attach an image first.")
        }
        let optimistic = prompt.isEmpty ? nil : CoFleetTurnItem(
            id: "local-\(UUID().uuidString)",
            turnID: "pending",
            kind: .userMessage,
            text: prompt
        )
        if let optimistic { items.append(optimistic) }
        draft = ""
        attachments = []
        var input: [CoFleetTurnInput] = []
        if !prompt.isEmpty { input.append(.text(prompt)) }
        input.append(contentsOf: sentAttachments.map(\.source.input))
        do {
            let turn = try await repository.startTurn(
                hostID: hostID,
                projectID: projectID,
                sessionID: sessionID,
                input: input,
                settings: settings,
                idempotencyKey: UUID()
            )
            activeTurn = turn
            return turn
        } catch {
            if let optimistic { items.removeAll { $0.id == optimistic.id } }
            if draft.isEmpty { draft = prompt }
            let queuedSources = Set(attachments.map(\.source))
            let availableSlots = max(0, CoFleetTurnAttachment.maximumCount - attachments.count)
            attachments.append(contentsOf: sentAttachments
                .filter { !queuedSources.contains($0.source) }
                .prefix(availableSlots))
            throw error
        }
    }

    public var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty
    }

    public func addAttachment(_ attachment: CoFleetTurnAttachment) throws {
        guard attachments.count < CoFleetTurnAttachment.maximumCount else {
            throw CoFleetTurnAttachmentError.tooManyAttachments(
                maximumCount: CoFleetTurnAttachment.maximumCount
            )
        }
        try attachment.validateForQueue()
        guard !attachments.contains(where: { $0.source == attachment.source }) else {
            throw CoFleetTurnAttachmentError.duplicateAttachment
        }
        attachments.append(attachment)
    }

    public func removeAttachment(id: CoFleetTurnAttachment.ID) {
        attachments.removeAll { $0.id == id }
    }

    public func interrupt() async throws {
        guard let hostID, let sessionID, let activeTurn else { return }
        try await repository.interruptTurn(hostID: hostID, sessionID: sessionID, turnID: activeTurn.id)
    }

    public func resolve(
        interactionID: String,
        decision: CoFleetInteractionDecision,
        answers: [String: [String]]? = nil
    ) async throws {
        guard let hostID else { return }
        try await repository.resolveInteraction(
            hostID: hostID,
            interactionID: interactionID,
            decision: decision,
            answers: answers
        )
        interactions.removeAll { $0.id == interactionID }
    }

    private func startEvents(hostID: CoFleetHostID, sessionID: String) {
        eventTask = Task { [weak self, repository] in
            var delayNanoseconds: UInt64 = 500_000_000
            while !Task.isCancelled {
                do {
                    let afterEventID = self?.lastProcessedEventID
                    let stream = try await repository.events(
                        hostID: hostID,
                        sessionID: sessionID,
                        afterEventID: afterEventID
                    )
                    for try await sequenced in stream {
                        guard !Task.isCancelled else { return }
                        self?.consume(sequenced)
                        delayNanoseconds = 500_000_000
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self?.errorMessage = error.localizedDescription
                }
                let jitter = Double.random(in: 0.8...1.2)
                let sleep = UInt64(Double(delayNanoseconds) * jitter)
                try? await Task.sleep(nanoseconds: sleep)
                delayNanoseconds = min(delayNanoseconds * 2, 30_000_000_000)
            }
        }
    }

    func consume(_ sequenced: CoFleetSequencedTurnEvent) {
        if let eventID = sequenced.id { lastProcessedEventID = eventID }
        apply(sequenced.event)
    }

    func apply(_ event: CoFleetTurnEvent) {
        switch event {
        case let .turn(turn):
            activeTurn = turn.state == .completed || turn.state == .failed || turn.state == .interrupted
                ? nil
                : turn
        case let .upsertItem(item):
            if item.kind == .userMessage {
                // Replace the local bubble with the canonical Codex item once
                // its lifecycle event arrives. Snapshot upserts also make SSE
                // replay idempotent after reconnects.
                if let optimistic = items.firstIndex(where: {
                    $0.id.hasPrefix("local-") && $0.kind == .userMessage && $0.text == item.text
                }) {
                    items.remove(at: optimistic)
                }
            }
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            } else {
                items.append(item)
            }
        case let .interaction(interaction):
            if let index = interactions.firstIndex(where: { $0.id == interaction.id }) {
                interactions[index] = interaction
            } else {
                interactions.append(interaction)
            }
        case let .interactionResolved(id):
            interactions.removeAll { $0.id == id }
        case let .interactionExpired(id):
            interactions.removeAll { $0.id == id }
        case .resetRequired:
            Task { [weak self] in
                guard let self, let hostID = self.hostID, let sessionID = self.sessionID else { return }
                async let transcript = self.repository.fetchTranscript(hostID: hostID, sessionID: sessionID)
                async let pending = self.repository.fetchInteractions(hostID: hostID, sessionID: sessionID)
                self.items = try await transcript
                self.interactions = try await pending
            }
        case .checkpoint:
            break
        }
    }
}
