import Foundation
import Observation

public struct CoFleetProjectConversationPreview: Codable, Hashable, Sendable {
    public var session: CoFleetSessionSummary
    public var messages: [CoFleetTurnItem]

    public init(session: CoFleetSessionSummary, messages: [CoFleetTurnItem]) {
        self.session = session
        self.messages = Self.recentConversationMessages(from: messages)
    }

    public static func recentConversationMessages(from items: [CoFleetTurnItem]) -> [CoFleetTurnItem] {
        let conversational = items.filter {
            ($0.kind == .userMessage || $0.kind == .assistantMessage)
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let userIndex = conversational.lastIndex(where: { $0.kind == .userMessage }) else {
            return []
        }
        let user = conversational[userIndex]
        let replies = conversational[conversational.index(after: userIndex)...]
        guard let reply = replies.last(where: { $0.kind == .assistantMessage }) else {
            return [user]
        }
        return [user, reply]
    }
}

@MainActor
@Observable
public final class ThreadStore {
    public private(set) var sessions: [CoFleetSessionSummary] = []
    public private(set) var sessionsByProjectID: [String: [CoFleetSessionSummary]] = [:]
    public private(set) var latestPreviewByProjectID: [String: CoFleetProjectConversationPreview] = [:]
    public private(set) var previewLoadingProjectIDs: Set<String> = []
    public private(set) var previewErrorsByProjectID: [String: String] = [:]
    public private(set) var nextCursor: String?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var showsArchived = false
    public var selectedSessionID: String? {
        didSet {
            guard let route = loadedRoute else { return }
            selectedSessionIDsByRoute[.init(route: route, archived: showsArchived)] = selectedSessionID
        }
    }

    @ObservationIgnored private let repository: any CoFleetThreadRepository
    @ObservationIgnored private let previewRepository: (any CoFleetTurnRepository)?
    @ObservationIgnored private let snapshotStorage: any CoFleetThreadSnapshotStorage
    @ObservationIgnored private var hostID: CoFleetHostID?
    @ObservationIgnored private var projectID: String?
    @ObservationIgnored private var activeSessionsByRoute: [ProjectRoute: [CoFleetSessionSummary]] = [:]
    @ObservationIgnored private var selectedSessionIDsByRoute: [SessionListRoute: String] = [:]
    @ObservationIgnored private var loadGeneration = UUID()
    @ObservationIgnored private var previewGenerationsByRoute: [ProjectRoute: UUID] = [:]
    @ObservationIgnored private var activeFirstPageLoads: [ProjectRoute: SessionPageLoad] = [:]
    @ObservationIgnored private var completedFirstPages: [ProjectRoute: CachedSessionPage] = [:]

    public init(
        repository: any CoFleetThreadRepository,
        previewRepository: (any CoFleetTurnRepository)? = nil,
        snapshotStorage: any CoFleetThreadSnapshotStorage = CoFleetInMemoryThreadSnapshotStorage()
    ) {
        self.repository = repository
        self.previewRepository = previewRepository ?? (repository as? any CoFleetTurnRepository)
        self.snapshotStorage = snapshotStorage
    }

    public var selectedSession: CoFleetSessionSummary? {
        if let selectedSessionID {
            return sessions.first(where: { $0.id == selectedSessionID })
        }
        return sessions.first
    }

    public var loadedProjectID: String? { projectID }
    public var loadedHostID: CoFleetHostID? { hostID }

    public var canLoadMore: Bool { nextCursor != nil }

    public func loadInitial(hostID: CoFleetHostID, projectID: String) async {
        let route = ProjectRoute(hostID: hostID, projectID: projectID)
        let suppliedSessionID = loadedRoute == route ? selectedSessionID : nil
        let generation = UUID()
        loadGeneration = generation
        self.hostID = hostID
        self.projectID = projectID
        showsArchived = false
        restoreSnapshotIfNeeded(for: route)
        sessions = activeSessionsByRoute[route] ?? sessionsByProjectID[projectID] ?? []
        nextCursor = nil
        let rememberedSessionID = selectedSessionIDsByRoute[.init(route: route, archived: false)]
            ?? suppliedSessionID
        selectedSessionID = rememberedSessionID ?? sessions.first?.id
        errorMessage = nil
        await loadPage(
            route: route,
            cursor: nil,
            replacing: true,
            archived: false,
            generation: generation
        )
    }

    public func loadMore() async {
        guard !isLoading, let route = loadedRoute, let nextCursor else { return }
        await loadPage(
            route: route,
            cursor: nextCursor,
            replacing: false,
            archived: showsArchived,
            generation: loadGeneration
        )
    }

    public func setShowsArchived(_ archived: Bool) async {
        guard showsArchived != archived, let route = loadedRoute else { return }
        showsArchived = archived
        sessions = archived ? [] : (activeSessionsByRoute[route] ?? sessionsByProjectID[route.projectID] ?? [])
        nextCursor = nil
        let rememberedSessionID = selectedSessionIDsByRoute[.init(route: route, archived: archived)]
        selectedSessionID = rememberedSessionID ?? sessions.first?.id
        errorMessage = nil
        let generation = UUID()
        loadGeneration = generation
        await loadPage(
            route: route,
            cursor: nil,
            replacing: true,
            archived: archived,
            generation: generation
        )
    }

    @discardableResult
    public func createSession(
        settings: CoFleetSessionSettings = CoFleetSessionSettings()
    ) async throws -> CoFleetSessionSummary {
        guard let route = loadedRoute else {
            throw CoFleetClientError.unavailable("Select a project before creating a session.")
        }
        let generation = loadGeneration
        let session = try await repository.createSession(
            hostID: route.hostID,
            projectID: route.projectID,
            settings: settings
        )
        guard isCurrent(route: route, generation: generation) else { return session }
        invalidateCompletedFirstPage(for: route)
        if showsArchived {
            showsArchived = false
            sessions = activeSessionsByRoute[route] ?? sessionsByProjectID[route.projectID] ?? []
            nextCursor = nil
        }
        sessions.insert(session, at: 0)
        cacheActiveSessions(sessions, for: route)
        selectedSessionID = session.id
        return session
    }

    public func archiveSelected() async throws {
        guard let route = loadedRoute, let selectedSessionID else { return }
        let generation = loadGeneration
        try await repository.archiveSession(hostID: route.hostID, sessionID: selectedSessionID)
        guard isCurrent(route: route, generation: generation), !showsArchived else { return }
        invalidateCompletedFirstPage(for: route)
        sessions.removeAll { $0.id == selectedSessionID }
        cacheActiveSessions(sessions, for: route)
        self.selectedSessionID = sessions.first?.id
    }

    public func unarchiveSelected() async throws {
        guard let route = loadedRoute,
              let selectedSessionID,
              let selected = sessions.first(where: { $0.id == selectedSessionID }) else { return }
        let generation = loadGeneration
        try await repository.unarchiveSession(hostID: route.hostID, sessionID: selectedSessionID)
        guard isCurrent(route: route, generation: generation), showsArchived else { return }
        invalidateCompletedFirstPage(for: route)
        sessions.removeAll { $0.id == selectedSessionID }
        var active = activeSessionsByRoute[route] ?? sessionsByProjectID[route.projectID] ?? []
        if !active.contains(where: { $0.id == selected.id }) {
            active.insert(selected, at: 0)
        }
        cacheActiveSessions(active, for: route)
        self.selectedSessionID = sessions.first?.id
    }

    @discardableResult
    public func resumeSelected(settings: CoFleetSessionSettings) async throws -> CoFleetSessionSummary? {
        guard let route = loadedRoute, let selectedSessionID else { return nil }
        let generation = loadGeneration
        let resumed = try await repository.resumeSession(
            hostID: route.hostID,
            projectID: route.projectID,
            sessionID: selectedSessionID,
            settings: settings
        )
        guard isCurrent(route: route, generation: generation), !showsArchived else { return resumed }
        invalidateCompletedFirstPage(for: route)
        replaceOrInsert(resumed, route: route)
        return resumed
    }

    @discardableResult
    public func forkSelected(settings: CoFleetSessionSettings) async throws -> CoFleetSessionSummary? {
        guard let route = loadedRoute, let selectedSessionID else { return nil }
        let generation = loadGeneration
        let forked = try await repository.forkSession(
            hostID: route.hostID,
            projectID: route.projectID,
            sessionID: selectedSessionID,
            settings: settings
        )
        guard isCurrent(route: route, generation: generation), !showsArchived else { return forked }
        invalidateCompletedFirstPage(for: route)
        sessions.insert(forked, at: 0)
        cacheActiveSessions(sessions, for: route)
        self.selectedSessionID = forked.id
        return forked
    }

    public func renameSelected(_ title: String) async throws {
        guard let route = loadedRoute, let selectedSessionID else { return }
        let generation = loadGeneration
        try await repository.renameSession(hostID: route.hostID, sessionID: selectedSessionID, title: title)
        guard isCurrent(route: route, generation: generation) else { return }
        invalidateCompletedFirstPage(for: route)
        guard let index = sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return }
        sessions[index].title = title
        if !showsArchived { cacheActiveSessions(sessions, for: route) }
    }

    public func openSelectedInCodex() async throws {
        guard let hostID, let selectedSessionID else {
            throw CoFleetClientError.unavailable("Choose a Codex task first.")
        }
        try await openInCodex(hostID: hostID, sessionID: selectedSessionID)
    }

    /// Opens a host-scoped Codex task without changing or refreshing the active
    /// session catalog. Progress already owns canonical host/session metadata;
    /// navigation must not pay for `thread/list` before handing that ID back to
    /// the same host.
    public func openInCodex(hostID: CoFleetHostID, sessionID: String) async throws {
        // This endpoint no longer calls Codex RPCs. One bounded authenticated
        // request is both sufficient and safer than retrying a desktop-launch
        // side effect for tens of seconds when the Tailnet route is unavailable.
        try await repository.openSessionInCodex(hostID: hostID, sessionID: sessionID)
    }

    public func latestSession(for projectID: String) -> CoFleetSessionSummary? {
        latestPreviewByProjectID[projectID]?.session
            ?? sessionsByProjectID[projectID]?
                .filter { !($0.preview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) }
                .max(by: { $0.updatedAt < $1.updatedAt })
            ?? sessionsByProjectID[projectID]?.max(by: { $0.updatedAt < $1.updatedAt })
    }

    public func latestPreview(for projectID: String) -> CoFleetProjectConversationPreview? {
        latestPreviewByProjectID[projectID]
    }

    public func projectID(hostID: CoFleetHostID, sessionID: String) -> String? {
        sessionsByProjectID.first { _, sessions in
            sessions.contains { $0.hostID == hostID && $0.id == sessionID }
        }?.key
    }

    /// Applies a host-wide turn lifecycle event to the project/session cache.
    /// This never changes the user's selected historical task.
    public func applyLiveTurn(
        hostID: CoFleetHostID,
        projectID: String,
        turn: CoFleetTurn
    ) {
        guard turn.hostID == hostID else { return }
        let route = ProjectRoute(hostID: hostID, projectID: projectID)
        var projectSessions = activeSessionsByRoute[route] ?? sessionsByProjectID[projectID] ?? []
        let previewSession = latestPreviewByProjectID[projectID].flatMap { preview in
            preview.session.id == turn.sessionID ? preview.session : nil
        }
        var summary = projectSessions.first(where: { $0.id == turn.sessionID })
            ?? previewSession
            ?? CoFleetSessionSummary(
                id: turn.sessionID,
                hostID: hostID,
                projectID: projectID,
                title: "Codex task",
                state: .active,
                updatedAt: turn.completedAt ?? turn.startedAt,
                createdAt: turn.startedAt
            )
        guard summary.hostID == hostID else { return }
        summary.state = switch turn.state {
        case .queued, .running: .active
        case .waitingForInteraction: .waitingForInteraction
        case .completed: .completed
        case .interrupted: .interrupted
        case .failed: .failed
        }
        summary.updatedAt = max(summary.updatedAt, turn.completedAt ?? turn.startedAt)
        upsertLiveSession(summary, in: &projectSessions)
        cacheActiveSessions(projectSessions, for: route, persist: turn.completedAt != nil)
        updateLoadedSessionsIfNeeded(route: route, projectSessions: projectSessions)
    }

    /// Projects streamed user/assistant items into the Progress preview without
    /// waiting for another transcript request. Streaming deltas stay in memory;
    /// completed messages are persisted for instant relaunch rendering.
    public func applyLiveItem(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String,
        item: CoFleetTurnItem,
        isCurrentSession: Bool
    ) {
        guard isCurrentSession else { return }
        let route = ProjectRoute(hostID: hostID, projectID: projectID)
        var projectSessions = activeSessionsByRoute[route] ?? sessionsByProjectID[projectID] ?? []
        let previewSession = latestPreviewByProjectID[projectID].flatMap { preview in
            preview.session.id == sessionID ? preview.session : nil
        }
        var session = projectSessions.first(where: { $0.id == sessionID })
            ?? previewSession
            ?? CoFleetSessionSummary(
                id: sessionID,
                hostID: hostID,
                projectID: projectID,
                title: "Codex task",
                state: .active,
                updatedAt: item.createdAt,
                createdAt: item.createdAt
            )
        guard session.id == sessionID, session.hostID == hostID else { return }
        session.updatedAt = max(session.updatedAt, item.createdAt)
        if item.kind == .userMessage,
           !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            session.preview = item.text
        }
        upsertLiveSession(session, in: &projectSessions)
        cacheActiveSessions(projectSessions, for: route, persist: false)
        updateLoadedSessionsIfNeeded(route: route, projectSessions: projectSessions)

        guard item.kind == .userMessage || item.kind == .assistantMessage else { return }
        var messages: [CoFleetTurnItem]
        if let current = latestPreviewByProjectID[projectID], current.session.id == sessionID {
            messages = current.messages
        } else if item.kind == .assistantMessage,
                  let prompt = session.preview?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !prompt.isEmpty {
            messages = [CoFleetTurnItem(
                id: "preview-user-\(sessionID)",
                turnID: item.turnID,
                kind: .userMessage,
                text: prompt,
                createdAt: session.updatedAt
            )]
        } else {
            messages = []
        }
        if let index = messages.firstIndex(where: { $0.id == item.id }) {
            messages[index] = item
        } else {
            messages.append(item)
        }
        let preview = CoFleetProjectConversationPreview(session: session, messages: messages)
        if !preview.messages.isEmpty {
            latestPreviewByProjectID[projectID] = preview
            if item.state == .completed { persistSnapshot(for: route) }
        }
    }

    /// Invalidates and reconciles exactly one project's first page and preview.
    /// Returns true when reconciliation discovered a new completed assistant
    /// message, allowing a Desktop wake to transition directly to "replied".
    @discardableResult
    public func reconcileLatestSessionPreview(
        for project: CoFleetProject,
        previousCurrentSessionID: String?,
        currentSessionID: String?
    ) async -> Bool {
        let route = ProjectRoute(hostID: project.hostID, projectID: project.id)
        let beforeReply = assistantReplySignature(latestPreviewByProjectID[project.id])
        let preservedSelection = loadedRoute == route ? selectedSessionID : nil
        let preservesHistoricalSelection = preservedSelection != nil
            && previousCurrentSessionID != nil
            && preservedSelection != previousCurrentSessionID
        let previouslyLoaded = loadedRoute == route ? sessions : []

        await refreshLatestSessionPreviews(for: [project], force: true)

        if loadedRoute == route, !showsArchived {
            var reconciled = sessionsByProjectID[project.id] ?? []
            let known = Set(reconciled.map(\.id))
            reconciled.append(contentsOf: previouslyLoaded.filter { !known.contains($0.id) })
            sessions = reconciled
            // An explicit history choice wins over a newly discovered current
            // task, even when that task moved to the head of the first page.
            if preservesHistoricalSelection, let preservedSelection {
                selectedSessionID = preservedSelection
            } else if let currentSessionID,
                      reconciled.contains(where: { $0.id == currentSessionID }) {
                selectedSessionID = currentSessionID
            } else {
                selectedSessionID = preservedSelection
            }
        }

        let after = latestPreviewByProjectID[project.id]
        guard currentSessionID == nil || after?.session.id == currentSessionID else { return false }
        let afterReply = assistantReplySignature(after)
        return afterReply != nil && afterReply != beforeReply
    }

    public func updateLoadedProjectPreview(items: [CoFleetTurnItem]) {
        guard let route = loadedRoute, let session = selectedSession else { return }
        let preview = CoFleetProjectConversationPreview(session: session, messages: items)
        guard !preview.messages.isEmpty else { return }
        latestPreviewByProjectID[route.projectID] = preview
        persistSnapshot(for: route)
    }

    /// Refresh each Progress card independently so one unavailable host cannot erase every
    /// other card. Only the newest task transcript is loaded; history stays lazily paged.
    public func refreshLatestSessionPreviews(
        for projects: [CoFleetProject],
        force: Bool = false
    ) async {
        guard let previewRepository else { return }
        let uniqueProjects = Dictionary(
            projects.map { (ProjectRoute(hostID: $0.hostID, projectID: $0.id), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        if force {
            for route in uniqueProjects.keys {
                invalidateCompletedFirstPage(for: route)
            }
        }
        // Publish durable stale data before the first suspension. The network work
        // below only reconciles it with Codex; it never blocks initial rendering.
        for route in uniqueProjects.keys {
            restoreSnapshotIfNeeded(for: route)
        }
        let generations = uniqueProjects.reduce(into: [ProjectRoute: UUID]()) { result, entry in
            let generation = UUID()
            previewGenerationsByRoute[entry.key] = generation
            result[entry.key] = generation
        }
        previewLoadingProjectIDs.formUnion(uniqueProjects.values.map(\.id))
        defer {
            // SwiftUI can cancel and recreate the Progress task while a host read is in
            // flight. Always retire generations owned by this refresh so a cancelled
            // request cannot leave a card permanently saying “Loading latest…”.
            for (route, generation) in generations
            where previewGenerationsByRoute[route] == generation {
                previewGenerationsByRoute[route] = nil
            }
            for projectID in Set(uniqueProjects.values.map(\.id))
            where !previewGenerationsByRoute.keys.contains(where: { $0.projectID == projectID }) {
                previewLoadingProjectIDs.remove(projectID)
            }
        }

        await withTaskGroup(of: ProjectPreviewLoadResult.self) { group in
            for (route, project) in uniqueProjects {
                guard let generation = generations[route] else { continue }
                group.addTask {
                    do {
                        let page = try await self.fetchActiveFirstPage(route: route)
                        let ordered = page.items.sorted { $0.updatedAt > $1.updatedAt }
                        let candidate = ordered.first {
                            !($0.preview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
                        } ?? ordered.first
                        let cached: CoFleetProjectConversationPreview?
                        if let candidate {
                            cached = await self.reusablePreview(for: candidate)
                        } else {
                            cached = nil
                        }
                        await self.applyPreviewMetadata(
                            route: route,
                            generation: generation,
                            sessions: ordered
                        )
                        guard await self.isCurrentPreviewGeneration(
                            route: route,
                            generation: generation
                        ) else {
                            return .success(
                                route: route,
                                generation: generation,
                                sessions: ordered,
                                preview: nil
                            )
                        }
                        guard !ordered.isEmpty else {
                            return .success(
                                route: route,
                                generation: generation,
                                sessions: [],
                                preview: nil
                            )
                        }

                        // `thread/list` already tells us whether a task has a user preview.
                        // Pick the freshest such task before paying for `thread/read`, rather
                        // than serially reading as many as five complete transcripts. This keeps
                        // Progress to one list call plus at most one transcript call.
                        guard let candidate else {
                            return .success(
                                route: route,
                                generation: generation,
                                sessions: ordered,
                                preview: nil
                            )
                        }

                        // A list refresh is enough when Codex says the task has not changed.
                        // Reuse the actual transcript already on screen instead of rereading it
                        // every minute or duplicating Agent Bay's initial transcript request.
                        if let cached {
                            return .success(
                                route: route,
                                generation: generation,
                                sessions: ordered,
                                preview: cached
                            )
                        }

                        let transcript = try await previewRepository.fetchTranscript(
                            hostID: project.hostID,
                            sessionID: candidate.id
                        )
                        return .success(
                            route: route,
                            generation: generation,
                            sessions: ordered,
                            preview: CoFleetProjectConversationPreview(
                                session: candidate,
                                messages: transcript
                            )
                        )
                    } catch {
                        return .failure(
                            route: route,
                            generation: generation,
                            message: error.localizedDescription
                        )
                    }
                }
            }

            for await result in group {
                guard previewGenerationsByRoute[result.route] == result.generation else { continue }
                switch result {
                case let .success(route, _, projectSessions, preview):
                    cacheActiveSessions(projectSessions, for: route)
                    if let preview, !preview.messages.isEmpty {
                        latestPreviewByProjectID[route.projectID] = preview
                    } else {
                        latestPreviewByProjectID[route.projectID] = nil
                    }
                    persistSnapshot(for: route)
                    previewErrorsByProjectID[route.projectID] = nil
                case let .failure(route, _, message):
                    previewErrorsByProjectID[route.projectID] = message
                }
                previewGenerationsByRoute[result.route] = nil
                if !previewGenerationsByRoute.keys.contains(where: { $0.projectID == result.route.projectID }) {
                    previewLoadingProjectIDs.remove(result.route.projectID)
                }
            }
        }
    }

    private func loadPage(
        route: ProjectRoute,
        cursor: String?,
        replacing: Bool,
        archived: Bool,
        generation: UUID
    ) async {
        isLoading = true
        defer {
            if loadGeneration == generation { isLoading = false }
        }
        do {
            let page: CoFleetSessionPage
            if cursor == nil, !archived {
                page = try await fetchActiveFirstPage(route: route)
            } else {
                do {
                    page = try await repository.fetchSessions(
                        hostID: route.hostID,
                        projectID: route.projectID,
                        cursor: cursor,
                        limit: 5,
                        archived: archived
                    )
                } catch {
                    guard Self.isTransientCodexReadError(error) else { throw error }
                    try await Task.sleep(for: .milliseconds(500))
                    page = try await repository.fetchSessions(
                        hostID: route.hostID,
                        projectID: route.projectID,
                        cursor: cursor,
                        limit: 5,
                        archived: archived
                    )
                }
            }
            guard isCurrent(route: route, generation: generation), showsArchived == archived else { return }
            if replacing {
                sessions = page.items.sorted { $0.updatedAt > $1.updatedAt }
            } else {
                let known = Set(sessions.map(\.id))
                sessions.append(contentsOf: page.items.filter { !known.contains($0.id) })
            }
            if !archived { cacheActiveSessions(sessions, for: route) }
            nextCursor = page.nextCursor
            if selectedSessionID == nil {
                selectedSessionID = selectedSessionIDsByRoute[.init(route: route, archived: archived)]
                    ?? sessions.first?.id
            }
            errorMessage = nil
        } catch {
            guard loadGeneration == generation else { return }
            errorMessage = error.localizedDescription
        }
    }

    private var loadedRoute: ProjectRoute? {
        guard let hostID, let projectID else { return nil }
        return ProjectRoute(hostID: hostID, projectID: projectID)
    }

    private func isCurrent(route: ProjectRoute, generation: UUID) -> Bool {
        loadedRoute == route && loadGeneration == generation
    }

    private func cacheActiveSessions(
        _ sessions: [CoFleetSessionSummary],
        for route: ProjectRoute,
        persist: Bool = true
    ) {
        activeSessionsByRoute[route] = sessions
        sessionsByProjectID[route.projectID] = sessions
        if persist { persistSnapshot(for: route) }
    }

    private func upsertLiveSession(
        _ session: CoFleetSessionSummary,
        in sessions: inout [CoFleetSessionSummary]
    ) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.append(session)
        }
        sessions.sort { $0.updatedAt > $1.updatedAt }
    }

    private func updateLoadedSessionsIfNeeded(
        route: ProjectRoute,
        projectSessions: [CoFleetSessionSummary]
    ) {
        guard loadedRoute == route, !showsArchived else { return }
        let preservedSelection = selectedSessionID
        let known = Set(projectSessions.map(\.id))
        sessions = projectSessions + sessions.filter { !known.contains($0.id) }
        selectedSessionID = preservedSelection
    }

    private func assistantReplySignature(
        _ preview: CoFleetProjectConversationPreview?
    ) -> String? {
        guard let preview,
              let reply = preview.messages.last(where: {
                  $0.kind == .assistantMessage && $0.state == .completed
              }) else { return nil }
        return "\(preview.session.id):\(reply.id):\(reply.text)"
    }

    private func restoreSnapshotIfNeeded(for route: ProjectRoute) {
        let key = CoFleetThreadSnapshotKey(hostID: route.hostID, projectID: route.projectID)
        guard let snapshot = snapshotStorage.snapshot(for: key) else { return }
        if activeSessionsByRoute[route] == nil {
            activeSessionsByRoute[route] = snapshot.sessions
            sessionsByProjectID[route.projectID] = snapshot.sessions
        }
        if latestPreviewByProjectID[route.projectID] == nil,
           let preview = snapshot.preview {
            latestPreviewByProjectID[route.projectID] = preview
        }
    }

    private func persistSnapshot(for route: ProjectRoute) {
        let preview = latestPreviewByProjectID[route.projectID].flatMap { value in
            value.session.hostID == route.hostID && value.session.projectID == route.projectID
                ? value
                : nil
        }
        snapshotStorage.save(CoFleetThreadSnapshot(
            key: .init(hostID: route.hostID, projectID: route.projectID),
            sessions: activeSessionsByRoute[route] ?? [],
            preview: preview
        ))
    }

    private func fetchActiveFirstPage(route: ProjectRoute) async throws -> CoFleetSessionPage {
        if let cached = completedFirstPages[route],
           Date().timeIntervalSince(cached.storedAt) < 5 {
            return cached.page
        }
        if let existing = activeFirstPageLoads[route] {
            return try await existing.task.value
        }

        let repository = repository
        let loadID = UUID()
        let task = Task {
            do {
                return try await repository.fetchSessions(
                    hostID: route.hostID,
                    projectID: route.projectID,
                    cursor: nil,
                    limit: 5,
                    archived: false
                )
            } catch {
                guard Self.isTransientCodexReadError(error) else { throw error }
                try await Task.sleep(for: .milliseconds(500))
                return try await repository.fetchSessions(
                    hostID: route.hostID,
                    projectID: route.projectID,
                    cursor: nil,
                    limit: 5,
                    archived: false
                )
            }
        }
        activeFirstPageLoads[route] = SessionPageLoad(id: loadID, task: task)
        defer {
            if activeFirstPageLoads[route]?.id == loadID {
                activeFirstPageLoads[route] = nil
            }
        }
        let page = try await task.value
        completedFirstPages[route] = CachedSessionPage(page: page, storedAt: .now)
        if completedFirstPages.count > 64 {
            let oldestRoutes = completedFirstPages
                .sorted { $0.value.storedAt < $1.value.storedAt }
                .prefix(completedFirstPages.count - 64)
                .map(\.key)
            for route in oldestRoutes {
                completedFirstPages[route] = nil
            }
        }
        return page
    }

    private func invalidateCompletedFirstPage(for route: ProjectRoute) {
        completedFirstPages[route] = nil
    }

    private func applyPreviewMetadata(
        route: ProjectRoute,
        generation: UUID,
        sessions: [CoFleetSessionSummary]
    ) {
        guard previewGenerationsByRoute[route] == generation else { return }
        cacheActiveSessions(sessions, for: route)
        previewErrorsByProjectID[route.projectID] = nil

        guard let current = latestPreviewByProjectID[route.projectID] else { return }
        guard let matching = sessions.first(where: { $0.id == current.session.id }) else {
            latestPreviewByProjectID[route.projectID] = nil
            persistSnapshot(for: route)
            return
        }
        latestPreviewByProjectID[route.projectID] = CoFleetProjectConversationPreview(
            session: matching,
            messages: current.messages
        )
        persistSnapshot(for: route)
    }

    private func isCurrentPreviewGeneration(route: ProjectRoute, generation: UUID) -> Bool {
        previewGenerationsByRoute[route] == generation
    }

    private func reusablePreview(
        for session: CoFleetSessionSummary
    ) -> CoFleetProjectConversationPreview? {
        guard let cached = latestPreviewByProjectID[session.projectID],
              cached.session.id == session.id,
              cached.session.updatedAt >= session.updatedAt,
              !cached.messages.isEmpty else { return nil }
        return CoFleetProjectConversationPreview(session: session, messages: cached.messages)
    }

    private func replaceOrInsert(_ session: CoFleetSessionSummary, route: ProjectRoute) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
        cacheActiveSessions(sessions, for: route)
    }

    nonisolated private static func isTransientCodexReadError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("codex is busy")
            || message.contains("app-server did not answer in time")
            || message.contains("timed out")
            || message.contains("timeout")
            || message.contains("try again shortly")
    }
}

private struct ProjectRoute: Hashable, Sendable {
    var hostID: CoFleetHostID
    var projectID: String
}

private struct SessionListRoute: Hashable, Sendable {
    var route: ProjectRoute
    var archived: Bool
}

private struct SessionPageLoad {
    var id: UUID
    var task: Task<CoFleetSessionPage, Error>
}

private struct CachedSessionPage {
    var page: CoFleetSessionPage
    var storedAt: Date
}

private enum ProjectPreviewLoadResult: Sendable {
    case success(
        route: ProjectRoute,
        generation: UUID,
        sessions: [CoFleetSessionSummary],
        preview: CoFleetProjectConversationPreview?
    )
    case failure(route: ProjectRoute, generation: UUID, message: String)

    var route: ProjectRoute {
        switch self {
        case let .success(route, _, _, _), let .failure(route, _, _): route
        }
    }

    var generation: UUID {
        switch self {
        case let .success(_, generation, _, _), let .failure(_, generation, _): generation
        }
    }
}
