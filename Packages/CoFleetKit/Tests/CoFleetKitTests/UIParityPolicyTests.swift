import CoFleetCore
import XCTest
@testable import CoFleetUI

final class UIParityPolicyTests: XCTestCase {
    private let hostID = CoFleetHostID(rawValue: "host")

    func testNavigationOrderAndDefaultsMatchManadaByPlatform() {
        XCTAssertEqual(
            CoFleetDestination.navigationOrder(for: .macOS),
            [.progress, .dashboard, .agentBay, .battle]
        )
        XCTAssertEqual(CoFleetDestination.defaultDestination(for: .macOS), .progress)

        XCTAssertEqual(
            CoFleetDestination.navigationOrder(for: .mobile),
            [.dashboard, .progress, .agentBay, .battle]
        )
        XCTAssertEqual(CoFleetDestination.defaultDestination(for: .mobile), .dashboard)
    }

    func testNavigationSymbolsMatchManadaByPlatform() {
        XCTAssertEqual(CoFleetDestination.progress.symbol(for: .macOS), "chart.bar.xaxis")
        XCTAssertEqual(CoFleetDestination.dashboard.symbol(for: .mobile), "rectangle.3.group")
        XCTAssertEqual(CoFleetDestination.agentBay.symbol(for: .macOS), "sparkles")
        XCTAssertEqual(CoFleetDestination.agentBay.symbol(for: .mobile), "person.3.sequence")
        XCTAssertEqual(CoFleetDestination.active.symbol(for: .mobile), "bolt.horizontal.circle")
        XCTAssertEqual(CoFleetDestination.battle.symbol(for: .macOS), "shield.lefthalf.filled")
    }

    func testProgressOnlyUsesTwoColumnsWhenManadaWidthFits() {
        XCTAssertEqual(CoFleetProgressLayoutPolicy.columnCount(availableWidth: 863), 1)
        XCTAssertEqual(CoFleetProgressLayoutPolicy.columnCount(availableWidth: 864), 2)
    }

    func testProgressMasonryColumnsPreserveAlternatingOrder() {
        let columns = CoFleetProgressLayoutPolicy.columns(from: ["a", "b", "c", "d", "e"])
        XCTAssertEqual(columns.left, ["a", "c", "e"])
        XCTAssertEqual(columns.right, ["b", "d"])
    }

    func testProgressHeaderKeepsIdentityAndTodosSideBySideAtPhoneWidth() {
        let metrics = CoFleetProgressHeaderLayout.metrics(availableWidth: 340)

        XCTAssertTrue(metrics.isCompact)
        XCTAssertGreaterThanOrEqual(metrics.identityWidth, 150)
        XCTAssertGreaterThanOrEqual(metrics.detailWidth, 124)
        XCTAssertEqual(metrics.identityWidth + metrics.spacing + metrics.detailWidth, 340, accuracy: 0.001)
    }

    func testProgressTodoPreviewPrefersIncompleteItems() {
        let done = todo(id: "done", title: "Done", completed: true, sortIndex: 0)
        let next = todo(id: "next", title: "Next", completed: false, sortIndex: 3)
        let first = todo(id: "first", title: "First", completed: false, sortIndex: 1)

        XCTAssertEqual(
            CoFleetProgressTodoProjection.preview([done, next, first]).map(\.id),
            ["first", "next", "done"]
        )
    }

    func testProgressCombinesCodexAndActivityIntoOneBadge() {
        XCTAssertEqual(
            CoFleetProgressProviderBadgePolicy.activityLabel(
                activity: .idle,
                projectState: .idle,
                reachability: .online
            ),
            "Idle"
        )
        XCTAssertEqual(
            CoFleetProgressProviderBadgePolicy.activityLabel(
                activity: .thinking,
                projectState: .working,
                reachability: .online
            ),
            "Thinking"
        )
        XCTAssertEqual(
            CoFleetProgressProviderBadgePolicy.activityLabel(
                activity: .replied,
                projectState: .replied,
                reachability: .online
            ),
            "Replied"
        )
        XCTAssertEqual(
            CoFleetProgressProviderBadgePolicy.activityLabel(
                activity: .thinking,
                projectState: .working,
                reachability: .offline
            ),
            "Offline"
        )
    }

    func testActiveProgressPaneFitsOneFreshMessageCardWithoutTakingTheWholeScreen() {
        XCTAssertEqual(CoFleetActiveLayoutPolicy.progressHeight(availableHeight: 500), 340)
        XCTAssertEqual(CoFleetActiveLayoutPolicy.progressHeight(availableHeight: 800), 416)
        XCTAssertEqual(CoFleetActiveLayoutPolicy.progressHeight(availableHeight: 1_000), 420)
    }

    func testConversationHistoryStartsAtFortyAndLoadsFortyMore() {
        let ids = (0..<90).map(String.init)
        XCTAssertEqual(CoFleetConversationPaging.visibleItemIDs(ids, limit: 40), Array(ids.suffix(40)))
        XCTAssertEqual(CoFleetConversationPaging.nextLimit(current: 40, total: 90), 80)
        XCTAssertEqual(CoFleetConversationPaging.nextLimit(current: 80, total: 90), 90)
    }

    func testProgressUsesCanonicalCurrentTaskEvenWhenOutsideFirstPage() {
        let project = project(currentSessionID: "remembered-task")
        let sessions = [session(id: "newest-task", updatedAt: Date(timeIntervalSince1970: 20))]

        XCTAssertEqual(
            CoFleetProgressSessionPolicy.sessionID(
                for: project,
                activeSessionID: "open-task",
                sessions: sessions
            ),
            "remembered-task"
        )
    }

    func testProgressUsesOpenTaskBeforeFreshestHistoryTask() {
        XCTAssertEqual(
            CoFleetProgressSessionPolicy.sessionID(
                for: project(),
                activeSessionID: "open-task",
                sessions: [session(id: "newest-task", updatedAt: Date(timeIntervalSince1970: 20))]
            ),
            "open-task"
        )
    }

    func testProgressFallsBackToFreshestActualTaskIncludingCompletedTask() {
        let sessions = [
            session(id: "older-active", state: .active, updatedAt: Date(timeIntervalSince1970: 10)),
            session(id: "fresh-complete", state: .completed, updatedAt: Date(timeIntervalSince1970: 30)),
        ]

        XCTAssertEqual(
            CoFleetProgressSessionPolicy.sessionID(
                for: project(),
                activeSessionID: nil,
                sessions: sessions
            ),
            "fresh-complete"
        )
    }

    func testProgressDoesNotBorrowAnotherProjectsSessionOrSettings() {
        let other = CoFleetSessionSummary(
            id: "other",
            hostID: hostID,
            projectID: "other-project",
            title: "Other",
            updatedAt: Date(timeIntervalSince1970: 50),
            modelID: "other-model",
            accessLevel: .fullAccess
        )

        XCTAssertNil(
            CoFleetProgressSessionPolicy.sessionID(
                for: project(),
                activeSessionID: nil,
                sessions: [other]
            )
        )
        XCTAssertEqual(
            CoFleetProgressSessionPolicy.settings(for: "missing", sessions: [other]),
            CoFleetSessionSettings()
        )
    }

    func testRuntimeLabelReflectsEditedModelAndActualHostDefault() {
        let models = [
            CoFleetModelInfo(id: "gpt-default", displayName: "GPT Default", isDefault: true),
            CoFleetModelInfo(id: "gpt-edited", displayName: "GPT Edited"),
        ]

        XCTAssertEqual(
            CoFleetRuntimeLabelResolver.label(
                settings: CoFleetSessionSettings(modelID: nil),
                models: models
            ),
            "GPT Default · Default"
        )
        XCTAssertEqual(
            CoFleetRuntimeLabelResolver.label(
                settings: CoFleetSessionSettings(modelID: "gpt-edited", reasoningEffort: "xhigh"),
                models: models
            ),
            "GPT Edited · XHigh"
        )
    }

    func testReasoningSliderKeepsDefaultSeparateFromHostEffortStops() {
        let efforts = CoFleetReasoningSliderPolicy.efforts(
            supported: ["low", "medium", "high", "xhigh"],
            current: nil
        )

        XCTAssertEqual(efforts, ["low", "medium", "high", "xhigh"])
        XCTAssertEqual(CoFleetReasoningSliderPolicy.index(current: nil, efforts: efforts), 0)
        XCTAssertNil(CoFleetReasoningSliderPolicy.selection(at: 0, efforts: efforts))
        XCTAssertEqual(CoFleetReasoningSliderPolicy.selection(at: 1, efforts: efforts), "low")
        XCTAssertEqual(CoFleetReasoningSliderPolicy.selection(at: 4, efforts: efforts), "xhigh")
    }

    func testReasoningSliderRetainsCurrentHostValueAndDeduplicatesStops() {
        let efforts = CoFleetReasoningSliderPolicy.efforts(
            supported: ["low", "low", "high"],
            current: "ultra"
        )

        XCTAssertEqual(efforts, ["low", "high", "ultra"])
        XCTAssertEqual(CoFleetReasoningSliderPolicy.index(current: "ultra", efforts: efforts), 3)
        XCTAssertEqual(CoFleetReasoningSliderPolicy.displayName(nil), "Default")
        XCTAssertEqual(CoFleetReasoningSliderPolicy.displayName("xhigh"), "XHigh")
    }

    private func project(currentSessionID: String? = nil) -> CoFleetProject {
        CoFleetProject(
            id: "project",
            hostID: hostID,
            displayName: "Project",
            canonicalPath: "/tmp/project",
            currentSessionID: currentSessionID
        )
    }

    private func session(
        id: String,
        state: CoFleetSessionState = .completed,
        updatedAt: Date
    ) -> CoFleetSessionSummary {
        CoFleetSessionSummary(
            id: id,
            hostID: hostID,
            projectID: "project",
            title: id,
            state: state,
            updatedAt: updatedAt
        )
    }

    private func todo(
        id: String,
        title: String,
        completed: Bool,
        sortIndex: Int
    ) -> CoFleetTodoItem {
        CoFleetTodoItem(
            id: id,
            hostID: hostID,
            projectID: "project",
            title: title,
            isCompleted: completed,
            sortIndex: sortIndex
        )
    }
}
