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
    public var draft = "" {
        didSet { persistCurrentComposer() }
    }

    @ObservationIgnored private let repository: any CoFleetTurnRepository
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var hostID: CoFleetHostID?
    @ObservationIgnored private var projectID: String?
    @ObservationIgnored private var sessionID: String?
    @ObservationIgnored private var openGeneration = UUID()
    @ObservationIgnored private var resetGeneration = UUID()
    @ObservationIgnored private var sendGenerationsByRoute: [TurnRoute: UUID] = [:]
    @ObservationIgnored private var composersByRoute: [TurnRoute: ComposerState] = [:]
    @ObservationIgnored private var composerAccessOrder: [TurnRoute: UInt64] = [:]
    @ObservationIgnored private var composerAccessCounter: UInt64 = 0
    @ObservationIgnored private var isRestoringComposer = false
    @ObservationIgnored private var itemRevision: UInt64 = 0
    @ObservationIgnored private var interactionRevision: UInt64 = 0
    @ObservationIgnored private var eventStreamErrorMessage: String?
    public private(set) var lastProcessedEventID: String?

    public init(repository: any CoFleetTurnRepository) {
        self.repository = repository
    }

    deinit {
        eventTask?.cancel()
    }

    public func open(hostID: CoFleetHostID, projectID: String, sessionID: String) async {
        persistCurrentComposer()
        let route = TurnRoute(hostID: hostID, projectID: projectID, sessionID: sessionID)
        let generation = UUID()
        openGeneration = generation
        resetGeneration = UUID()
        eventTask?.cancel()
        self.hostID = hostID
        self.projectID = projectID
        self.sessionID = sessionID
        items = []
        itemRevision = 0
        interactions = []
        interactionRevision = 0
        activeTurn = nil
        restoreComposer(for: route)
        lastProcessedEventID = nil
        eventStreamErrorMessage = nil
        isLoading = true

        let repository = repository
        async let transcriptResult = Self.capture {
            try await repository.fetchTranscript(hostID: hostID, sessionID: sessionID)
        }
        async let interactionResult = Self.capture {
            try await repository.fetchInteractions(hostID: hostID, sessionID: sessionID)
        }

        var errors: [String] = []
        switch await transcriptResult {
        case let .success(loadedItems):
            guard isCurrent(route: route, generation: generation) else { return }
            items = loadedItems
            itemRevision &+= 1
        case let .failure(message):
            guard isCurrent(route: route, generation: generation) else { return }
            errors.append("Couldn’t load this conversation: \(message)")
        }

        guard isCurrent(route: route, generation: generation) else { return }
        startEvents(hostID: hostID, sessionID: sessionID, generation: generation)

        let interactionRevisionAtRequest = interactionRevision
        switch await interactionResult {
        case let .success(loadedInteractions):
            guard isCurrent(route: route, generation: generation) else { return }
            if interactionRevision == interactionRevisionAtRequest {
                interactions = loadedInteractions
            }
        case let .failure(message):
            guard isCurrent(route: route, generation: generation) else { return }
            errors.append("Pending interactions couldn’t be refreshed: \(message)")
        }

        guard isCurrent(route: route, generation: generation) else { return }
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
        isLoading = false
    }

    public func close() {
        persistCurrentComposer()
        openGeneration = UUID()
        resetGeneration = UUID()
        eventTask?.cancel()
        eventTask = nil
        hostID = nil
        projectID = nil
        sessionID = nil
        items = []
        itemRevision = 0
        interactions = []
        interactionRevision = 0
        activeTurn = nil
        clearVisibleComposer()
        lastProcessedEventID = nil
        eventStreamErrorMessage = nil
        isLoading = false
        errorMessage = nil
    }

    public var loadedHostID: CoFleetHostID? { hostID }
    public var loadedProjectID: String? { projectID }
    public var loadedSessionID: String? { sessionID }

    @discardableResult
    public func send(settings: CoFleetSessionSettings) async throws -> CoFleetTurn {
        guard let route = loadedRoute else {
            throw CoFleetClientError.unavailable("Select a session before sending a message.")
        }
        let generation = openGeneration
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentAttachments = attachments
        guard !prompt.isEmpty || !sentAttachments.isEmpty else {
            throw CoFleetClientError.conflict("Enter a message or attach an image first.")
        }
        let sendGeneration = UUID()
        sendGenerationsByRoute[route] = sendGeneration
        let optimistic = prompt.isEmpty ? nil : CoFleetTurnItem(
            id: "local-\(UUID().uuidString)",
            turnID: "pending",
            kind: .userMessage,
            text: prompt
        )
        if let optimistic {
            items.append(optimistic)
            itemRevision &+= 1
        }
        draft = ""
        attachments = []
        persistCurrentComposer()
        var input: [CoFleetTurnInput] = []
        if !prompt.isEmpty { input.append(.text(prompt)) }
        input.append(contentsOf: sentAttachments.map(\.source.input))
        do {
            let turn = try await repository.startTurn(
                hostID: route.hostID,
                projectID: route.projectID,
                sessionID: route.sessionID,
                input: input,
                settings: settings,
                idempotencyKey: UUID()
            )
            if sendGenerationsByRoute[route] == sendGeneration {
                if isCurrent(route: route, generation: generation) {
                    activeTurn = turn
                }
                sendGenerationsByRoute[route] = nil
            }
            return turn
        } catch {
            if sendGenerationsByRoute[route] == sendGeneration {
                if isCurrent(route: route, generation: generation) {
                    if let optimistic {
                        items.removeAll { $0.id == optimistic.id }
                        itemRevision &+= 1
                    }
                    if draft.isEmpty { draft = prompt }
                    restoreAttachments(sentAttachments)
                    persistCurrentComposer()
                } else {
                    restoreCachedComposer(
                        prompt: prompt,
                        attachments: sentAttachments,
                        for: route
                    )
                }
                sendGenerationsByRoute[route] = nil
            }
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
        persistCurrentComposer()
    }

    public func removeAttachment(id: CoFleetTurnAttachment.ID) {
        attachments.removeAll { $0.id == id }
        persistCurrentComposer()
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
        guard let route = loadedRoute else { return }
        let generation = openGeneration
        try await repository.resolveInteraction(
            hostID: route.hostID,
            interactionID: interactionID,
            decision: decision,
            answers: answers
        )
        guard isCurrent(route: route, generation: generation) else { return }
        interactions.removeAll { $0.id == interactionID }
        interactionRevision &+= 1
    }

    private func startEvents(hostID: CoFleetHostID, sessionID: String, generation: UUID) {
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
                    if let eventStreamErrorMessage = self?.eventStreamErrorMessage,
                       self?.errorMessage == eventStreamErrorMessage {
                        self?.errorMessage = nil
                    }
                    self?.eventStreamErrorMessage = nil
                    for try await sequenced in stream {
                        guard !Task.isCancelled, self?.openGeneration == generation else { return }
                        self?.consume(sequenced)
                        delayNanoseconds = 500_000_000
                    }
                } catch is CancellationError {
                    return
                } catch {
                    if self?.openGeneration == generation,
                       !Self.isExpectedEventStreamDisconnect(error) {
                        let message = error.localizedDescription
                        self?.eventStreamErrorMessage = message
                        self?.errorMessage = message
                    }
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
                // Replace the local bubble with the canonical item once its lifecycle event
                // arrives. Snapshot upserts also make replay idempotent after reconnects.
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
            itemRevision &+= 1
        case let .interaction(interaction):
            if let index = interactions.firstIndex(where: { $0.id == interaction.id }) {
                interactions[index] = interaction
            } else {
                interactions.append(interaction)
            }
            interactionRevision &+= 1
        case let .interactionResolved(id):
            interactions.removeAll { $0.id == id }
            interactionRevision &+= 1
        case let .interactionExpired(id):
            interactions.removeAll { $0.id == id }
            interactionRevision &+= 1
        case .resetRequired:
            refreshAfterReset()
        case .checkpoint:
            break
        }
    }

    private var loadedRoute: TurnRoute? {
        guard let hostID, let projectID, let sessionID else { return nil }
        return TurnRoute(hostID: hostID, projectID: projectID, sessionID: sessionID)
    }

    private func isCurrent(route: TurnRoute, generation: UUID) -> Bool {
        loadedRoute == route && openGeneration == generation
    }

    private func refreshAfterReset() {
        guard let route = loadedRoute else { return }
        let generation = openGeneration
        let reset = UUID()
        resetGeneration = reset
        let itemRevisionAtRequest = itemRevision
        let interactionRevisionAtRequest = interactionRevision

        Task { [weak self, repository] in
            async let transcriptResult = Self.capture {
                try await repository.fetchTranscript(hostID: route.hostID, sessionID: route.sessionID)
            }
            async let interactionResult = Self.capture {
                try await repository.fetchInteractions(hostID: route.hostID, sessionID: route.sessionID)
            }

            let transcript = await transcriptResult
            guard let self,
                  self.isCurrent(route: route, generation: generation),
                  self.resetGeneration == reset else { return }
            switch transcript {
            case let .success(items):
                if self.itemRevision == itemRevisionAtRequest {
                    self.items = items
                    self.itemRevision &+= 1
                    self.errorMessage = nil
                }
            case let .failure(message):
                self.errorMessage = "Couldn’t refresh this conversation: \(message)"
            }

            let pending = await interactionResult
            guard self.isCurrent(route: route, generation: generation),
                  self.resetGeneration == reset else { return }
            switch pending {
            case let .success(interactions):
                if self.interactionRevision == interactionRevisionAtRequest {
                    self.interactions = interactions
                    self.interactionRevision &+= 1
                }
            case let .failure(message):
                self.errorMessage = "Pending interactions couldn’t be refreshed: \(message)"
            }
        }
    }

    private func persistCurrentComposer() {
        guard !isRestoringComposer, let route = loadedRoute else { return }
        if draft.isEmpty && attachments.isEmpty {
            composersByRoute[route] = nil
            composerAccessOrder[route] = nil
            return
        }
        composersByRoute[route] = ComposerState(draft: draft, attachments: attachments)
        composerAccessCounter &+= 1
        composerAccessOrder[route] = composerAccessCounter
        trimComposerCache(keeping: route)
    }

    private func restoreComposer(for route: TurnRoute) {
        let composer = composersByRoute[route] ?? ComposerState()
        isRestoringComposer = true
        draft = composer.draft
        attachments = composer.attachments
        isRestoringComposer = false
        if !composer.draft.isEmpty || !composer.attachments.isEmpty {
            composerAccessCounter &+= 1
            composerAccessOrder[route] = composerAccessCounter
        }
    }

    private func clearVisibleComposer() {
        isRestoringComposer = true
        draft = ""
        attachments = []
        isRestoringComposer = false
    }

    private func restoreAttachments(_ sentAttachments: [CoFleetTurnAttachment]) {
        let queuedSources = Set(attachments.map(\.source))
        let availableSlots = max(0, CoFleetTurnAttachment.maximumCount - attachments.count)
        attachments.append(contentsOf: sentAttachments
            .filter { !queuedSources.contains($0.source) }
            .prefix(availableSlots))
    }

    private func restoreCachedComposer(
        prompt: String,
        attachments sentAttachments: [CoFleetTurnAttachment],
        for route: TurnRoute
    ) {
        var composer = composersByRoute[route] ?? ComposerState()
        if composer.draft.isEmpty { composer.draft = prompt }
        let queuedSources = Set(composer.attachments.map(\.source))
        let availableSlots = max(0, CoFleetTurnAttachment.maximumCount - composer.attachments.count)
        composer.attachments.append(contentsOf: sentAttachments
            .filter { !queuedSources.contains($0.source) }
            .prefix(availableSlots))
        guard !composer.draft.isEmpty || !composer.attachments.isEmpty else { return }
        composersByRoute[route] = composer
        composerAccessCounter &+= 1
        composerAccessOrder[route] = composerAccessCounter
        trimComposerCache(keeping: route)
    }

    private func trimComposerCache(keeping currentRoute: TurnRoute) {
        while composersByRoute.count > 64 {
            guard let oldest = composerAccessOrder
                .filter({ $0.key != currentRoute })
                .min(by: { $0.value < $1.value })?.key else { return }
            composersByRoute[oldest] = nil
            composerAccessOrder[oldest] = nil
        }
    }

    private nonisolated static func capture<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async -> StoreLoadResult<Value> {
        do {
            return .success(try await operation())
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// A long-lived SSE request can end at an HTTP or transport timeout even
    /// when no chat operation failed. The reconnect loop owns these expected
    /// disconnects; surfacing them in the composer makes an untouched task look
    /// broken before the user has sent anything.
    nonisolated private static func isExpectedEventStreamDisconnect(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("request timed out")
            || message.contains("timed out")
            || message.contains("timeout")
            || message.contains("network connection was lost")
            || message.contains("connection reset")
    }
}

private struct TurnRoute: Hashable, Sendable {
    var hostID: CoFleetHostID
    var projectID: String
    var sessionID: String
}

private struct ComposerState: Sendable {
    var draft = ""
    var attachments: [CoFleetTurnAttachment] = []
}

private enum StoreLoadResult<Value: Sendable>: Sendable {
    case success(Value)
    case failure(String)
}
