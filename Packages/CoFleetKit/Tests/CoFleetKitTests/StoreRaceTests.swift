@testable import CoFleetCore
import Foundation
import XCTest

@MainActor
final class StoreRaceTests: XCTestCase {
    func testArchivedLoadCannotReclaimRouteAndNextProjectLoadsActiveTasks() async {
        let archivedStarted = AsyncLatch()
        let archivedRelease = AsyncLatch()
        let repository = SessionRouteRaceRepository(
            archivedStarted: archivedStarted,
            archivedRelease: archivedRelease
        )
        let store = ThreadStore(repository: repository)
        let firstHost = CoFleetHostID(rawValue: "host-a")
        let secondHost = CoFleetHostID(rawValue: "host-b")

        await store.loadInitial(hostID: firstHost, projectID: "project-a")
        let archiveLoad = Task { await store.setShowsArchived(true) }
        await archivedStarted.wait()

        await store.loadInitial(hostID: secondHost, projectID: "project-b")
        await archivedRelease.signal()
        await archiveLoad.value

        XCTAssertEqual(store.loadedHostID, secondHost)
        XCTAssertEqual(store.loadedProjectID, "project-b")
        XCTAssertFalse(store.showsArchived)
        XCTAssertEqual(store.sessions.map(\.id), ["active-project-b"])
        let secondProjectArchivedFlags = await repository.archivedFlags(for: "project-b")
        XCTAssertEqual(secondProjectArchivedFlags, [false])
    }

    func testConcurrentPreviewRefreshesShareFirstPageRequest() async {
        let firstStarted = AsyncLatch()
        let firstRelease = AsyncLatch()
        let repository = PreviewRaceRepository(firstStarted: firstStarted, firstRelease: firstRelease)
        let store = ThreadStore(repository: repository, previewRepository: repository)
        let project = CoFleetProject(
            id: "project-sample",
            hostID: .init(rawValue: "sample-host"),
            displayName: "Sample",
            canonicalPath: "/tmp/sample"
        )

        let olderRefresh = Task { await store.refreshLatestSessionPreviews(for: [project]) }
        await firstStarted.wait()
        let newerRefresh = Task { await store.refreshLatestSessionPreviews(for: [project]) }
        await Task.yield()
        let requestCount = await repository.sessionRequestCount()
        XCTAssertEqual(requestCount, 1)
        await firstRelease.signal()
        await newerRefresh.value
        await olderRefresh.value

        XCTAssertEqual(store.latestSession(for: project.id)?.id, "old-session")
        XCTAssertEqual(store.latestPreview(for: project.id)?.messages.map(\.text), ["Old question", "Old answer"])
        XCTAssertFalse(store.previewLoadingProjectIDs.contains(project.id))
    }

    func testOutOfPageCanonicalSelectionDoesNotMasqueradeAsFirstSession() async {
        let repository = SessionRouteRaceRepository(
            archivedStarted: AsyncLatch(),
            archivedRelease: AsyncLatch()
        )
        let store = ThreadStore(repository: repository)
        let host = CoFleetHostID(rawValue: "sample-host")

        await store.loadInitial(hostID: host, projectID: "project-sample")
        store.selectedSessionID = "canonical-session-outside-first-page"

        XCTAssertNil(store.selectedSession)
        await store.loadInitial(hostID: host, projectID: "project-sample")
        XCTAssertEqual(store.selectedSessionID, "canonical-session-outside-first-page")
        XCTAssertNil(store.selectedSession)
    }

    func testColdSessionCatalogRetriesOneTransientTimeout() async {
        let repository = TransientCodexReadRepository(failSessionReads: 1)
        let store = ThreadStore(repository: repository)

        await store.loadInitial(
            hostID: .init(rawValue: "sample-host"),
            projectID: "project-sample"
        )

        XCTAssertEqual(store.sessions.map(\.id), ["session-sample"])
        XCTAssertNil(store.errorMessage)
        let sessionReadCount = await repository.sessionReadCount()
        XCTAssertEqual(sessionReadCount, 2)
    }

    func testCompanionDoesNotRetryDesktopLaunchSideEffect() async {
        let repository = TransientCodexReadRepository(failDesktopOpens: 1)
        let store = ThreadStore(repository: repository)
        let hostID = CoFleetHostID(rawValue: "sample-host")
        await store.loadInitial(hostID: hostID, projectID: "project-sample")

        do {
            try await store.openSelectedInCodex()
            XCTFail("Expected the desktop launch error to be surfaced")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Codex is busy"))
        }

        let desktopOpenCount = await repository.desktopOpenCount()
        XCTAssertEqual(desktopOpenCount, 1)
    }

    func testInteractionFailureStillCommitsTranscriptAndStartsEvents() async {
        let eventsStarted = AsyncLatch()
        let repository = InteractionFailureRepository(eventsStarted: eventsStarted)
        let store = TurnStore(repository: repository)

        await store.open(
            hostID: .init(rawValue: "sample-host"),
            projectID: "project-sample",
            sessionID: "session-sample"
        )
        await eventsStarted.wait()

        XCTAssertEqual(store.items.map(\.text), ["Recovered transcript"])
        XCTAssertTrue(store.interactions.isEmpty)
        XCTAssertTrue(store.errorMessage?.contains("Pending interactions") == true)
    }

    func testComposerDraftsAreScopedByHostProjectAndSession() async {
        let store = TurnStore(repository: ImmediateTurnRepository())
        let firstHost = CoFleetHostID(rawValue: "host-a")
        let secondHost = CoFleetHostID(rawValue: "host-b")

        await store.open(hostID: firstHost, projectID: "project-a", sessionID: "session-a")
        store.draft = "First draft"

        await store.open(hostID: firstHost, projectID: "project-a", sessionID: "session-b")
        XCTAssertTrue(store.draft.isEmpty)
        store.draft = "Second session draft"

        await store.open(hostID: secondHost, projectID: "project-a", sessionID: "session-a")
        XCTAssertTrue(store.draft.isEmpty)
        store.draft = "Other host draft"

        await store.open(hostID: firstHost, projectID: "project-a", sessionID: "session-a")
        XCTAssertEqual(store.draft, "First draft")
        await store.open(hostID: firstHost, projectID: "project-a", sessionID: "session-b")
        XCTAssertEqual(store.draft, "Second session draft")
        await store.open(hostID: secondHost, projectID: "project-a", sessionID: "session-a")
        XCTAssertEqual(store.draft, "Other host draft")
    }

    func testLateSendCompletionCannotMutateNewRoute() async throws {
        let sendStarted = AsyncLatch()
        let sendRelease = AsyncLatch()
        let repository = SendRaceRepository(sendStarted: sendStarted, sendRelease: sendRelease)
        let store = TurnStore(repository: repository)
        let host = CoFleetHostID(rawValue: "sample-host")

        await store.open(hostID: host, projectID: "project-a", sessionID: "session-a")
        store.draft = "Send from A"
        let send = Task { try await store.send(settings: .init()) }
        await sendStarted.wait()

        await store.open(hostID: host, projectID: "project-b", sessionID: "session-b")
        store.draft = "Keep B"
        await sendRelease.signal()
        _ = try await send.value

        XCTAssertEqual(store.loadedProjectID, "project-b")
        XCTAssertEqual(store.loadedSessionID, "session-b")
        XCTAssertEqual(store.items.map(\.text), ["Session B"])
        XCTAssertEqual(store.draft, "Keep B")
        XCTAssertNil(store.activeTurn)
    }

    func testFailedSendRestoresOnlyItsOwningRouteComposer() async {
        let sendStarted = AsyncLatch()
        let sendRelease = AsyncLatch()
        let repository = SendRaceRepository(
            sendStarted: sendStarted,
            sendRelease: sendRelease,
            shouldFail: true
        )
        let store = TurnStore(repository: repository)
        let host = CoFleetHostID(rawValue: "sample-host")

        await store.open(hostID: host, projectID: "project-a", sessionID: "session-a")
        store.draft = "Retry A"
        let send = Task { try await store.send(settings: .init()) }
        await sendStarted.wait()

        await store.open(hostID: host, projectID: "project-b", sessionID: "session-b")
        store.draft = "Keep B"
        await sendRelease.signal()
        do {
            _ = try await send.value
            XCTFail("Expected the synthetic failure")
        } catch {
            // Expected.
        }

        XCTAssertEqual(store.draft, "Keep B")
        await store.open(hostID: host, projectID: "project-a", sessionID: "session-a")
        XCTAssertEqual(store.draft, "Retry A")
    }

    func testLateResetCannotOverwriteNewRoute() async {
        let resetStarted = AsyncLatch()
        let resetRelease = AsyncLatch()
        let resetFinished = AsyncLatch()
        let repository = ResetRaceRepository(
            resetStarted: resetStarted,
            resetRelease: resetRelease,
            resetFinished: resetFinished
        )
        let store = TurnStore(repository: repository)
        let host = CoFleetHostID(rawValue: "sample-host")

        await store.open(hostID: host, projectID: "project-a", sessionID: "session-a")
        await repository.armDelayedReset()
        store.apply(.resetRequired)
        await resetStarted.wait()

        await store.open(hostID: host, projectID: "project-b", sessionID: "session-b")
        await resetRelease.signal()
        await resetFinished.wait()
        for _ in 0..<4 { await Task.yield() }

        XCTAssertEqual(store.loadedProjectID, "project-b")
        XCTAssertEqual(store.loadedSessionID, "session-b")
        XCTAssertEqual(store.items.map(\.text), ["Session B"])
    }
}

private actor AsyncLatch {
    private var isSignaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isSignaled { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func signal() {
        guard !isSignaled else { return }
        isSignaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private enum StoreRaceError: Error, LocalizedError {
    case unavailable

    var errorDescription: String? { "Synthetic interaction failure." }
}

private protocol ThreadRepositoryStub: CoFleetThreadRepository {}

private extension ThreadRepositoryStub {
    func createSession(hostID: CoFleetHostID, projectID: String) async throws -> CoFleetSessionSummary {
        .init(id: "new-session", hostID: hostID, projectID: projectID, title: "New")
    }

    func resumeSession(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String,
        settings: CoFleetSessionSettings
    ) async throws -> CoFleetSessionSummary {
        .init(id: sessionID, hostID: hostID, projectID: projectID, title: "Resumed")
    }

    func forkSession(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String,
        settings: CoFleetSessionSettings
    ) async throws -> CoFleetSessionSummary {
        .init(id: "forked-session", hostID: hostID, projectID: projectID, title: "Forked")
    }

    func renameSession(hostID: CoFleetHostID, sessionID: String, title: String) async throws {}
    func archiveSession(hostID: CoFleetHostID, sessionID: String) async throws {}
    func unarchiveSession(hostID: CoFleetHostID, sessionID: String) async throws {}
    func openSessionInCodex(hostID: CoFleetHostID, sessionID: String) async throws {}
}

private protocol TurnRepositoryStub: CoFleetTurnRepository {}

private extension TurnRepositoryStub {
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
        .init(id: "turn", hostID: hostID, sessionID: sessionID, state: .running)
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
        AsyncThrowingStream { _ in }
    }
}

private actor SessionRouteRaceRepository: ThreadRepositoryStub {
    private let archivedStarted: AsyncLatch
    private let archivedRelease: AsyncLatch
    private var requests: [(projectID: String, archived: Bool)] = []

    init(archivedStarted: AsyncLatch, archivedRelease: AsyncLatch) {
        self.archivedStarted = archivedStarted
        self.archivedRelease = archivedRelease
    }

    func fetchSessions(
        hostID: CoFleetHostID,
        projectID: String,
        cursor: String?,
        limit: Int,
        archived: Bool
    ) async throws -> CoFleetSessionPage {
        requests.append((projectID, archived))
        if archived {
            await archivedStarted.signal()
            await archivedRelease.wait()
        }
        let prefix = archived ? "archived" : "active"
        return .init(items: [
            .init(
                id: "\(prefix)-\(projectID)",
                hostID: hostID,
                projectID: projectID,
                title: "Synthetic"
            ),
        ], nextCursor: nil)
    }

    func archivedFlags(for projectID: String) -> [Bool] {
        requests.filter { $0.projectID == projectID }.map(\.archived)
    }
}

private actor PreviewRaceRepository: ThreadRepositoryStub, TurnRepositoryStub {
    private let firstStarted: AsyncLatch
    private let firstRelease: AsyncLatch
    private var requestCount = 0

    init(firstStarted: AsyncLatch, firstRelease: AsyncLatch) {
        self.firstStarted = firstStarted
        self.firstRelease = firstRelease
    }

    func fetchSessions(
        hostID: CoFleetHostID,
        projectID: String,
        cursor: String?,
        limit: Int,
        archived: Bool
    ) async throws -> CoFleetSessionPage {
        requestCount += 1
        let request = requestCount
        if request == 1 {
            await firstStarted.signal()
            await firstRelease.wait()
        }
        let sessionID = request == 1 ? "old-session" : "new-session"
        return .init(items: [
            .init(id: sessionID, hostID: hostID, projectID: projectID, title: sessionID),
        ], nextCursor: nil)
    }

    func fetchTranscript(hostID: CoFleetHostID, sessionID: String) async throws -> [CoFleetTurnItem] {
        let prefix = sessionID == "new-session" ? "New" : "Old"
        return [
            .init(id: "\(sessionID)-user", turnID: "turn", kind: .userMessage, text: "\(prefix) question"),
            .init(id: "\(sessionID)-assistant", turnID: "turn", kind: .assistantMessage, text: "\(prefix) answer"),
        ]
    }

    func sessionRequestCount() -> Int { requestCount }
}

private actor TransientCodexReadRepository: ThreadRepositoryStub {
    private var remainingSessionFailures: Int
    private var remainingDesktopFailures: Int
    private var sessionReads = 0
    private var desktopOpens = 0

    init(failSessionReads: Int = 0, failDesktopOpens: Int = 0) {
        remainingSessionFailures = failSessionReads
        remainingDesktopFailures = failDesktopOpens
    }

    func fetchSessions(
        hostID: CoFleetHostID,
        projectID: String,
        cursor: String?,
        limit: Int,
        archived: Bool
    ) async throws -> CoFleetSessionPage {
        sessionReads += 1
        if remainingSessionFailures > 0 {
            remainingSessionFailures -= 1
            throw CoFleetClientError.unavailable("Codex app-server did not answer in time.")
        }
        return .init(items: [
            .init(
                id: "session-sample",
                hostID: hostID,
                projectID: projectID,
                title: "Sample"
            ),
        ], nextCursor: nil)
    }

    func openSessionInCodex(hostID: CoFleetHostID, sessionID: String) async throws {
        desktopOpens += 1
        if remainingDesktopFailures > 0 {
            remainingDesktopFailures -= 1
            throw CoFleetClientError.unavailable("Codex is busy; try again shortly.")
        }
    }

    func sessionReadCount() -> Int { sessionReads }
    func desktopOpenCount() -> Int { desktopOpens }
}

private actor InteractionFailureRepository: TurnRepositoryStub {
    private let eventsStarted: AsyncLatch

    init(eventsStarted: AsyncLatch) {
        self.eventsStarted = eventsStarted
    }

    func fetchTranscript(hostID: CoFleetHostID, sessionID: String) async throws -> [CoFleetTurnItem] {
        [.init(id: "message", turnID: "turn", kind: .assistantMessage, text: "Recovered transcript")]
    }

    func fetchInteractions(hostID: CoFleetHostID, sessionID: String) async throws -> [CoFleetInteraction] {
        throw StoreRaceError.unavailable
    }

    func events(
        hostID: CoFleetHostID,
        sessionID: String,
        afterEventID: String?
    ) async throws -> AsyncThrowingStream<CoFleetSequencedTurnEvent, Error> {
        await eventsStarted.signal()
        return AsyncThrowingStream { _ in }
    }
}

private actor ImmediateTurnRepository: TurnRepositoryStub {}

private actor SendRaceRepository: TurnRepositoryStub {
    private let sendStarted: AsyncLatch
    private let sendRelease: AsyncLatch
    private let shouldFail: Bool

    init(sendStarted: AsyncLatch, sendRelease: AsyncLatch, shouldFail: Bool = false) {
        self.sendStarted = sendStarted
        self.sendRelease = sendRelease
        self.shouldFail = shouldFail
    }

    func fetchTranscript(hostID: CoFleetHostID, sessionID: String) async throws -> [CoFleetTurnItem] {
        guard sessionID == "session-b" else { return [] }
        return [.init(id: "b", turnID: "turn-b", kind: .assistantMessage, text: "Session B")]
    }

    func startTurn(
        hostID: CoFleetHostID,
        projectID: String,
        sessionID: String,
        input: [CoFleetTurnInput],
        settings: CoFleetSessionSettings,
        idempotencyKey: UUID
    ) async throws -> CoFleetTurn {
        await sendStarted.signal()
        await sendRelease.wait()
        if shouldFail { throw StoreRaceError.unavailable }
        return .init(id: "late-turn", hostID: hostID, sessionID: sessionID, state: .running)
    }
}

private actor ResetRaceRepository: TurnRepositoryStub {
    private let resetStarted: AsyncLatch
    private let resetRelease: AsyncLatch
    private let resetFinished: AsyncLatch
    private var delaysNextReset = false

    init(resetStarted: AsyncLatch, resetRelease: AsyncLatch, resetFinished: AsyncLatch) {
        self.resetStarted = resetStarted
        self.resetRelease = resetRelease
        self.resetFinished = resetFinished
    }

    func armDelayedReset() {
        delaysNextReset = true
    }

    func fetchTranscript(hostID: CoFleetHostID, sessionID: String) async throws -> [CoFleetTurnItem] {
        if sessionID == "session-a", delaysNextReset {
            delaysNextReset = false
            await resetStarted.signal()
            await resetRelease.wait()
            await resetFinished.signal()
            return [.init(id: "late-a", turnID: "turn-a", kind: .assistantMessage, text: "Late reset A")]
        }
        let text = sessionID == "session-b" ? "Session B" : "Session A"
        return [.init(id: sessionID, turnID: "turn", kind: .assistantMessage, text: text)]
    }
}
