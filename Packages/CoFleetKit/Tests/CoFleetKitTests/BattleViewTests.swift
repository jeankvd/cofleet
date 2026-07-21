import SceneKit
import XCTest
import CoFleetCore
@testable import CoFleetUI

@MainActor
final class BattleViewTests: XCTestCase {
    private let hostID = CoFleetHostID(rawValue: "host")

    func testBattleOnboardingRequiresAProjectAndTwoTodos() {
        XCTAssertEqual(
            CoFleetBattleOnboardingPolicy.readiness(
                projects: [],
                preferredProjectID: nil,
                todosByProjectID: [:]
            ),
            .noProject
        )

        let project = project(id: "alpha")
        XCTAssertEqual(
            CoFleetBattleOnboardingPolicy.readiness(
                projects: [project],
                preferredProjectID: project.id,
                todosByProjectID: [project.id: [todo(id: "one")]]
            ),
            .needsTodos(projectID: project.id, projectName: project.displayName, count: 1)
        )

        XCTAssertEqual(
            CoFleetBattleOnboardingPolicy.readiness(
                projects: [project],
                preferredProjectID: project.id,
                todosByProjectID: [project.id: [todo(id: "one"), todo(id: "two")]]
            ),
            .ready(projectID: project.id)
        )
    }

    func testBattleOnboardingWaitsForTodoCatalog() {
        let project = project(id: "alpha")
        XCTAssertEqual(
            CoFleetBattleOnboardingPolicy.readiness(
                projects: [project],
                preferredProjectID: project.id,
                todosByProjectID: [:]
            ),
            .loading
        )
    }
    func testPlaybackStopsRendererWhenBattleIsNotVisible() {
        let quality = CoFleetBattleSceneQualityProfile.desktop

        XCTAssertEqual(
            CoFleetBattleScenePlaybackState.resolve(isActive: false, quality: quality),
            CoFleetBattleScenePlaybackState(isPlaying: false, rendersContinuously: false)
        )
        XCTAssertEqual(
            CoFleetBattleScenePlaybackState.resolve(isActive: true, quality: quality),
            CoFleetBattleScenePlaybackState(isPlaying: true, rendersContinuously: true)
        )
    }

    func testLowPowerMobileProfileDisablesExpensiveEffects() {
        let quality = CoFleetBattleSceneQualityProfile.mobile(isLowPowerModeEnabled: true)

        XCTAssertEqual(quality.preferredFramesPerSecond, 24)
        XCTAssertFalse(quality.rendersContinuously)
        XCTAssertFalse(quality.isJitteringEnabled)
        XCTAssertFalse(quality.wantsDepthOfField)
        XCTAssertEqual(quality.shadowMapSize, 512)
    }

    func testBattleKeepsTheWorkingManadaCameraSemantics() {
        let camera = CoFleetBattleCameraConfiguration.manada

        XCTAssertEqual(camera.focalLength, 50)
        XCTAssertEqual(camera.sensorHeight, 24)
        XCTAssertEqual(camera.position.x, 0)
        XCTAssertEqual(camera.position.y, 9.2)
        XCTAssertEqual(camera.position.z, 12.2)
        XCTAssertEqual(camera.target.x, 0)
        XCTAssertEqual(camera.target.y, 0.1)
        XCTAssertEqual(camera.target.z, -1.4)
    }

    func testPetBillboardKeepsSpriteTransformSeparateAndShadowEnabled() {
        let sprite = SCNNode(geometry: SCNPlane(width: 1, height: 1))
        sprite.scale.x = -1
        sprite.castsShadow = true

        let billboard = CoFleetBattlePetBillboard.makeContainer(for: sprite)

        XCTAssertEqual(billboard.childNodes, [sprite])
        XCTAssertEqual(sprite.scale.x, -1)
        XCTAssertTrue(sprite.castsShadow)
        XCTAssertTrue(billboard.constraints?.first is SCNBillboardConstraint)
    }

    func testHUDShadowPolicyDoesNotDisablePetShadow() {
        let pet = SCNNode()
        pet.castsShadow = true
        let hud = SCNNode()
        let label = SCNNode(geometry: SCNText(string: "READY", extrusionDepth: 0))
        label.castsShadow = true
        hud.addChildNode(label)
        pet.addChildNode(hud)

        CoFleetBattleHUDShadowPolicy.disableShadows(in: hud)

        XCTAssertTrue(pet.castsShadow)
        XCTAssertFalse(hud.castsShadow)
        XCTAssertFalse(label.castsShadow)
    }

    func testAttackTriggersOnlyWhenRenderedPartyMemberTransitionsToReplied() {
        let oldParty = [
            CoFleetBattlePartyState(projectID: "one", state: .working),
            CoFleetBattlePartyState(projectID: "two", state: .idle),
            CoFleetBattlePartyState(projectID: "three", state: .working),
        ]
        let newParty = [
            CoFleetBattlePartyState(projectID: "one", state: .replied),
            CoFleetBattlePartyState(projectID: "two", state: .idle),
            CoFleetBattlePartyState(projectID: "three", state: .working),
        ]

        XCTAssertEqual(
            CoFleetBattlePartyState.firstReplyTransition(from: oldParty, to: newParty),
            "one"
        )
    }

    func testAttackDoesNotReplayForExistingReplyOrNewlyRenderedMember() {
        let oldParty = [
            CoFleetBattlePartyState(projectID: "one", state: .replied),
            CoFleetBattlePartyState(projectID: "two", state: .working),
        ]
        let existingReply = [
            CoFleetBattlePartyState(projectID: "one", state: .replied),
            CoFleetBattlePartyState(projectID: "two", state: .idle),
        ]
        let newlyRenderedReply = existingReply + [
            CoFleetBattlePartyState(projectID: "three", state: .replied),
        ]

        XCTAssertNil(CoFleetBattlePartyState.firstReplyTransition(from: oldParty, to: existingReply))
        XCTAssertNil(CoFleetBattlePartyState.firstReplyTransition(from: existingReply, to: newlyRenderedReply))
    }

    private func project(id: String) -> CoFleetProject {
        CoFleetProject(
            id: id,
            hostID: hostID,
            displayName: id.capitalized,
            canonicalPath: "/tmp/\(id)"
        )
    }

    private func todo(id: String) -> CoFleetTodoItem {
        CoFleetTodoItem(id: id, hostID: hostID, projectID: "alpha", title: id.capitalized)
    }
}
