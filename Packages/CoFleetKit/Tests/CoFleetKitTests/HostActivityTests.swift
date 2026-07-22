import CoFleetCore
import CoFleetTransport
import Foundation
import XCTest

final class HostActivityTests: XCTestCase {
    private let hostID = CoFleetHostID(rawValue: "host-sample")

    func testHostDecoderPreservesReplayCursorAndDecodesActivity() throws {
        let raw = CoFleetSSEEvent(
            id: "42",
            name: "project.activityChanged",
            data: #"{"type":"project.activityChanged","hostID":"host-sample","projectID":"project-one","sessionID":"session-one","turnID":"turn-one","state":"working","itemKind":"reasoning","observedAt":"2026-07-21T17:00:00Z","source":"codexDesktop","_cofleetReplay":true}"#,
            retryMilliseconds: 1_200
        )

        let decoded = try CoFleetHostEventDecoder(hostID: hostID).decode(raw)

        XCTAssertEqual(decoded.id, "42")
        XCTAssertEqual(decoded.retryMilliseconds, 1_200)
        XCTAssertTrue(decoded.isReplay)
        guard case let .activityChanged(update) = decoded.event else {
            return XCTFail("Expected project activity")
        }
        XCTAssertEqual(update.hostID, hostID)
        XCTAssertEqual(update.projectID, "project-one")
        XCTAssertEqual(update.sessionID, "session-one")
        XCTAssertEqual(update.state, .working)
        XCTAssertEqual(update.itemKind, "reasoning")
        XCTAssertEqual(update.source, .codexDesktop)
    }

    func testHostDecoderTurnsUnknownEventIntoCursorCheckpoint() throws {
        let decoded = try CoFleetHostEventDecoder(hostID: hostID).decode(.init(
            id: "99",
            name: "future.provider-neutral.event",
            data: "not-json"
        ))

        XCTAssertEqual(decoded.id, "99")
        XCTAssertEqual(decoded.event, .checkpoint)
    }

    func testHostDecoderRoutesCatalogAndTurnItemToExplicitProject() throws {
        let decoder = CoFleetHostEventDecoder(hostID: hostID)
        let catalog = try decoder.decode(.init(
            id: "100",
            name: "session.catalogUpdated",
            data: #"{"type":"session.catalogUpdated","projectID":"project-one","currentSessionID":"session-new"}"#
        ))
        XCTAssertEqual(
            catalog.event,
            .sessionCatalogUpdated(.init(
                hostID: hostID,
                projectID: "project-one",
                currentSessionID: "session-new"
            ))
        )

        let item = try decoder.decode(.init(
            id: "101",
            name: "turn.item",
            data: #"{"type":"turn.item","projectID":"project-one","sessionID":"session-new","item":{"id":"reply","turnID":"turn-one","kind":"assistantMessage","state":"completed","text":"Done","createdAt":"2026-07-21T17:00:00Z"}}"#
        ))
        XCTAssertEqual(item.event.explicitProjectID, "project-one")
        XCTAssertEqual(item.event.sessionID, "session-new")
    }

    func testActivityReducerProjectsDetailedWorkAndInteractionStates() {
        let reasoning = CoFleetProjectActivityReducer.reduce(
            current: nil,
            projectID: "project-one",
            event: .activityChanged(.init(
                hostID: hostID,
                projectID: "project-one",
                sessionID: "session-one",
                state: .working,
                itemKind: "reasoning"
            ))
        )
        XCTAssertEqual(reasoning?.activity, .reasoning)
        XCTAssertEqual(reasoning?.activity.projectState, .working)

        let command = CoFleetProjectActivityReducer.reduce(
            current: reasoning,
            projectID: "project-one",
            event: .turnItem(
                projectID: "project-one",
                sessionID: "session-one",
                item: .init(
                    id: "command",
                    turnID: "turn-one",
                    kind: .command,
                    state: .streaming,
                    text: "swift test"
                )
            )
        )
        XCTAssertEqual(command?.activity, .runningCommand)

        let question = CoFleetProjectActivityReducer.reduce(
            current: command,
            projectID: "project-one",
            event: .interactionPending(
                projectID: "project-one",
                interaction: .init(
                    id: "question",
                    hostID: hostID,
                    sessionID: "session-one",
                    turnID: "turn-one",
                    kind: .question,
                    title: "Choose",
                    detail: "Which one?",
                    choices: [.submitAnswer],
                    expiresAt: .now.addingTimeInterval(300)
                )
            )
        )
        XCTAssertEqual(question?.activity, .question)
        XCTAssertEqual(question?.activity.projectState, .waitingForAnswer)

        let replied = CoFleetProjectActivityReducer.reduce(
            current: question,
            projectID: "project-one",
            event: .turnItem(
                projectID: "project-one",
                sessionID: "session-one",
                item: .init(
                    id: "answer",
                    turnID: "turn-one",
                    kind: .assistantMessage,
                    state: .completed,
                    text: "Done"
                )
            )
        )
        XCTAssertEqual(replied?.activity, .replied)

        let idleAfterReply = CoFleetProjectActivityReducer.reduce(
            current: replied,
            projectID: "project-one",
            event: .activityChanged(.init(
                hostID: hostID,
                projectID: "project-one",
                sessionID: "session-one",
                state: .idle
            ))
        )
        XCTAssertEqual(idleAfterReply?.activity, .replied)
    }

    func testDesktopIdleWaitsForCanonicalReconciliation() {
        let working = CoFleetProjectActivitySnapshot(
            projectID: "project-one",
            sessionID: "session-one",
            activity: .thinking,
            source: .codexDesktop
        )

        let reduced = CoFleetProjectActivityReducer.reduce(
            current: working,
            projectID: "project-one",
            event: .activityChanged(.init(
                hostID: hostID,
                projectID: "project-one",
                sessionID: "session-one",
                state: .idle,
                source: .codexDesktop
            ))
        )

        XCTAssertEqual(reduced?.activity, .thinking)
    }

    func testReconnectBackoffIsBoundedAndHonorsServerRetry() {
        var backoff = CoFleetHostEventReconnectBackoff()
        XCTAssertEqual(backoff.nextDelay(jitter: 1), .milliseconds(500))
        XCTAssertEqual(backoff.nextDelay(jitter: 1), .seconds(1))
        XCTAssertEqual(backoff.nextDelay(serverRetryMilliseconds: 10, jitter: 1), .milliseconds(250))
        backoff.reset()
        XCTAssertEqual(backoff.nextDelay(serverRetryMilliseconds: 90_000, jitter: 1), .seconds(30))
    }
}

@MainActor
final class HostActivityStoreTests: XCTestCase {
    func testFleetStoreMirrorsRichActivityAndCurrentSession() async {
        let hostID = CoFleetHostID(rawValue: "host-sample")
        let repository = HostActivityFleetRepository(hostID: hostID)
        let store = FleetStore(repository: repository)
        await store.refresh()

        store.applyHostEvent(
            .activityChanged(.init(
                hostID: hostID,
                projectID: "project-one",
                sessionID: "session-one",
                state: .working,
                itemKind: "command"
            )),
            to: "project-one"
        )
        store.setCurrentSessionID("session-one", projectID: "project-one", hostID: hostID)

        XCTAssertEqual(store.activity(for: "project-one")?.activity, .runningCommand)
        XCTAssertEqual(store.projects.first?.state, .working)
        XCTAssertEqual(store.projects.first?.currentSessionID, "session-one")
        XCTAssertEqual(store.activityRevision, 1)
    }

    func testCatalogReconciliationPreservesExplicitHistoricalSelection() async {
        let hostID = CoFleetHostID(rawValue: "host-sample")
        let repository = HostActivityThreadRepository(hostID: hostID)
        let store = ThreadStore(repository: repository, previewRepository: repository)
        let project = CoFleetProject(
            id: "project-one",
            hostID: hostID,
            displayName: "Sample",
            canonicalPath: "/tmp/sample",
            currentSessionID: "current-old"
        )

        await store.loadInitial(hostID: hostID, projectID: project.id)
        store.selectedSessionID = "history"
        await repository.publishNewCurrentSession()
        _ = await store.reconcileLatestSessionPreview(
            for: project,
            previousCurrentSessionID: "current-old",
            currentSessionID: "current-new"
        )

        XCTAssertEqual(store.selectedSessionID, "history")
        XCTAssertEqual(store.sessionsByProjectID[project.id]?.first?.id, "current-new")
        XCTAssertEqual(store.projectID(hostID: hostID, sessionID: "current-new"), project.id)
    }

    func testLiveItemForNewCurrentSessionReplacesOlderPreview() async {
        let hostID = CoFleetHostID(rawValue: "host-sample")
        let repository = HostActivityThreadRepository(hostID: hostID)
        let store = ThreadStore(repository: repository, previewRepository: repository)
        await store.loadInitial(hostID: hostID, projectID: "project-one")

        store.applyLiveItem(
            hostID: hostID,
            projectID: "project-one",
            sessionID: "current-old",
            item: .init(
                id: "old-user",
                turnID: "old-turn",
                kind: .userMessage,
                text: "Older prompt"
            ),
            isCurrentSession: true
        )
        store.applyLiveItem(
            hostID: hostID,
            projectID: "project-one",
            sessionID: "current-new",
            item: .init(
                id: "new-user",
                turnID: "new-turn",
                kind: .userMessage,
                text: "New prompt"
            ),
            isCurrentSession: true
        )

        XCTAssertEqual(store.latestPreview(for: "project-one")?.session.id, "current-new")
        XCTAssertEqual(store.latestPreview(for: "project-one")?.messages.first?.text, "New prompt")
    }
}

private actor HostActivityFleetRepository: CoFleetFleetRepository {
    let hostID: CoFleetHostID

    init(hostID: CoFleetHostID) { self.hostID = hostID }

    func fetchHosts() async throws -> [CoFleetHostInfo] {
        [.init(
            id: hostID,
            displayName: "Sample Mac",
            platform: "macOS",
            canonicalHome: "/Users/sample",
            reachability: .online
        )]
    }

    func fetchAccount(hostID: CoFleetHostID) async throws -> CoFleetAccountInfo { .init(hostID: hostID) }
    func fetchAccountLimits(hostID: CoFleetHostID) async throws -> [CoFleetRateLimitInfo] { [] }
    func fetchProjects() async throws -> [CoFleetProject] {
        [.init(id: "project-one", hostID: hostID, displayName: "Sample", canonicalPath: "/tmp/sample")]
    }
    func discoverRecentRoots(hostID: CoFleetHostID, cursor: String?) async throws -> CoFleetDirectoryPage {
        .init(canonicalPath: "/", parentPath: nil, entries: [], nextCursor: nil)
    }
    func browseDirectories(hostID: CoFleetHostID, path: String, cursor: String?, showHidden: Bool) async throws -> CoFleetDirectoryPage {
        .init(canonicalPath: path, parentPath: nil, entries: [], nextCursor: nil)
    }
    func createDirectory(hostID: CoFleetHostID, parent: String, name: String) async throws -> CoFleetDirectoryEntry {
        .init(name: name, canonicalPath: "\(parent)/\(name)")
    }
    func registerProject(hostID: CoFleetHostID, canonicalPath: String, displayName: String) async throws -> CoFleetProject {
        .init(hostID: hostID, displayName: displayName, canonicalPath: canonicalPath)
    }
    func removeProject(id: String) async throws {}
}

private actor HostActivityThreadRepository: CoFleetThreadRepository, CoFleetTurnRepository {
    let hostID: CoFleetHostID
    private var hasNewCurrent = false

    init(hostID: CoFleetHostID) { self.hostID = hostID }

    func publishNewCurrentSession() { hasNewCurrent = true }

    func fetchSessions(hostID: CoFleetHostID, projectID: String, cursor: String?, limit: Int, archived: Bool) async throws -> CoFleetSessionPage {
        let ids = hasNewCurrent ? ["current-new", "current-old", "history"] : ["current-old", "history"]
        return .init(items: ids.enumerated().map { index, id in
            .init(
                id: id,
                hostID: hostID,
                projectID: projectID,
                title: id,
                updatedAt: Date(timeIntervalSince1970: Double(100 - index)),
                preview: "Prompt for \(id)"
            )
        }, nextCursor: nil)
    }

    func createSession(hostID: CoFleetHostID, projectID: String) async throws -> CoFleetSessionSummary {
        .init(id: "created", hostID: hostID, projectID: projectID, title: "Created")
    }
    func resumeSession(hostID: CoFleetHostID, projectID: String, sessionID: String, settings: CoFleetSessionSettings) async throws -> CoFleetSessionSummary {
        .init(id: sessionID, hostID: hostID, projectID: projectID, title: sessionID)
    }
    func forkSession(hostID: CoFleetHostID, projectID: String, sessionID: String, settings: CoFleetSessionSettings) async throws -> CoFleetSessionSummary {
        .init(id: "fork", hostID: hostID, projectID: projectID, title: "Fork")
    }
    func renameSession(hostID: CoFleetHostID, sessionID: String, title: String) async throws {}
    func archiveSession(hostID: CoFleetHostID, sessionID: String) async throws {}
    func unarchiveSession(hostID: CoFleetHostID, sessionID: String) async throws {}

    func fetchTranscript(hostID: CoFleetHostID, sessionID: String) async throws -> [CoFleetTurnItem] {
        [
            .init(id: "user-\(sessionID)", turnID: "turn", kind: .userMessage, text: "Prompt for \(sessionID)"),
            .init(id: "reply-\(sessionID)", turnID: "turn", kind: .assistantMessage, text: "Reply for \(sessionID)"),
        ]
    }
    func fetchInteractions(hostID: CoFleetHostID, sessionID: String) async throws -> [CoFleetInteraction] { [] }
    func startTurn(hostID: CoFleetHostID, projectID: String, sessionID: String, input: [CoFleetTurnInput], settings: CoFleetSessionSettings, idempotencyKey: UUID) async throws -> CoFleetTurn {
        .init(id: "turn", hostID: hostID, sessionID: sessionID, state: .running)
    }
    func interruptTurn(hostID: CoFleetHostID, sessionID: String, turnID: String) async throws {}
    func resolveInteraction(hostID: CoFleetHostID, interactionID: String, decision: CoFleetInteractionDecision, answers: [String: [String]]?) async throws {}
    func events(hostID: CoFleetHostID, sessionID: String, afterEventID: String?) async throws -> AsyncThrowingStream<CoFleetSequencedTurnEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
