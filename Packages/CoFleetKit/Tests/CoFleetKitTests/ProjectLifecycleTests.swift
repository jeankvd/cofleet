import CoFleetCore
import CoFleetTransport
import Foundation
import XCTest

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
final class ProjectLifecycleTests: XCTestCase {
    func testHostServiceRenamesWithPatchAndRemovesOnlyThroughUnregisterEndpoint() async throws {
        ProjectLifecycleURLProtocol.recorder.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProjectLifecycleURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let endpoint = try CoFleetHostEndpoint(
            baseURL: URL(string: "https://sample.tailnet.ts.net")!
        )
        let client = CoFleetAPIClient(endpoint: endpoint, session: session) { "sample-token" }
        let service = CoFleetHostService(client: client)
        let hostID = CoFleetHostID(rawValue: "sample-host")

        let renamed = try await service.renameProject(
            hostID: hostID,
            id: "project-1",
            displayName: "Renamed Project"
        )
        try await service.removeProject(id: "project-1")

        XCTAssertEqual(renamed.id, "project-1")
        XCTAssertEqual(renamed.hostID, hostID)
        XCTAssertEqual(renamed.displayName, "Renamed Project")
        XCTAssertEqual(renamed.canonicalPath, "/Users/sample/work")
        XCTAssertEqual(renamed.currentSessionID, "thread-current")

        let requests = ProjectLifecycleURLProtocol.recorder.snapshot()
        XCTAssertEqual(
            requests.map { "\($0.method) \($0.path)" },
            [
                "PATCH /v1/projects/project-1",
                "DELETE /v1/projects/project-1",
            ]
        )
        XCTAssertEqual(requests.first?.jsonBody?["name"] as? String, "Renamed Project")
        XCTAssertNil(requests.last?.jsonBody)
        XCTAssertTrue(
            requests.allSatisfy { !$0.path.contains("directories") },
            "Removing a project must only unregister it; it must never issue a directory operation."
        )
    }

    func testHostServiceRequestsCodexDesktopOpenWithoutSendingAnExternalURL() async throws {
        ProjectLifecycleURLProtocol.recorder.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProjectLifecycleURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let endpoint = try CoFleetHostEndpoint(baseURL: URL(string: "https://sample.tailnet.ts.net")!)
        let client = CoFleetAPIClient(endpoint: endpoint, session: session) { "sample-token" }
        let service = CoFleetHostService(client: client)

        try await service.openSessionInCodex(
            hostID: CoFleetHostID(rawValue: "sample-host"),
            sessionID: "thread-abc"
        )

        let requests = ProjectLifecycleURLProtocol.recorder.snapshot()
        XCTAssertEqual(requests.map { "\($0.method) \($0.path)" }, [
            "POST /v1/sessions/thread-abc/open-in-codex",
        ])
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/v1/sessions/thread-abc/open-in-codex")
        XCTAssertEqual(request.jsonBody?.count, 0)
        XCTAssertNil(request.jsonBody?["url"])
        XCTAssertEqual(request.timeoutInterval, 8, accuracy: 0.001)
    }

    func testFleetStoreRenamePreservesVisibilityAndUserOrder() async throws {
        let hostID = CoFleetHostID(rawValue: "sample-host")
        let repository = ProjectLifecycleRepositoryFake(
            projects: [
                CoFleetProject(
                    id: "project-a",
                    hostID: hostID,
                    displayName: "Alpha",
                    canonicalPath: "/Users/sample/alpha",
                    sortIndex: 0
                ),
                CoFleetProject(
                    id: "project-b",
                    hostID: hostID,
                    displayName: "Beta",
                    canonicalPath: "/Users/sample/beta",
                    sortIndex: 1
                ),
            ]
        )
        let preferences = ProjectLifecyclePreferencesStore()
        let store = FleetStore(repository: repository, preferencesStore: preferences)
        await store.refresh()
        XCTAssertTrue(store.moveProject("project-b", before: "project-a"))
        store.setVisibility(false, for: "project-a")

        let renamed = try await store.renameProject(
            id: "project-a",
            displayName: "  Renamed Alpha  "
        )

        XCTAssertEqual(renamed.displayName, "Renamed Alpha")
        XCTAssertFalse(renamed.isVisible)
        XCTAssertEqual(renamed.sortIndex, 1)
        XCTAssertEqual(store.orderedProjects.map(\.id), ["project-b", "project-a"])
        XCTAssertEqual(preferences.value?.orderedProjectIDs, ["project-b", "project-a"])
        XCTAssertEqual(preferences.value?.hiddenProjectIDs, ["project-a"])

        let call = await repository.renameCall()
        XCTAssertEqual(
            call,
            .init(hostID: hostID, projectID: "project-a", displayName: "Renamed Alpha")
        )
    }

    func testFleetStoreRemovalOnlyUnregistersAndPrunesLocalPreferences() async throws {
        let hostID = CoFleetHostID(rawValue: "sample-host")
        let repository = ProjectLifecycleRepositoryFake(
            projects: [
                CoFleetProject(
                    id: "project-a",
                    hostID: hostID,
                    displayName: "Alpha",
                    canonicalPath: "/Users/sample/alpha"
                ),
                CoFleetProject(
                    id: "project-b",
                    hostID: hostID,
                    displayName: "Beta",
                    canonicalPath: "/Users/sample/beta"
                ),
            ]
        )
        let preferences = ProjectLifecyclePreferencesStore()
        let store = FleetStore(repository: repository, preferencesStore: preferences)
        await store.refresh()
        store.setVisibility(false, for: "project-a")

        try await store.removeProject(id: "project-a")

        XCTAssertEqual(store.projects.map(\.id), ["project-b"])
        XCTAssertEqual(preferences.value?.orderedProjectIDs, ["project-b"])
        XCTAssertEqual(preferences.value?.hiddenProjectIDs, [])
        let removedProjectIDs = await repository.removedProjectIDs()
        let directoryPaths = await repository.existingDirectoryPaths()
        XCTAssertEqual(removedProjectIDs, ["project-a"])
        XCTAssertEqual(
            directoryPaths,
            ["/Users/sample/alpha", "/Users/sample/beta"],
            "Unregistering project metadata must leave project directories untouched."
        )
    }
}

private struct ProjectRenameCall: Equatable, Sendable {
    var hostID: CoFleetHostID
    var projectID: String
    var displayName: String
}

private actor ProjectLifecycleRepositoryFake: CoFleetFleetRepository {
    private var projects: [CoFleetProject]
    private let directoryPaths: [String]
    private var recordedRenameCall: ProjectRenameCall?
    private var removedIDs: [String] = []

    init(projects: [CoFleetProject]) {
        self.projects = projects
        directoryPaths = projects.map(\.canonicalPath)
    }

    func fetchHosts() async throws -> [CoFleetHostInfo] {
        Array(Set(projects.map(\.hostID))).map { hostID in
            CoFleetHostInfo(
                id: hostID,
                displayName: "Sample Host",
                platform: "macOS",
                canonicalHome: "/Users/sample",
                reachability: .online
            )
        }
    }

    func fetchAccount(hostID: CoFleetHostID) async throws -> CoFleetAccountInfo {
        .init(hostID: hostID, authenticationType: "chatgpt", requiresOpenAIAuthentication: false)
    }

    func fetchAccountLimits(hostID: CoFleetHostID) async throws -> [CoFleetRateLimitInfo] { [] }
    func fetchProjects() async throws -> [CoFleetProject] { projects }

    func discoverRecentRoots(hostID: CoFleetHostID, cursor: String?) async throws -> CoFleetDirectoryPage {
        .init(canonicalPath: "/Users/sample", parentPath: "/Users", entries: [])
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
        .init(name: name, canonicalPath: "\(parent)/\(name)")
    }

    func registerProject(
        hostID: CoFleetHostID,
        canonicalPath: String,
        displayName: String
    ) async throws -> CoFleetProject {
        .init(hostID: hostID, displayName: displayName, canonicalPath: canonicalPath)
    }

    func renameProject(
        hostID: CoFleetHostID,
        id: String,
        displayName: String
    ) async throws -> CoFleetProject {
        guard let index = projects.firstIndex(where: { $0.id == id && $0.hostID == hostID }) else {
            throw CoFleetClientError.unavailable("The project was not found.")
        }
        recordedRenameCall = .init(hostID: hostID, projectID: id, displayName: displayName)
        projects[index].displayName = displayName
        projects[index].isVisible = true
        projects[index].sortIndex = 99
        return projects[index]
    }

    func removeProject(id: String) async throws {
        guard projects.contains(where: { $0.id == id }) else {
            throw CoFleetClientError.unavailable("The project was not found.")
        }
        removedIDs.append(id)
        projects.removeAll { $0.id == id }
    }

    func renameCall() -> ProjectRenameCall? { recordedRenameCall }
    func removedProjectIDs() -> [String] { removedIDs }
    func existingDirectoryPaths() -> [String] { directoryPaths }
}

@MainActor
private final class ProjectLifecyclePreferencesStore: CoFleetProgressPreferencesStoring {
    var value: CoFleetProgressPreferences?

    func load() -> CoFleetProgressPreferences? { value }
    func save(_ preferences: CoFleetProgressPreferences) { value = preferences }
}

private struct ProjectLifecycleRequest {
    var method: String
    var path: String
    var jsonBody: [String: Any]?
    var timeoutInterval: TimeInterval

    init(request: URLRequest) {
        method = request.httpMethod ?? "GET"
        path = request.url?.path ?? ""
        timeoutInterval = request.timeoutInterval
        if let body = request.httpBody ?? Self.read(request.httpBodyStream),
           let object = try? JSONSerialization.jsonObject(with: body),
           let dictionary = object as? [String: Any] {
            jsonBody = dictionary
        } else {
            jsonBody = nil
        }
    }

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { return nil }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

private final class ProjectLifecycleURLProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = ProjectLifecycleRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let lifecycleRequest = ProjectLifecycleRequest(request: request)
        Self.recorder.append(lifecycleRequest)

        let statusCode: Int
        let body: String
        switch (lifecycleRequest.method, lifecycleRequest.path) {
        case ("GET", "/v1/host"):
            statusCode = 200
            body = #"{"host":{"id":"sample-host","displayName":"Sample Mac","platform":"macOS","homePath":"/Users/sample","codexAvailable":true,"capabilities":{"folderCreation":true,"pets":true,"codexDesktopOpen":true,"sourceControl":["git"]}}}"#
        case ("PATCH", "/v1/projects/project-1"):
            statusCode = 200
            body = #"{"project":{"id":"project-1","name":"Renamed Project","canonicalPath":"/Users/sample/work","currentSessionID":"thread-current","petID":null}}"#
        case ("DELETE", "/v1/projects/project-1"):
            statusCode = 200
            body = #"{"project":{"id":"project-1","name":"Renamed Project","canonicalPath":"/Users/sample/work","petID":null},"directoryDeleted":false}"#
        case ("POST", "/v1/sessions/thread-abc/open-in-codex"):
            statusCode = 200
            body = #"{"sessionID":"thread-abc","opened":true}"#
        default:
            statusCode = 400
            body = #"{"error":{"code":"unexpected_request","message":"Unexpected method or path."}}"#
        }

        let data = Data(body.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ProjectLifecycleRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [ProjectLifecycleRequest] = []

    func append(_ request: ProjectLifecycleRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func snapshot() -> [ProjectLifecycleRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func reset() {
        lock.lock()
        requests.removeAll()
        lock.unlock()
    }
}
