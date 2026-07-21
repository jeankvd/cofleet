import CoreGraphics
import XCTest
import CoFleetCore
@testable import CoFleetUI

final class WatchPresentationPolicyTests: XCTestCase {
    func testRoundedDisplayInsetUsesWatchEdgeAllowance() {
        XCTAssertEqual(CoFleetWatchPresentationPolicy.roundedDisplayInset(for: 198), 4)
        XCTAssertEqual(CoFleetWatchPresentationPolicy.roundedDisplayInset(for: 300), 6)
    }

    func testSwipeBackMustBeginAtTheLeadingEdgeAndMoveMostlyHorizontally() {
        XCTAssertTrue(CoFleetWatchPresentationPolicy.shouldDismiss(
            startX: 12,
            translation: CGSize(width: 52, height: 8)
        ))
        XCTAssertFalse(CoFleetWatchPresentationPolicy.shouldDismiss(
            startX: 31,
            translation: CGSize(width: 52, height: 8)
        ))
        XCTAssertFalse(CoFleetWatchPresentationPolicy.shouldDismiss(
            startX: 12,
            translation: CGSize(width: 43, height: 8)
        ))
        XCTAssertFalse(CoFleetWatchPresentationPolicy.shouldDismiss(
            startX: 12,
            translation: CGSize(width: 52, height: 56)
        ))
    }

    func testActiveCodexStatesAndLocalRelayTurnShowThinkingRow() {
        XCTAssertTrue(CoFleetWatchPresentationPolicy.showsActivity(
            action: .working,
            hasLocallyPendingTurn: false
        ))
        XCTAssertTrue(CoFleetWatchPresentationPolicy.showsActivity(
            action: .idle,
            hasLocallyPendingTurn: true
        ))
        XCTAssertFalse(CoFleetWatchPresentationPolicy.showsActivity(
            action: .replied,
            hasLocallyPendingTurn: false
        ))
    }

    func testLatestPreviewIsTrimmedAndDeduplicatedBeforeAppending() {
        XCTAssertTrue(CoFleetWatchPresentationPolicy.shouldAppendLatest(
            existingLastText: "Earlier reply",
            latestText: " Fresh reply \n"
        ))
        XCTAssertFalse(CoFleetWatchPresentationPolicy.shouldAppendLatest(
            existingLastText: "Fresh reply",
            latestText: " Fresh reply \n"
        ))
        XCTAssertFalse(CoFleetWatchPresentationPolicy.shouldAppendLatest(
            existingLastText: nil,
            latestText: "  \n"
        ))
    }

    func testProjectStateMapsToSpecificWatchInteractionIndicators() {
        XCTAssertEqual(CoFleetWatchPresentationPolicy.action(for: CoFleetProjectState.idle), .idle)
        XCTAssertEqual(CoFleetWatchPresentationPolicy.action(for: CoFleetProjectState.working), .working)
        XCTAssertEqual(CoFleetWatchPresentationPolicy.action(for: CoFleetProjectState.waitingForApproval), .approvalNeeded)
        XCTAssertEqual(CoFleetWatchPresentationPolicy.action(for: CoFleetProjectState.waitingForAnswer), .questionAsked)
        XCTAssertEqual(CoFleetWatchPresentationPolicy.action(for: CoFleetProjectState.replied), .replied)
    }

    func testProjectedActivityKeepsDetailedWatchStates() {
        XCTAssertEqual(CoFleetWatchPresentationPolicy.action(for: CoFleetProjectActivity.thinking), .thinking)
        XCTAssertEqual(CoFleetWatchPresentationPolicy.action(for: CoFleetProjectActivity.reasoning), .reasoning)
        XCTAssertEqual(CoFleetWatchPresentationPolicy.action(for: CoFleetProjectActivity.runningCommand), .runningCommand)
        XCTAssertEqual(CoFleetWatchPresentationPolicy.action(for: CoFleetProjectActivity.approval), .approvalNeeded)
        XCTAssertEqual(CoFleetWatchPresentationPolicy.action(for: CoFleetProjectActivity.question), .questionAsked)
        XCTAssertEqual(CoFleetWatchPresentationPolicy.action(for: CoFleetProjectActivity.replied), .replied)
    }

    func testSnapshotPublicationIgnoresTimestampOnlyChanges() {
        let project = CoFleetWatchProjectSnapshot(
            id: "project-sample",
            hostID: .init(rawValue: "sample-host"),
            sessionID: "session-sample",
            name: "Sample",
            hostReachability: .online,
            action: .thinking,
            latestMessage: "Working"
        )
        let previous = CoFleetWatchSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1),
            projects: [project],
            focusedProjectID: project.id
        )
        let timestampOnly = CoFleetWatchSnapshot(
            generatedAt: Date(timeIntervalSince1970: 2),
            projects: [project],
            focusedProjectID: project.id
        )
        XCTAssertFalse(CoFleetWatchPresentationPolicy.snapshotContentChanged(
            from: previous,
            to: timestampOnly
        ))

        var replied = timestampOnly
        replied.projects[0].action = .replied
        replied.projects[0].latestMessage = "Finished"
        XCTAssertTrue(CoFleetWatchPresentationPolicy.snapshotContentChanged(
            from: previous,
            to: replied
        ))
    }

    func testOnlyInflightOrNewerDeliveriesOverrideHostSnapshot() {
        let snapshotDate = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(CoFleetWatchPresentationPolicy.shouldReapplyDelivery(
            state: .running,
            deliveryUpdatedAt: Date(timeIntervalSince1970: 50),
            snapshotGeneratedAt: snapshotDate
        ))
        XCTAssertTrue(CoFleetWatchPresentationPolicy.shouldReapplyDelivery(
            state: .completed,
            deliveryUpdatedAt: Date(timeIntervalSince1970: 101),
            snapshotGeneratedAt: snapshotDate
        ))
        XCTAssertFalse(CoFleetWatchPresentationPolicy.shouldReapplyDelivery(
            state: .notified,
            deliveryUpdatedAt: Date(timeIntervalSince1970: 99),
            snapshotGeneratedAt: snapshotDate
        ))
    }

    func testReplyAlertRequiresAnObservedActiveToNewReplyTransition() {
        let active = CoFleetWatchProjectSnapshot(
            id: "project-sample",
            sessionID: "session-sample",
            name: "Sample",
            hostReachability: .online,
            action: .reasoning,
            latestMessage: "Earlier reply"
        )
        var replied = active
        replied.action = .replied
        replied.latestMessage = "Fresh reply"

        XCTAssertTrue(CoFleetWatchPresentationPolicy.shouldNotifyReply(
            previous: active,
            current: replied
        ))
        XCTAssertFalse(CoFleetWatchPresentationPolicy.shouldNotifyReply(
            previous: nil,
            current: replied
        ))

        var unchanged = replied
        unchanged.latestMessage = active.latestMessage
        XCTAssertTrue(CoFleetWatchPresentationPolicy.shouldNotifyReply(
            previous: active,
            current: unchanged
        ))
    }
}
