import CoFleetCodex
@testable import CoFleetCore
@testable import CoFleetTransport
import CoFleetUI
import Foundation
import XCTest

final class CoreAndTransportTests: XCTestCase {
    func testProjectIdentityIsHostScoped() {
        let id = "project-sample"
        let project = CoFleetProject(
            id: id,
            hostID: .init(rawValue: "sample-host"),
            displayName: "Sample Project",
            canonicalPath: "/Users/sample/Project"
        )
        XCTAssertEqual(project.canonicalIdentity, "sample-host:/Users/sample/Project")
    }

    func testAccessMappingsMatchCodexProfiles() {
        XCTAssertEqual(
            CoFleetAccessLevel.askForApproval.codexPermissionProfile,
            .init(sandbox: .workspaceWrite, approvalPolicy: .untrusted, reviewMode: .user)
        )
        XCTAssertEqual(
            CoFleetAccessLevel.approveForMe.codexPermissionProfile,
            .init(sandbox: .workspaceWrite, approvalPolicy: .onRequest, reviewMode: .automatic)
        )
        XCTAssertEqual(
            CoFleetAccessLevel.fullAccess.codexPermissionProfile,
            .init(sandbox: .dangerFullAccess, approvalPolicy: .never, reviewMode: .user)
        )
    }

    func testSessionPageEnforcesFiveItems() {
        let host = CoFleetHostID(rawValue: "sample-host")
        let project = "project-sample"
        let sessions = (0..<9).map {
            CoFleetSessionSummary(id: "session-\($0)", hostID: host, projectID: project, title: "Session \($0)")
        }
        XCTAssertEqual(CoFleetSessionPage(items: sessions, nextCursor: "next").items.count, 5)
    }

    func testSSEParserHandlesChunksAndMultilineData() throws {
        var parser = CoFleetSSEParser()
        XCTAssertTrue(try parser.feed(Data("id: 9\nevent: turn\ndata: first".utf8)).isEmpty)
        let events = try parser.feed(Data("\ndata: second\n\n".utf8))
        XCTAssertEqual(events, [CoFleetSSEEvent(id: "9", name: "turn", data: "first\nsecond")])
    }

    func testProviderNeutralSSEDecodesTurnItemsAndInteractions() throws {
        let turnData = #"{"type":"turn.updated","turn":{"id":"turn-1","hostID":"sample-host","sessionID":"thread-1","state":"running","startedAt":"2026-07-20T12:00:00Z"}}"#
        let turn = try CoFleetTurnEventDecoder().decode(
            .init(id: "40", name: "turn.updated", data: turnData)
        )
        guard case let .turn(model) = turn.event else {
            return XCTFail("Expected a turn event")
        }
        XCTAssertEqual(turn.id, "40")
        XCTAssertEqual(model.hostID.rawValue, "sample-host")
        XCTAssertEqual(model.sessionID, "thread-1")

        let interactionData = #"{"type":"interaction.pending","interaction":{"id":"interaction-1","hostID":"sample-host","sessionID":"thread-1","turnID":"turn-1","kind":"question","state":"pending","title":"Codex has a question","detail":"Answer 2 questions.","choices":["submitAnswer"],"questions":[{"id":"target","header":"Target","prompt":"Which target?","options":[{"label":"Device","detail":"Use a device."}],"allowsFreeform":false,"isSecret":false},{"id":"note","header":"Note","prompt":"Anything else?","options":[],"allowsFreeform":true,"isSecret":false}],"expiresAt":"2026-07-20T12:05:00Z"}}"#
        let interaction = try CoFleetTurnEventDecoder().decode(
            .init(id: "41", name: "interaction.pending", data: interactionData)
        )
        guard case let .interaction(model) = interaction.event else {
            return XCTFail("Expected an interaction event")
        }
        XCTAssertEqual(model.questions.map(\.id), ["target", "note"])
        XCTAssertEqual(model.questions[0].options.first?.label, "Device")
        XCTAssertTrue(model.questions[1].allowsFreeform)
    }

    func testStartTurnRequestEncodesProviderNeutralMixedInput() throws {
        let request = StartTurnRequest(
            projectID: "project-sample",
            input: [
                .text("Compare these images."),
                .imageURL(URL(string: "https://example.com/reference.png")!),
                .localImage(path: "/tmp/sample/current.png"),
            ],
            settings: .init(
                modelID: "gpt-sample",
                reasoningEffort: "high",
                serviceTier: "priority",
                accessLevel: .approveForMe
            )
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["projectID"] as? String, "project-sample")
        XCTAssertEqual(object["model"] as? String, "gpt-sample")
        XCTAssertEqual(object["reasoningEffort"] as? String, "high")
        XCTAssertEqual(object["serviceTier"] as? String, "priority")
        XCTAssertEqual(object["accessLevel"] as? String, "approve_for_me")
        let input = try XCTUnwrap(object["input"] as? [[String: String]])
        XCTAssertEqual(input, [
            ["type": "text", "text": "Compare these images."],
            ["type": "image", "url": "https://example.com/reference.png"],
            ["type": "localImage", "path": "/tmp/sample/current.png"],
        ])
    }

    func testAttachmentFactoriesEnforceURLAndProjectRootSafety() throws {
        XCTAssertThrowsError(
            try CoFleetTurnAttachment.imageURL(URL(string: "file:///tmp/image.png")!)
        ) { error in
            XCTAssertEqual(error as? CoFleetTurnAttachmentError, .invalidImageURL)
        }

        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("cofleet-attachment-\(UUID().uuidString)", isDirectory: true)
        let projectRoot = temporaryRoot.appendingPathComponent("project", isDirectory: true)
        let outsideRoot = temporaryRoot.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outsideRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryRoot) }
        let insideImage = projectRoot.appendingPathComponent("inside.png")
        let outsideImage = outsideRoot.appendingPathComponent("outside.png")
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: insideImage)
        try Data([0x89, 0x50, 0x4e, 0x47]).write(to: outsideImage)

        let attachment = try CoFleetTurnAttachment.localImage(
            insideImage,
            insideProjectRoot: projectRoot
        )
        XCTAssertEqual(attachment.source, .localImage(path: insideImage.path))
        XCTAssertEqual(attachment.byteCount, 4)
        XCTAssertThrowsError(
            try CoFleetTurnAttachment.localImage(outsideImage, insideProjectRoot: projectRoot)
        ) { error in
            XCTAssertEqual(error as? CoFleetTurnAttachmentError, .outsideProjectRoot)
        }
    }

    func testUnknownSSEBecomesReconnectCheckpointWithoutDecodingPayload() throws {
        let decoded = try CoFleetTurnEventDecoder().decode(
            .init(id: "77", name: "future.event", data: "not-json-and-provider-private")
        )
        XCTAssertEqual(decoded.id, "77")
        XCTAssertEqual(decoded.event, .checkpoint)
    }

    func testHostProjectionFixtureDecodesAsCanonicalSwiftItem() throws {
        let url = try XCTUnwrap(
            Bundle.module.url(
                forResource: "codex-item-started-projection",
                withExtension: "json",
                subdirectory: "Fixtures"
            )
        )
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        let id = try XCTUnwrap(object["id"] as? String)
        let name = try XCTUnwrap(object["event"] as? String)
        let data = try JSONSerialization.data(withJSONObject: try XCTUnwrap(object["data"]))
        let decoded = try CoFleetTurnEventDecoder().decode(
            .init(id: id, name: name, data: String(decoding: data, as: UTF8.self))
        )
        guard case let .upsertItem(item) = decoded.event else {
            return XCTFail("Expected the projected item fixture")
        }
        XCTAssertEqual(decoded.id, "101")
        XCTAssertEqual(item.id, "message-sample")
        XCTAssertEqual(item.kind, .assistantMessage)
        XCTAssertEqual(item.state, .streaming)
        XCTAssertEqual(item.text, "Hello from Codex.")
    }

    func testHostIDUsesStringWireFormatAndReadsLegacyStorage() throws {
        let id = CoFleetHostID(rawValue: "sample-host")
        XCTAssertEqual(String(data: try JSONEncoder().encode(id), encoding: .utf8), #""sample-host""#)
        XCTAssertEqual(
            try JSONDecoder().decode(CoFleetHostID.self, from: Data(#"{"rawValue":"legacy-host"}"#.utf8)),
            CoFleetHostID(rawValue: "legacy-host")
        )
    }

    func testStoredHostPairingMigratesRecordWithoutDeviceID() throws {
        let data = Data(#"{"host":{"id":"sample-host","displayName":"Sample Mac","platform":"macOS","canonicalHome":"/Users/sample","reachability":"online","capabilities":{"canBrowseDirectories":true,"canCreateDirectories":true,"canImportPets":true,"supportsPlasticSCM":false},"lastSeenAt":null},"endpoint":"https://sample.tailnet.ts.net"}"#.utf8)
        let record = try JSONDecoder().decode(CoFleetStoredHostPairing.self, from: data)

        XCTAssertEqual(record.host.id.rawValue, "sample-host")
        XCTAssertEqual(record.endpoint.absoluteString, "https://sample.tailnet.ts.net")
        XCTAssertNil(record.deviceID)
    }

    func testSSEParserAcceptsExactLineAndEventLimits() throws {
        var parser = CoFleetSSEParser(maximumLineBytes: 7, maximumEventBytes: 8)
        let events = try parser.feed(Data("data: a\n\n".utf8))
        XCTAssertEqual(events, [CoFleetSSEEvent(data: "a")])
    }

    func testSSEParserRejectsOversizedLineAcrossChunks() throws {
        var parser = CoFleetSSEParser(maximumLineBytes: 8, maximumEventBytes: 64)
        XCTAssertTrue(try parser.feed(Data("data: 12".utf8)).isEmpty)

        XCTAssertThrowsError(try parser.feed(Data("3".utf8))) { error in
            XCTAssertEqual(
                error as? CoFleetTransportLimitError,
                .sseLineTooLarge(maxBytes: 8)
            )
        }
    }

    func testSSEParserRejectsOversizedEventAcrossSmallLines() throws {
        var parser = CoFleetSSEParser(maximumLineBytes: 32, maximumEventBytes: 15)
        XCTAssertTrue(try parser.feed(Data("data: a\n".utf8)).isEmpty)

        XCTAssertThrowsError(try parser.feed(Data("data: b\n".utf8))) { error in
            XCTAssertEqual(
                error as? CoFleetTransportLimitError,
                .sseEventTooLarge(maxBytes: 15)
            )
        }
    }

    func testBoundedResponseAccumulatorRejectsByteBeyondLimit() throws {
        var body = CoFleetBoundedBodyAccumulator(maximumBytes: 3)
        try body.append(0x01)
        try body.append(0x02)
        try body.append(0x03)
        XCTAssertEqual(body.data.count, 3)

        XCTAssertThrowsError(try body.append(0x04)) { error in
            XCTAssertEqual(
                error as? CoFleetTransportLimitError,
                .responseBodyTooLarge(maxBytes: 3)
            )
        }
    }

    func testHostEndpointOnlyAllowsHTTPSOrExactLoopbackHTTP() throws {
        XCTAssertNoThrow(try CoFleetHostEndpoint(baseURL: URL(string: "https://sample.tailnet.ts.net")!))
        XCTAssertNoThrow(try CoFleetHostEndpoint(baseURL: URL(string: "http://127.0.0.1:8765")!))
        XCTAssertThrowsError(try CoFleetHostEndpoint(baseURL: URL(string: "http://sample.tailnet.ts.net")!))
        XCTAssertThrowsError(try CoFleetHostEndpoint(baseURL: URL(string: "https://user:secret@sample.tailnet.ts.net")!))
        XCTAssertThrowsError(try CoFleetHostEndpoint(baseURL: URL(string: "https://sample.tailnet.ts.net/base")!))
        XCTAssertThrowsError(try CoFleetHostEndpoint(baseURL: URL(string: "https://sample.tailnet.ts.net/#fragment")!))
    }

    func testPetValidatorRejectsTraversal() {
        let manifest = CoFleetPetManifest(
            hostID: .init(rawValue: "sample-host"),
            id: "sample-pet",
            displayName: "Sample Pet",
            spriteVersionNumber: 2,
            spritesheetPath: "../secret.png",
            rows: 11,
            digest: String(repeating: "a", count: 64)
        )
        XCTAssertThrowsError(try CoFleetPetManifestValidator.validate(manifest)) {
            XCTAssertEqual($0 as? CoFleetPetManifestError, .unsafeAssetPath("../secret.png"))
        }
    }

    func testPetValidatorAcceptsSafeV2Manifest() throws {
        let manifest = CoFleetPetManifest(
            hostID: .init(rawValue: "sample-host"),
            id: "sample-pet",
            displayName: "Sample Pet",
            spriteVersionNumber: 2,
            spritesheetPath: "spritesheet.webp",
            rows: 11,
            digest: String(repeating: "a", count: 64)
        )
        XCTAssertNoThrow(try CoFleetPetManifestValidator.validate(manifest))
        XCTAssertEqual(manifest.pixelWidth, 1_536)
        XCTAssertEqual(manifest.pixelHeight, 2_288)
    }

    func testResponsivePolicies() {
        XCTAssertEqual(CoFleetResponsivePolicy.progressColumns(availableWidth: 863), .one)
        XCTAssertEqual(CoFleetResponsivePolicy.progressColumns(availableWidth: 864), .two)
        #if os(macOS)
        XCTAssertEqual(CoFleetResponsivePolicy.activePresentation, .sideBySide)
        #else
        XCTAssertEqual(CoFleetResponsivePolicy.activePresentation, .vertical)
        #endif
    }

    func testRemoteThreadNeverGetsCodexDeepLink() {
        let session = CoFleetSessionSummary(
            id: "01900000-0000-7000-8000-000000000001",
            hostID: .init(rawValue: "remote-host"),
            projectID: "project-sample",
            title: "Synthetic Session"
        )
        XCTAssertNil(CodexDeepLinkResolver.localThreadURL(session: session, localHostID: .init(rawValue: "local-host")))
        XCTAssertEqual(
            CodexDeepLinkResolver.localThreadURL(session: session, localHostID: session.hostID)?.absoluteString,
            "codex://threads/01900000-0000-7000-8000-000000000001"
        )
    }

    func testWatchDeliveryPersistsForRecovery() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cofleet-watch-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CoFleetWatchDeliveryStore(fileURL: url)
        let delivery = CoFleetWatchDelivery(
            hostID: .init(rawValue: "sample-host"),
            projectID: "project-sample",
            sessionID: "sample-session",
            state: .completed,
            responsePreview: "Finished safely."
        )
        try await store.upsert(delivery)
        let restored = CoFleetWatchDeliveryStore(fileURL: url)
        await restored.load()
        let pending = await restored.completedNeedingNotification()
        XCTAssertEqual(pending, [delivery])
    }

    func testWatchRelayRequestRoundTripsWithHostAndSessionScope() throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let request = CoFleetWatchRequest(
            id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
            kind: .startTurn,
            hostID: .init(rawValue: "sample-host"),
            projectID: "project-sample",
            sessionID: "session-sample",
            prompt: "Check the current build.",
            createdAt: now
        )
        let encoded = try CoFleetWatchRelayCodec.encode(.init(request: request))
        let decoded = try CoFleetWatchRelayCodec.decode(encoded)
        XCTAssertEqual(decoded.request, request)
        XCTAssertEqual(decoded.kind, .request)
    }

    func testWatchRelayRejectsOversizedAndStaleRequests() {
        let oversized = CoFleetWatchRequest(
            kind: .startTurn,
            hostID: .init(rawValue: "sample-host"),
            projectID: "project-sample",
            sessionID: "session-sample",
            prompt: String(repeating: "x", count: CoFleetWatchRelayCodec.maximumPromptUTF8Bytes + 1)
        )
        XCTAssertThrowsError(try CoFleetWatchRelayCodec.encode(.init(request: oversized))) {
            XCTAssertEqual($0 as? CoFleetWatchRelayValidationError, .promptTooLarge)
        }

        let now = Date()
        let stale = CoFleetWatchRequest(
            kind: .toggleTodo,
            hostID: .init(rawValue: "sample-host"),
            projectID: "project-sample",
            todoID: "todo-sample",
            createdAt: now.addingTimeInterval(-(CoFleetWatchRelayCodec.maximumRequestAge + 1))
        )
        XCTAssertThrowsError(try CoFleetWatchRelayCodec.validate(stale, now: now)) {
            XCTAssertEqual($0 as? CoFleetWatchRelayValidationError, .staleRequest)
        }
    }

    func testWatchDeliveryStoreKeepsLatestBoundedRecoverySet() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cofleet-watch-bounded-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CoFleetWatchDeliveryStore(fileURL: url)
        let hostID = CoFleetHostID(rawValue: "sample-host")
        for index in 0..<110 {
            try await store.upsert(CoFleetWatchDelivery(
                hostID: hostID,
                projectID: "project-\(index)",
                sessionID: "session-\(index)",
                state: .pending,
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            ))
        }
        let stored = await store.all()
        XCTAssertEqual(stored.count, 100)
        XCTAssertEqual(stored.first?.projectID, "project-109")
        XCTAssertNil(stored.first { $0.projectID == "project-0" })
    }
}

@MainActor
final class StoreTests: XCTestCase {
    func testThreadStoreRequestsFiveAndLoadsNextPage() async {
        let repository = ThreadRepositoryFake()
        let store = ThreadStore(repository: repository)
        let host = CoFleetHostID(rawValue: "sample-host")
        let project = "project-sample"

        await store.loadInitial(hostID: host, projectID: project)
        XCTAssertEqual(store.sessions.count, 5)
        XCTAssertTrue(store.canLoadMore)
        await store.loadMore()
        XCTAssertEqual(store.sessions.count, 7)
        let limits = await repository.requestedLimits
        XCTAssertEqual(limits, [5, 5])
    }

    func testThreadStoreOpensSelectedSessionOnItsOwningHost() async throws {
        let repository = ThreadRepositoryFake()
        let store = ThreadStore(repository: repository)
        let host = CoFleetHostID(rawValue: "sample-host")

        await store.loadInitial(hostID: host, projectID: "project-sample")
        try await store.openSelectedInCodex()

        let requests = await repository.desktopOpenRequests
        XCTAssertEqual(requests, [.init(hostID: host, sessionID: "session-0")])
    }

    func testThreadStoreOpensCachedHostSessionWithoutLoadingCatalog() async throws {
        let repository = ThreadRepositoryFake()
        let store = ThreadStore(repository: repository)
        let host = CoFleetHostID(rawValue: "sample-host")

        try await store.openInCodex(hostID: host, sessionID: "cached-session")

        let requests = await repository.desktopOpenRequests
        XCTAssertEqual(requests, [.init(hostID: host, sessionID: "cached-session")])
        let limits = await repository.requestedLimits
        XCTAssertTrue(limits.isEmpty)
    }

    func testThreadStoreRefreshesFreshestTranscriptPreviewPerProject() async {
        let repository = ThreadRepositoryFake()
        let store = ThreadStore(repository: repository, previewRepository: repository)
        let host = CoFleetHostID(rawValue: "sample-host")
        let project = CoFleetProject(
            id: "project-sample",
            hostID: host,
            displayName: "Sample",
            canonicalPath: "/tmp/sample"
        )

        await store.refreshLatestSessionPreviews(for: [project])

        XCTAssertEqual(store.latestSession(for: project.id)?.id, "session-0")
        XCTAssertEqual(
            store.latestPreview(for: project.id)?.messages.map(\.text),
            ["Latest question", "Latest answer"]
        )
    }

    func testConversationPreviewRequiresAUserTurn() {
        let assistantOnly = CoFleetProjectConversationPreview.recentConversationMessages(from: [
            .init(id: "assistant", turnID: "turn", kind: .assistantMessage, text: "Orphaned response"),
            .init(id: "reasoning", turnID: "turn", kind: .reasoning, text: "Hidden reasoning"),
        ])

        XCTAssertTrue(assistantOnly.isEmpty)
    }

    func testThreadStoreSkipsEmptyNewestTaskForFreshestPopulatedPreview() async {
        let repository = ThreadRepositoryFake(transcriptsBySessionID: [
            "session-0": [
                .init(id: "assistant-only", turnID: "empty", kind: .assistantMessage, text: "No initiating user"),
            ],
            "session-1": [
                .init(id: "user", turnID: "populated", kind: .userMessage, text: "Actual latest question"),
                .init(id: "answer", turnID: "populated", kind: .assistantMessage, text: "Actual latest answer"),
            ],
        ])
        let store = ThreadStore(repository: repository, previewRepository: repository)
        let project = CoFleetProject(
            id: "project-sample",
            hostID: .init(rawValue: "sample-host"),
            displayName: "Sample",
            canonicalPath: "/tmp/sample"
        )

        await store.refreshLatestSessionPreviews(for: [project])

        XCTAssertEqual(store.latestSession(for: project.id)?.id, "session-1")
        XCTAssertEqual(
            store.latestPreview(for: project.id)?.messages.map(\.text),
            ["Actual latest question", "Actual latest answer"]
        )
        let transcriptRequests = await repository.transcriptRequests
        XCTAssertEqual(transcriptRequests, ["session-1"])
    }

    func testThreadStoreReusesUnchangedLatestTranscriptPreview() async {
        let repository = ThreadRepositoryFake()
        let store = ThreadStore(repository: repository, previewRepository: repository)
        let project = CoFleetProject(
            id: "project-sample",
            hostID: .init(rawValue: "sample-host"),
            displayName: "Sample",
            canonicalPath: "/tmp/sample"
        )

        await store.refreshLatestSessionPreviews(for: [project])
        await store.refreshLatestSessionPreviews(for: [project])

        let transcriptRequests = await repository.transcriptRequests
        XCTAssertEqual(transcriptRequests, ["session-0"])
        let requestedLimits = await repository.requestedLimits
        XCTAssertEqual(requestedLimits, [5])
    }

    func testThreadStoreReloadsTranscriptWhenLatestTaskChanges() async {
        let repository = ThreadRepositoryFake()
        let store = ThreadStore(repository: repository, previewRepository: repository)
        let project = CoFleetProject(
            id: "project-sample",
            hostID: .init(rawValue: "sample-host"),
            displayName: "Sample",
            canonicalPath: "/tmp/sample"
        )

        await store.refreshLatestSessionPreviews(for: [project])
        await repository.advanceLatestSession()
        await store.refreshLatestSessionPreviews(for: [project], force: true)

        let transcriptRequests = await repository.transcriptRequests
        XCTAssertEqual(transcriptRequests, ["session-0", "session-0"])
    }

    func testThreadStoreReadsAtMostOneTranscriptWhenMetadataHasNoUserPreview() async {
        let repository = ThreadRepositoryFake(transcriptsBySessionID: [:])
        let store = ThreadStore(repository: repository, previewRepository: repository)
        let project = CoFleetProject(
            id: "project-sample",
            hostID: .init(rawValue: "sample-host"),
            displayName: "Sample",
            canonicalPath: "/tmp/sample"
        )

        await store.refreshLatestSessionPreviews(for: [project])

        let transcriptRequests = await repository.transcriptRequests
        XCTAssertEqual(transcriptRequests, ["session-0"])
        XCTAssertNil(store.latestPreview(for: project.id))
    }

    func testFleetStoreDeduplicatesCanonicalHostAndPath() async {
        let host = CoFleetHostID(rawValue: "sample-host")
        let project = CoFleetProject(hostID: host, displayName: "Sample", canonicalPath: "/tmp/sample")
        let repository = FleetRepositoryFake(projects: [project])
        let store = FleetStore(repository: repository)
        await store.refresh()

        do {
            _ = try await store.registerProject(hostID: host, canonicalPath: "/tmp/sample", displayName: "Duplicate")
            XCTFail("Expected duplicate conflict")
        } catch CoFleetClientError.conflict {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFleetStoreListsRotatesAndRevokesCurrentDevice() async {
        let repository = FleetRepositoryFake(projects: [])
        let store = FleetStore(repository: repository)
        let hostID = CoFleetHostID(rawValue: "sample-host")

        await store.refresh()
        await store.refreshPairedDevices(hostID: hostID)
        XCTAssertEqual(store.currentPairedDeviceIDs[hostID], "device-sample")
        XCTAssertEqual(store.pairedDevices[hostID]?.map(\.id), ["device-sample"])

        await store.rotateCurrentDevice(hostID: hostID)
        XCTAssertEqual(
            store.pairedDevices[hostID]?.first?.lastSeenAt,
            Date(timeIntervalSince1970: 1_800_000_100)
        )

        await store.revokeCurrentDevice(hostID: hostID)
        XCTAssertTrue(store.hosts.isEmpty)
        XCTAssertNil(store.pairedDevices[hostID])
        XCTAssertNil(store.currentPairedDeviceIDs[hostID])
    }

    func testTurnStoreReconcilesOptimisticMessageAndAdvancesUnknownCheckpoint() async throws {
        let repository = TurnRepositoryFake()
        let store = TurnStore(repository: repository)
        let hostID = CoFleetHostID(rawValue: "sample-host")
        await store.open(hostID: hostID, projectID: "project-sample", sessionID: "thread-1")
        store.draft = "Build the sample."
        _ = try await store.send(settings: .init())
        XCTAssertEqual(store.items.count, 1)
        XCTAssertTrue(store.items[0].id.hasPrefix("local-"))

        let canonical = CoFleetTurnItem(
            id: "message-1",
            turnID: "turn-1",
            kind: .userMessage,
            text: "Build the sample."
        )
        store.consume(.init(id: "50", event: .upsertItem(canonical)))
        store.consume(.init(id: "51", event: .upsertItem(canonical)))
        XCTAssertEqual(store.items, [canonical])

        store.consume(.init(id: "77", event: .checkpoint))
        XCTAssertEqual(store.lastProcessedEventID, "77")
        XCTAssertEqual(store.items, [canonical])
    }

    func testTurnStoreSendsTextAndBoundedAttachmentsThenClearsComposer() async throws {
        let repository = TurnRepositoryFake()
        let store = TurnStore(repository: repository)
        let hostID = CoFleetHostID(rawValue: "sample-host")
        await store.open(hostID: hostID, projectID: "project-sample", sessionID: "thread-1")
        store.draft = "Compare these."
        let remote = try CoFleetTurnAttachment.imageURL(
            URL(string: "https://example.com/reference.png")!
        )
        let local = CoFleetTurnAttachment(
            source: .localImage(path: "/tmp/sample/current.png"),
            displayName: "current.png",
            byteCount: 1_024
        )
        try store.addAttachment(remote)
        try store.addAttachment(local)

        _ = try await store.send(settings: .init())

        let requests = await repository.startedRequests
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.hostID, hostID)
        XCTAssertEqual(request.projectID, "project-sample")
        XCTAssertEqual(request.sessionID, "thread-1")
        XCTAssertEqual(request.input, [
            .text("Compare these."),
            .imageURL(URL(string: "https://example.com/reference.png")!),
            .localImage(path: "/tmp/sample/current.png"),
        ])
        XCTAssertTrue(store.draft.isEmpty)
        XCTAssertTrue(store.attachments.isEmpty)
    }

    func testTurnStoreBoundsAttachmentsAndRestoresThemWhenSendFails() async throws {
        let repository = TurnRepositoryFake(startError: .unavailable("Host offline."))
        let store = TurnStore(repository: repository)
        await store.open(
            hostID: .init(rawValue: "sample-host"),
            projectID: "project-sample",
            sessionID: "thread-1"
        )
        for index in 0..<CoFleetTurnAttachment.maximumCount {
            try store.addAttachment(try CoFleetTurnAttachment.imageURL(
                URL(string: "https://example.com/image-\(index).png")!
            ))
        }
        XCTAssertThrowsError(try store.addAttachment(try CoFleetTurnAttachment.imageURL(
            URL(string: "https://example.com/overflow.png")!
        ))) { error in
            XCTAssertEqual(
                error as? CoFleetTurnAttachmentError,
                .tooManyAttachments(maximumCount: CoFleetTurnAttachment.maximumCount)
            )
        }

        do {
            _ = try await store.send(settings: .init())
            XCTFail("Expected the synthetic send failure")
        } catch CoFleetClientError.unavailable {
            // Expected.
        }
        XCTAssertEqual(store.attachments.count, CoFleetTurnAttachment.maximumCount)
        XCTAssertTrue(store.canSend)
    }
}

final class CredentialLifecycleTests: XCTestCase {
    func testPairingStorageFailureRevokesIncompleteDeviceAndRestoresPriorToken() async throws {
        let hostID = CoFleetHostID(rawValue: "sample-host")
        let vault = CredentialTokenVaultFake(token: "prior-token", failsStore: true)
        let credential = CoFleetHostCredential(hostID: hostID, vault: vault)
        let rollback = CredentialRollbackProbe()

        do {
            try await credential.installPairingToken("new-token") {
                await rollback.record()
            }
            XCTFail("Expected secure-storage failure")
        } catch let error as CoFleetPairingCredentialError {
            guard case .rolledBack = error else {
                return XCTFail("Expected the incomplete pairing to be rolled back")
            }
        }

        let rollbackCount = await rollback.count
        let restoredToken = try await credential.token()
        XCTAssertEqual(rollbackCount, 1)
        XCTAssertEqual(restoredToken, "prior-token")
    }

    func testFailedPairingRollbackRetainsNewTokenForInProcessRecovery() async throws {
        let hostID = CoFleetHostID(rawValue: "sample-host")
        let vault = CredentialTokenVaultFake(token: nil, failsStore: true)
        let credential = CoFleetHostCredential(hostID: hostID, vault: vault)

        do {
            try await credential.installPairingToken("recoverable-token") {
                throw CredentialTestError.rollbackFailed
            }
            XCTFail("Expected rollback failure")
        } catch let error as CoFleetPairingCredentialError {
            guard case .recoveryRequired = error else {
                return XCTFail("Expected in-process recovery state")
            }
        }

        let recoverableToken = try await credential.token()
        let persistedToken = try await vault.token(for: hostID)
        XCTAssertEqual(recoverableToken, "recoverable-token")
        XCTAssertNil(persistedToken)
    }
}

private struct RecordedTurnRequest: Sendable {
    var hostID: CoFleetHostID
    var projectID: String
    var sessionID: String
    var input: [CoFleetTurnInput]
}

private actor TurnRepositoryFake: CoFleetTurnRepository {
    private(set) var startedRequests: [RecordedTurnRequest] = []
    private let startError: CoFleetClientError?

    init(startError: CoFleetClientError? = nil) {
        self.startError = startError
    }

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
        startedRequests.append(.init(
            hostID: hostID,
            projectID: projectID,
            sessionID: sessionID,
            input: input
        ))
        if let startError { throw startError }
        return CoFleetTurn(id: "turn-1", hostID: hostID, sessionID: sessionID, state: .running)
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
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

private actor ThreadRepositoryFake: CoFleetThreadRepository, CoFleetTurnRepository {
    struct DesktopOpenRequest: Equatable {
        var hostID: CoFleetHostID
        var sessionID: String
    }

    private(set) var requestedLimits: [Int] = []
    private(set) var desktopOpenRequests: [DesktopOpenRequest] = []
    private(set) var transcriptRequests: [String] = []
    private let transcriptsBySessionID: [String: [CoFleetTurnItem]]?
    private var sessionRevision = 0

    init(transcriptsBySessionID: [String: [CoFleetTurnItem]]? = nil) {
        self.transcriptsBySessionID = transcriptsBySessionID
    }

    func fetchSessions(
        hostID: CoFleetHostID,
        projectID: String,
        cursor: String?,
        limit: Int,
        archived: Bool
    ) async throws -> CoFleetSessionPage {
        requestedLimits.append(limit)
        let range = cursor == nil ? 0..<5 : 5..<7
        let items = range.map {
            let sessionID = "session-\($0)"
            let transcriptPreview = transcriptsBySessionID?[sessionID]?
                .first(where: { $0.kind == .userMessage })?.text
            return CoFleetSessionSummary(
                id: sessionID,
                hostID: hostID,
                projectID: projectID,
                title: "Session \($0)",
                updatedAt: Date(timeIntervalSince1970: 100 - Double($0) + Double(sessionRevision)),
                createdAt: Date(timeIntervalSince1970: 100 - Double($0)),
                preview: transcriptsBySessionID == nil ? "Latest question" : transcriptPreview
            )
        }
        return CoFleetSessionPage(items: items, nextCursor: cursor == nil ? "next" : nil)
    }

    func createSession(hostID: CoFleetHostID, projectID: String) async throws -> CoFleetSessionSummary {
        CoFleetSessionSummary(id: "new", hostID: hostID, projectID: projectID, title: "New Session")
    }

    func resumeSession(hostID: CoFleetHostID, projectID: String, sessionID: String, settings: CoFleetSessionSettings) async throws -> CoFleetSessionSummary {
        CoFleetSessionSummary(id: sessionID, hostID: hostID, projectID: projectID, title: "Resumed", modelID: settings.modelID)
    }

    func forkSession(hostID: CoFleetHostID, projectID: String, sessionID: String, settings: CoFleetSessionSettings) async throws -> CoFleetSessionSummary {
        CoFleetSessionSummary(id: "fork", hostID: hostID, projectID: projectID, title: "Fork")
    }

    func renameSession(hostID: CoFleetHostID, sessionID: String, title: String) async throws {}

    func archiveSession(hostID: CoFleetHostID, sessionID: String) async throws {}
    func unarchiveSession(hostID: CoFleetHostID, sessionID: String) async throws {}

    func openSessionInCodex(hostID: CoFleetHostID, sessionID: String) async throws {
        desktopOpenRequests.append(.init(hostID: hostID, sessionID: sessionID))
    }

    func fetchTranscript(hostID: CoFleetHostID, sessionID: String) async throws -> [CoFleetTurnItem] {
        transcriptRequests.append(sessionID)
        if let transcriptsBySessionID {
            return transcriptsBySessionID[sessionID] ?? []
        }
        return [
            .init(id: "old-user", turnID: "old", kind: .userMessage, text: "Old question"),
            .init(id: "old-answer", turnID: "old", kind: .assistantMessage, text: "Old answer"),
            .init(id: "latest-user", turnID: "new", kind: .userMessage, text: "Latest question"),
            .init(id: "reasoning", turnID: "new", kind: .reasoning, text: "Thinking"),
            .init(id: "latest-answer", turnID: "new", kind: .assistantMessage, text: "Latest answer"),
        ]
    }

    func fetchInteractions(hostID: CoFleetHostID, sessionID: String) async throws -> [CoFleetInteraction] { [] }

    func advanceLatestSession() {
        sessionRevision += 1
    }

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
        AsyncThrowingStream { continuation in continuation.finish() }
    }
}

private actor FleetRepositoryFake: CoFleetFleetRepository {
    let projects: [CoFleetProject]
    private var isRevoked = false
    private var device = CoFleetPairedDevice(
        id: "device-sample",
        name: "Sample iPhone",
        createdAt: Date(timeIntervalSince1970: 1_800_000_000),
        lastSeenAt: Date(timeIntervalSince1970: 1_800_000_050)
    )

    init(projects: [CoFleetProject]) { self.projects = projects }

    func fetchHosts() async throws -> [CoFleetHostInfo] {
        if isRevoked { return [] }
        return [.init(
            id: .init(rawValue: "sample-host"),
            displayName: "Sample Mac",
            platform: "macOS",
            canonicalHome: "/Users/sample",
            reachability: .online
        )]
    }

    func fetchAccount(hostID: CoFleetHostID) async throws -> CoFleetAccountInfo {
        .init(hostID: hostID, authenticationType: "chatgpt", planType: "plus", requiresOpenAIAuthentication: false)
    }

    func fetchAccountLimits(hostID: CoFleetHostID) async throws -> [CoFleetRateLimitInfo] {
        [.init(hostID: hostID, limitID: "codex", primary: .init(usedPercent: 25))]
    }

    func fetchPairedDevices(hostID: CoFleetHostID) async throws -> [CoFleetPairedDevice] {
        isRevoked ? [] : [device]
    }

    func currentPairedDeviceID(hostID: CoFleetHostID) async -> String? {
        isRevoked ? nil : device.id
    }

    func rotateCurrentDevice(hostID: CoFleetHostID) async throws -> CoFleetPairedDevice {
        device.lastSeenAt = Date(timeIntervalSince1970: 1_800_000_100)
        return device
    }

    func revokeCurrentDevice(hostID: CoFleetHostID) async throws {
        isRevoked = true
    }

    func fetchProjects() async throws -> [CoFleetProject] { isRevoked ? [] : projects }

    func discoverRecentRoots(hostID: CoFleetHostID, cursor: String?) async throws -> CoFleetDirectoryPage {
        .init(
            canonicalPath: "",
            parentPath: nil,
            entries: [.init(name: "Sample", canonicalPath: "/Users/sample/Sample")]
        )
    }

    func browseDirectories(
        hostID: CoFleetHostID,
        path: String,
        cursor: String?,
        showHidden: Bool
    ) async throws -> CoFleetDirectoryPage {
        .init(canonicalPath: path, parentPath: "/", entries: [])
    }

    func createDirectory(
        hostID: CoFleetHostID,
        parent: String,
        name: String
    ) async throws -> CoFleetDirectoryEntry {
        .init(name: name, canonicalPath: parent + "/" + name)
    }

    func registerProject(hostID: CoFleetHostID, canonicalPath: String, displayName: String) async throws -> CoFleetProject {
        .init(hostID: hostID, displayName: displayName, canonicalPath: canonicalPath)
    }

    func removeProject(id: String) async throws {}
}

private enum CredentialTestError: Error, LocalizedError {
    case keychainUnavailable
    case rollbackFailed

    var errorDescription: String? {
        switch self {
        case .keychainUnavailable: "Synthetic Keychain failure."
        case .rollbackFailed: "Synthetic rollback failure."
        }
    }
}

private actor CredentialTokenVaultFake: CoFleetTokenVault {
    private var storedToken: String?
    private let failsStore: Bool

    init(token: String?, failsStore: Bool) {
        storedToken = token
        self.failsStore = failsStore
    }

    func token(for hostID: CoFleetHostID) throws -> String? { storedToken }

    func store(token: String, for hostID: CoFleetHostID) throws {
        if failsStore { throw CredentialTestError.keychainUnavailable }
        storedToken = token
    }

    func removeToken(for hostID: CoFleetHostID) throws {
        storedToken = nil
    }
}

private actor CredentialRollbackProbe {
    private(set) var count = 0

    func record() {
        count += 1
    }
}
