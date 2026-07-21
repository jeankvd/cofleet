import Foundation
import Observation

@MainActor
@Observable
public final class ThreadStore {
    public private(set) var sessions: [CoFleetSessionSummary] = []
    public private(set) var nextCursor: String?
    public private(set) var isLoading = false
    public private(set) var errorMessage: String?
    public private(set) var showsArchived = false
    public var selectedSessionID: String?

    @ObservationIgnored private let repository: any CoFleetThreadRepository
    @ObservationIgnored private var hostID: CoFleetHostID?
    @ObservationIgnored private var projectID: String?

    public init(repository: any CoFleetThreadRepository) {
        self.repository = repository
    }

    public var selectedSession: CoFleetSessionSummary? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first { $0.id == selectedSessionID }
    }

    public var canLoadMore: Bool { nextCursor != nil }

    public func loadInitial(hostID: CoFleetHostID, projectID: String) async {
        self.hostID = hostID
        self.projectID = projectID
        sessions = []
        nextCursor = nil
        selectedSessionID = nil
        await loadPage(cursor: nil, replacing: true)
    }

    public func loadMore() async {
        guard !isLoading, let nextCursor else { return }
        await loadPage(cursor: nextCursor, replacing: false)
    }

    public func setShowsArchived(_ archived: Bool) async {
        guard showsArchived != archived, let hostID, let projectID else { return }
        showsArchived = archived
        sessions = []
        nextCursor = nil
        selectedSessionID = nil
        await loadPage(cursor: nil, replacing: true)
        self.hostID = hostID
        self.projectID = projectID
    }

    @discardableResult
    public func createSession() async throws -> CoFleetSessionSummary {
        guard let hostID, let projectID else {
            throw CoFleetClientError.unavailable("Select a project before creating a session.")
        }
        let session = try await repository.createSession(hostID: hostID, projectID: projectID)
        sessions.insert(session, at: 0)
        selectedSessionID = session.id
        return session
    }

    public func archiveSelected() async throws {
        guard let hostID, let selectedSessionID else { return }
        try await repository.archiveSession(hostID: hostID, sessionID: selectedSessionID)
        sessions.removeAll { $0.id == selectedSessionID }
        self.selectedSessionID = sessions.first?.id
    }

    public func unarchiveSelected() async throws {
        guard let hostID, let selectedSessionID else { return }
        try await repository.unarchiveSession(hostID: hostID, sessionID: selectedSessionID)
        sessions.removeAll { $0.id == selectedSessionID }
        self.selectedSessionID = sessions.first?.id
    }

    @discardableResult
    public func resumeSelected(settings: CoFleetSessionSettings) async throws -> CoFleetSessionSummary? {
        guard let hostID, let projectID, let selectedSessionID else { return nil }
        let resumed = try await repository.resumeSession(
            hostID: hostID,
            projectID: projectID,
            sessionID: selectedSessionID,
            settings: settings
        )
        replaceOrInsert(resumed)
        return resumed
    }

    @discardableResult
    public func forkSelected(settings: CoFleetSessionSettings) async throws -> CoFleetSessionSummary? {
        guard let hostID, let projectID, let selectedSessionID else { return nil }
        let forked = try await repository.forkSession(
            hostID: hostID,
            projectID: projectID,
            sessionID: selectedSessionID,
            settings: settings
        )
        sessions.insert(forked, at: 0)
        self.selectedSessionID = forked.id
        return forked
    }

    public func renameSelected(_ title: String) async throws {
        guard let hostID, let selectedSessionID else { return }
        try await repository.renameSession(hostID: hostID, sessionID: selectedSessionID, title: title)
        guard let index = sessions.firstIndex(where: { $0.id == selectedSessionID }) else { return }
        sessions[index].title = title
    }

    private func loadPage(cursor: String?, replacing: Bool) async {
        guard let hostID, let projectID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await repository.fetchSessions(
                hostID: hostID,
                projectID: projectID,
                cursor: cursor,
                limit: 5,
                archived: showsArchived
            )
            if replacing {
                sessions = page.items
            } else {
                let known = Set(sessions.map(\.id))
                sessions.append(contentsOf: page.items.filter { !known.contains($0.id) })
            }
            nextCursor = page.nextCursor
            if selectedSessionID == nil { selectedSessionID = sessions.first?.id }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func replaceOrInsert(_ session: CoFleetSessionSummary) {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            sessions[index] = session
        } else {
            sessions.insert(session, at: 0)
        }
    }
}
