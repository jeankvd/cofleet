import CoFleetCore
import XCTest

@MainActor
final class ThreadSnapshotStorageTests: XCTestCase {
    func testUserDefaultsSnapshotIsHostScopedAndBoundsSessionsAndMessages() {
        let suiteName = "org.cofleet.tests.thread-snapshots.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let hostID = CoFleetHostID(rawValue: "host-sample")
        let projectID = "project-sample"
        let sessions = (0..<7).map { index in
            CoFleetSessionSummary(
                id: "session-\(index)",
                hostID: hostID,
                projectID: projectID,
                title: "Session \(index)",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }
        let preview = CoFleetProjectConversationPreview(
            session: sessions[6],
            messages: [
                .init(id: "user-old", turnID: "old", kind: .userMessage, text: "Old question"),
                .init(id: "answer-old", turnID: "old", kind: .assistantMessage, text: "Old answer"),
                .init(id: "reasoning", turnID: "new", kind: .reasoning, text: "Hidden"),
                .init(id: "user-new", turnID: "new", kind: .userMessage, text: "Fresh question"),
                .init(id: "answer-new", turnID: "new", kind: .assistantMessage, text: "Fresh answer"),
            ]
        )
        let storage = CoFleetUserDefaultsThreadSnapshotStorage(defaults: defaults)
        XCTAssertTrue(storage.save(CoFleetThreadSnapshot(
            key: .init(hostID: hostID, projectID: projectID),
            sessions: sessions,
            preview: preview
        )))

        let restored = storage.snapshot(for: .init(hostID: hostID, projectID: projectID))
        XCTAssertEqual(restored?.sessions.map(\.id), [
            "session-6", "session-5", "session-4", "session-3", "session-2",
        ])
        XCTAssertEqual(restored?.preview?.messages.map(\.text), ["Fresh question", "Fresh answer"])
        XCTAssertNil(storage.snapshot(for: .init(hostID: .init(rawValue: "other-host"), projectID: projectID)))
    }

    func testUserDefaultsSnapshotEvictsOldEntriesAndRejectsOversizedEnvelope() {
        let suiteName = "org.cofleet.tests.thread-snapshot-bounds.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Could not create isolated defaults suite")
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hostID = CoFleetHostID(rawValue: "host-sample")
        let storage = CoFleetUserDefaultsThreadSnapshotStorage(
            defaults: defaults,
            maximumEntries: 2,
            maximumEncodedBytes: 4_096
        )

        for index in 0..<3 {
            XCTAssertTrue(storage.save(CoFleetThreadSnapshot(
                key: .init(hostID: hostID, projectID: "project-\(index)"),
                sessions: [],
                preview: nil,
                savedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )))
        }
        XCTAssertNil(storage.snapshot(for: .init(hostID: hostID, projectID: "project-0")))
        XCTAssertNotNil(storage.snapshot(for: .init(hostID: hostID, projectID: "project-1")))
        XCTAssertNotNil(storage.snapshot(for: .init(hostID: hostID, projectID: "project-2")))

        let oversizedSession = CoFleetSessionSummary(
            id: "oversized",
            hostID: hostID,
            projectID: "oversized-project",
            title: String(repeating: "x", count: 8_192)
        )
        XCTAssertFalse(storage.save(CoFleetThreadSnapshot(
            key: .init(hostID: hostID, projectID: "oversized-project"),
            sessions: [oversizedSession],
            preview: nil
        )))
        XCTAssertNil(storage.snapshot(for: .init(hostID: hostID, projectID: "oversized-project")))
    }

    func testLoadInitialPublishesPersistedSessionsBeforeRefreshCompletes() async {
        let hostID = CoFleetHostID(rawValue: "host-sample")
        let projectID = "project-sample"
        let cached = session(id: "cached", hostID: hostID, projectID: projectID, updatedAt: 10)
        let fresh = session(id: "fresh", hostID: hostID, projectID: projectID, updatedAt: 20)
        let storage = CoFleetInMemoryThreadSnapshotStorage()
        storage.save(CoFleetThreadSnapshot(
            key: .init(hostID: hostID, projectID: projectID),
            sessions: [cached],
            preview: nil
        ))
        let repository = BlockingThreadRepository(page: .init(items: [fresh], nextCursor: nil))
        let store = ThreadStore(repository: repository, snapshotStorage: storage)

        let load = Task { await store.loadInitial(hostID: hostID, projectID: projectID) }
        await repository.waitUntilFetchStarts()
        XCTAssertEqual(store.sessions.map(\.id), ["cached"])
        XCTAssertEqual(store.selectedSessionID, "cached")

        await repository.releaseFetch()
        await load.value
        XCTAssertEqual(store.sessions.map(\.id), ["fresh"])
    }

    func testProgressPreviewPublishesPersistedMessagesBeforeRefreshCompletes() async {
        let hostID = CoFleetHostID(rawValue: "host-sample")
        let projectID = "project-sample"
        let cachedSession = session(id: "session", hostID: hostID, projectID: projectID, updatedAt: 10)
        let storage = CoFleetInMemoryThreadSnapshotStorage()
        storage.save(CoFleetThreadSnapshot(
            key: .init(hostID: hostID, projectID: projectID),
            sessions: [cachedSession],
            preview: .init(session: cachedSession, messages: [
                .init(id: "user", turnID: "turn", kind: .userMessage, text: "Cached question"),
                .init(id: "answer", turnID: "turn", kind: .assistantMessage, text: "Cached answer"),
            ])
        ))
        let repository = BlockingThreadRepository(page: .init(items: [cachedSession], nextCursor: nil))
        let store = ThreadStore(
            repository: repository,
            previewRepository: repository,
            snapshotStorage: storage
        )
        let project = CoFleetProject(
            id: projectID,
            hostID: hostID,
            displayName: "Sample",
            canonicalPath: "/tmp/sample"
        )

        let refresh = Task { await store.refreshLatestSessionPreviews(for: [project]) }
        await repository.waitUntilFetchStarts()
        XCTAssertEqual(
            store.latestPreview(for: projectID)?.messages.map(\.text),
            ["Cached question", "Cached answer"]
        )

        await repository.releaseFetch()
        await refresh.value
    }

    private func session(
        id: String,
        hostID: CoFleetHostID,
        projectID: String,
        updatedAt: TimeInterval
    ) -> CoFleetSessionSummary {
        CoFleetSessionSummary(
            id: id,
            hostID: hostID,
            projectID: projectID,
            title: id,
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            createdAt: Date(timeIntervalSince1970: updatedAt),
            preview: "Question"
        )
    }
}

private actor BlockingThreadRepository: CoFleetThreadRepository, CoFleetTurnRepository {
    private let page: CoFleetSessionPage
    private var fetchStarted = false
    private var fetchContinuation: CheckedContinuation<Void, Never>?

    init(page: CoFleetSessionPage) {
        self.page = page
    }

    func waitUntilFetchStarts() async {
        while !fetchStarted {
            await Task.yield()
        }
    }

    func releaseFetch() {
        fetchContinuation?.resume()
        fetchContinuation = nil
    }

    func fetchSessions(
        hostID: CoFleetHostID,
        projectID: String,
        cursor: String?,
        limit: Int,
        archived: Bool
    ) async throws -> CoFleetSessionPage {
        fetchStarted = true
        await withCheckedContinuation { fetchContinuation = $0 }
        return page
    }

    func createSession(hostID: CoFleetHostID, projectID: String) async throws -> CoFleetSessionSummary {
        page.items[0]
    }

    func resumeSession(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String,
        settings: CoFleetSessionSettings
    ) async throws -> CoFleetSessionSummary { page.items[0] }

    func forkSession(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String,
        settings: CoFleetSessionSettings
    ) async throws -> CoFleetSessionSummary { page.items[0] }

    func renameSession(hostID: CoFleetHostID, sessionID: String, title: String) async throws {}
    func archiveSession(hostID: CoFleetHostID, sessionID: String) async throws {}
    func unarchiveSession(hostID: CoFleetHostID, sessionID: String) async throws {}
    func openSessionInCodex(hostID: CoFleetHostID, sessionID: String) async throws {}

    func fetchTranscript(hostID: CoFleetHostID, sessionID: String) async throws -> [CoFleetTurnItem] { [] }
    func fetchInteractions(hostID: CoFleetHostID, sessionID: String) async throws -> [CoFleetInteraction] { [] }

    func startTurn(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String,
        input: [CoFleetTurnInput],
        settings: CoFleetSessionSettings,
        idempotencyKey: UUID
    ) async throws -> CoFleetTurn {
        CoFleetTurn(id: "turn", hostID: hostID, sessionID: sessionID, state: .running)
    }

    func interruptTurn(hostID: CoFleetHostID, sessionID: String, turnID: String) async throws {}

    func resolveInteraction(
        hostID: CoFleetHostID,
        interactionID: String,
        decision: CoFleetInteractionDecision,
        answers: [String: [String]]?
    ) async throws {}

    func events(
        hostID: CoFleetHostID,
        sessionID: String,
        afterEventID: String?
    ) async throws -> AsyncThrowingStream<CoFleetSequencedTurnEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
