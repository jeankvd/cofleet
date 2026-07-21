import CoFleetCore
import CoFleetTransport
import Foundation
import XCTest

final class WidgetSnapshotTests: XCTestCase {
    func testAutomaticModeAlternatesOnStableHalfHourBoundaries() {
        let evenBoundary = Date(timeIntervalSince1970: 4 * 30 * 60)
        let oddBoundary = Date(timeIntervalSince1970: 5 * 30 * 60)

        XCTAssertEqual(CoFleetWidgetMode.automatic.resolved(at: evenBoundary), .focusedMessage)
        XCTAssertEqual(CoFleetWidgetMode.automatic.resolved(at: oddBoundary), .threePets)
        XCTAssertEqual(CoFleetWidgetMode.focusedMessage.resolved(at: oddBoundary), .focusedMessage)
        XCTAssertEqual(CoFleetWidgetMode.threePets.resolved(at: evenBoundary), .threePets)
    }

    func testValidBoundedPreviewRoundTripsInSnapshot() throws {
        let preview = validPreview(petID: "pet-sample")
        let snapshot = CoFleetWatchSnapshot(
            generatedAt: Date(timeIntervalSince1970: 0),
            projects: [project(
                id: "project-sample",
                petID: preview.petID,
                preview: preview
            )]
        )

        let encoded = try CoFleetWatchRelayCodec.encode(.init(snapshot: snapshot))
        let decoded = try CoFleetWatchRelayCodec.decode(encoded)

        XCTAssertEqual(decoded.snapshot, snapshot)
        XCTAssertLessThan(encoded.count, CoFleetWatchRelayCodec.maximumPayloadBytes)
    }

    func testPreviewRejectsOversizedDataAndDimensionMismatch() {
        let oversized = CoFleetPetPreview(
            petID: "pet-sample",
            pixelWidth: 1,
            pixelHeight: 1,
            digest: String(repeating: "a", count: 64),
            data: Data(repeating: 0, count: CoFleetPetPreview.maximumByteCount + 1)
        )
        XCTAssertThrowsError(try CoFleetWatchRelayCodec.validate(oversized)) {
            XCTAssertEqual($0 as? CoFleetWatchRelayValidationError, .invalidPetPreview)
        }

        var mismatched = validPreview(petID: "pet-sample")
        mismatched.pixelWidth = 2
        XCTAssertThrowsError(try CoFleetWatchRelayCodec.validate(mismatched)) {
            XCTAssertEqual($0 as? CoFleetWatchRelayValidationError, .invalidPetPreview)
        }
    }

    func testSnapshotRejectsMoreThanThreePetPreviews() {
        let projects = (0...CoFleetWatchRelayCodec.maximumPetPreviews).map { index in
            let petID = "pet-\(index)"
            return project(id: "project-\(index)", petID: petID, preview: validPreview(petID: petID))
        }
        XCTAssertThrowsError(try CoFleetWatchRelayCodec.validate(CoFleetWatchSnapshot(projects: projects))) {
            XCTAssertEqual($0 as? CoFleetWatchRelayValidationError, .snapshotTooLarge)
        }
    }

    func testSnapshotRejectsPreviewNotBoundToSelectedPet() {
        let snapshot = CoFleetWatchSnapshot(projects: [project(
            id: "project-sample",
            petID: "pet-selected",
            preview: validPreview(petID: "pet-other")
        )])
        XCTAssertThrowsError(try CoFleetWatchRelayCodec.validate(snapshot)) {
            XCTAssertEqual($0 as? CoFleetWatchRelayValidationError, .invalidPetPreview)
        }
    }

    private func project(
        id: String,
        petID: String,
        preview: CoFleetPetPreview
    ) -> CoFleetWatchProjectSnapshot {
        CoFleetWatchProjectSnapshot(
            id: id,
            hostID: .init(rawValue: "sample-host"),
            name: "Sample Project",
            hostReachability: .online,
            action: .idle,
            selectedPetID: petID,
            petPreview: preview
        )
    }

    private func validPreview(petID: String) -> CoFleetPetPreview {
        // A transparent 1 x 1 PNG used only to exercise bounded snapshot decoding.
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        )!
        return CoFleetPetPreview(
            petID: petID,
            pixelWidth: 1,
            pixelHeight: 1,
            digest: String(repeating: "a", count: 64),
            data: png
        )
    }
}
