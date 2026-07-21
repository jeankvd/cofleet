import CoFleetCore
import CoreGraphics
import Foundation
import XCTest
@testable import CoFleetUI

final class PetFeatureTests: XCTestCase {
    private let hostID = CoFleetHostID(rawValue: "sample-host")

    func testManifestAcceptsExactV1AndV2AtlasContracts() throws {
        let v1 = manifest(version: 1, rows: 9, suffix: "1")
        let v2 = manifest(version: 2, rows: 11, suffix: "2")
        XCTAssertNoThrow(try CoFleetPetManifestValidator.validate(v1))
        XCTAssertNoThrow(try CoFleetPetManifestValidator.validate(v2))
        XCTAssertEqual(v1.pixelHeight, 1_872)
        XCTAssertEqual(v2.pixelHeight, 2_288)
    }

    func testManifestRejectsVersionDimensionMismatchAndNonCanonicalAsset() {
        var wrongRows = manifest(version: 2, rows: 9, suffix: "1")
        XCTAssertThrowsError(try CoFleetPetManifestValidator.validate(wrongRows)) {
            XCTAssertEqual($0 as? CoFleetPetManifestError, .invalidDimensions)
        }
        wrongRows.rows = 11
        wrongRows.spritesheetPath = "folder/spritesheet.webp"
        XCTAssertThrowsError(try CoFleetPetManifestValidator.validate(wrongRows)) {
            XCTAssertEqual(
                $0 as? CoFleetPetManifestError,
                .unsafeAssetPath("folder/spritesheet.webp")
            )
        }
    }

    func testPetAssetsEnforceNonEmptyBoundedPayloads() throws {
        XCTAssertThrowsError(try CoFleetPetAsset(
            hostID: hostID,
            petID: "sample-pet",
            assetName: "spritesheet.webp",
            mediaType: "image/webp",
            data: Data()
        )) {
            XCTAssertEqual($0 as? CoFleetPetManifestError, .assetSize)
        }
        XCTAssertNoThrow(try CoFleetPetAsset(
            hostID: hostID,
            petID: "sample-pet",
            assetName: "spritesheet.webp",
            mediaType: "image/webp",
            data: Data([0x01])
        ))
    }

    func testAtlasIdentityIsStableAndRejectsCrossPetReuse() throws {
        let manifest = manifest(version: 2, rows: 11, suffix: "a")
        let asset = try CoFleetPetAsset(
            hostID: hostID,
            petID: manifest.id,
            assetName: manifest.spritesheetPath,
            mediaType: "image/webp",
            data: Data([0x01, 0x02, 0x03])
        )

        XCTAssertEqual(
            CoFleetPetSpriteView.atlasIdentity(manifest: manifest, asset: asset),
            "\(manifest.canonicalIdentity):\(manifest.digest):3"
        )

        var otherPet = manifest
        otherPet.id = "another-pet"
        XCTAssertNil(CoFleetPetSpriteView.atlasIdentity(manifest: otherPet, asset: asset))

        var otherSheet = manifest
        otherSheet.spritesheetPath = "spritesheet.png"
        XCTAssertNil(CoFleetPetSpriteView.atlasIdentity(manifest: otherSheet, asset: asset))
    }

    func testAnimationSkipsTransparentTrailingAtlasCell() throws {
        let pixels: [UInt8] = [
            255, 0, 0, 255,
            0, 255, 0, 255,
            0, 0, 0, 0,
        ]
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 3,
            height: 1,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 12,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let manifest = CoFleetPetManifest(
            hostID: hostID,
            id: "tiny",
            displayName: "Tiny",
            spriteVersionNumber: 2,
            spritesheetPath: "spritesheet.png",
            frameWidth: 1,
            frameHeight: 1,
            columns: 3,
            rows: 1,
            digest: String(repeating: "a", count: 64)
        )

        XCTAssertEqual(
            CoFleetPetFramePolicy.visibleColumns(in: image, manifest: manifest, row: 0),
            [0, 1]
        )
    }

    func testPetHatchUsesTheRealSkillAndFindsOnlyNewHostPackages() {
        XCTAssertTrue(CoFleetPendingPetHatch.codexPrompt.contains("$hatch-pet"))
        XCTAssertTrue(CoFleetPendingPetHatch.codexPrompt.contains("visual QA"))
        XCTAssertTrue(CoFleetPendingPetHatch.codexPrompt.contains("~/.codex/pets/<pet-id>/"))

        let hatch = CoFleetPendingPetHatch(
            hostID: hostID,
            projectID: "project-sample",
            sessionID: "session-hatch",
            baselineDigests: ["existing"]
        )
        let existing = CoFleetDiscoveredPet(
            hostID: hostID,
            sourcePath: "/tmp/cofleet-fixtures/pets/existing/pet.json",
            displayName: "Existing",
            spriteVersionNumber: 2,
            digest: "existing"
        )
        let fresh = CoFleetDiscoveredPet(
            hostID: hostID,
            sourcePath: "/tmp/cofleet-fixtures/pets/fresh/pet.json",
            displayName: "Fresh",
            spriteVersionNumber: 2,
            digest: "fresh"
        )
        let otherHost = CoFleetDiscoveredPet(
            hostID: CoFleetHostID(rawValue: "other-host"),
            sourcePath: "/tmp/cofleet-fixtures/other-host/pets/fresh/pet.json",
            displayName: "Other",
            spriteVersionNumber: 2,
            digest: "other"
        )

        XCTAssertEqual(hatch.newlyDiscoveredPets(in: [existing, fresh, otherHost]), [fresh])
    }

    func testPetHatchReadsReadyPackageOnlyFromAssistantMessages() {
        let hatch = CoFleetPendingPetHatch(
            hostID: hostID,
            projectID: "project-sample",
            sessionID: "session-hatch",
            baselineDigests: []
        )
        let items = [
            CoFleetTurnItem(
                id: "user",
                turnID: "turn",
                kind: .userMessage,
                text: "COFLEET_PET_READY=/tmp/not-this-one"
            ),
            CoFleetTurnItem(
                id: "assistant",
                turnID: "turn",
                kind: .assistantMessage,
                text: "Finished.\nCOFLEET_PET_READY=/Users/sample/.codex/pets/fresh"
            ),
        ]

        XCTAssertEqual(
            hatch.readyPackagePath(in: items),
            "/Users/sample/.codex/pets/fresh"
        )
    }

    @MainActor
    func testWorkspaceLoadsOnlyTheSelectedPetAsset() async {
        let repository = PetWorkspaceRepositoryFake(hostID: hostID)
        let store = WorkspaceStore(repository: repository)
        await store.open(hostID: hostID, projectID: "project-sample", selectedPetID: nil)
        XCTAssertEqual(store.pets.count, 1)
        XCTAssertNil(store.selectedPetAsset)
        let requestsBeforeSelection = await repository.assetRequests()
        XCTAssertEqual(requestsBeforeSelection, [])

        let updated = try? await store.selectPet(id: "pet_sample")
        XCTAssertEqual(updated?.selectedPetID, "pet_sample")
        XCTAssertEqual(store.selectedPetAsset?.petID, "pet_sample")
        let requestsAfterSelection = await repository.assetRequests()
        XCTAssertEqual(requestsAfterSelection, ["pet_sample"])

        await store.loadSelectedPetAsset()
        let requestsAfterReload = await repository.assetRequests()
        XCTAssertEqual(requestsAfterReload, ["pet_sample"], "The selected atlas is cached.")
    }

    @MainActor
    func testWorkspaceDiscoversAndImportsHostPetPackage() async throws {
        let repository = PetWorkspaceRepositoryFake(hostID: hostID)
        let store = WorkspaceStore(repository: repository)
        await store.open(hostID: hostID, projectID: "project-sample")
        try await store.discoverPets()
        XCTAssertEqual(store.discoveredPets.map(\.sourcePath), ["/Users/sample/.codex/pets/sample/pet.json"])

        let imported = try await store.importPet(
            sourcePath: "/Users/sample/.codex/pets/sample/pet.json"
        )
        XCTAssertEqual(imported?.id, "pet_sample")
        XCTAssertTrue(store.discoveredPets.isEmpty)
    }

    private func manifest(version: Int, rows: Int, suffix: Character) -> CoFleetPetManifest {
        CoFleetPetManifest(
            hostID: hostID,
            id: "sample-pet-\(suffix)",
            displayName: "Sample Pet",
            spriteVersionNumber: version,
            spritesheetPath: "spritesheet.webp",
            rows: rows,
            digest: String(repeating: suffix, count: 64)
        )
    }
}

private actor PetWorkspaceRepositoryFake: CoFleetWorkspaceRepository {
    private let hostID: CoFleetHostID
    private var requestedAssets: [String] = []
    private var imported = false

    init(hostID: CoFleetHostID) {
        self.hostID = hostID
    }

    func fetchNote(hostID: CoFleetHostID, projectID: String, sessionID: String?) async throws -> CoFleetNote {
        CoFleetNote(hostID: hostID, projectID: projectID, sessionID: sessionID)
    }

    func saveNote(_ note: CoFleetNote, expectedETag: String) async throws -> CoFleetNoteSaveResult {
        .saved(note)
    }

    func fetchTodos(hostID: CoFleetHostID, projectID: String) async throws -> [CoFleetTodoItem] { [] }

    func saveTodo(_ todo: CoFleetTodoItem, expectedETag: String?) async throws -> CoFleetTodoItem { todo }

    func deleteTodo(hostID: CoFleetHostID, id: String, expectedETag: String) async throws {}

    func fetchPets(hostID: CoFleetHostID) async throws -> [CoFleetPetManifest] {
        imported ? [manifest] : [manifest]
    }

    func discoverPets(hostID: CoFleetHostID) async throws -> [CoFleetDiscoveredPet] {
        guard !imported else { return [] }
        return [CoFleetDiscoveredPet(
            hostID: hostID,
            sourcePath: "/Users/sample/.codex/pets/sample/pet.json",
            displayName: "Sample Pet",
            spriteVersionNumber: 2,
            digest: String(repeating: "a", count: 64)
        )]
    }

    func importPet(hostID: CoFleetHostID, sourcePath: String) async throws -> CoFleetPetManifest {
        imported = true
        return manifest
    }

    func selectPet(hostID: CoFleetHostID, projectID: String, petID: String) async throws -> CoFleetProject {
        CoFleetProject(
            id: projectID,
            hostID: hostID,
            displayName: "Sample Project",
            canonicalPath: "/Users/sample/Project",
            selectedPetID: petID
        )
    }

    func fetchPetAsset(
        hostID: CoFleetHostID,
        petID: String,
        assetName: String
    ) async throws -> CoFleetPetAsset {
        requestedAssets.append(petID)
        return try CoFleetPetAsset(
            hostID: hostID,
            petID: petID,
            assetName: assetName,
            mediaType: "image/webp",
            data: Data([0x01])
        )
    }

    func assetRequests() -> [String] { requestedAssets }

    private var manifest: CoFleetPetManifest {
        CoFleetPetManifest(
            hostID: hostID,
            id: "pet_sample",
            displayName: "Sample Pet",
            spriteVersionNumber: 2,
            spritesheetPath: "spritesheet.webp",
            rows: 11,
            digest: String(repeating: "a", count: 64)
        )
    }
}
