import CoFleetCore
import CoFleetTransport
import Foundation
import XCTest

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SourceControlTransportTests: XCTestCase {
    func testProjectCatalogDecodesEmbeddedSourceControlStatus() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SourceControlURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let endpoint = try CoFleetHostEndpoint(baseURL: URL(string: "https://sample.tailnet.ts.net")!)
        let client = CoFleetAPIClient(endpoint: endpoint, session: session) { "sample-token" }
        let service = CoFleetHostService(client: client)

        let projects = try await service.fetchProjects()
        let project = try XCTUnwrap(projects.first)

        XCTAssertEqual(project.sourceControl?.kind, .git)
        XCTAssertEqual(project.sourceControl?.state, .unpushed)
        XCTAssertEqual(project.sourceControl?.branch, "main")
        XCTAssertEqual(project.sourceControl?.summary, "main...origin/main [ahead 1]")
        XCTAssertEqual(
            project.sourceControl?.observedAt,
            Date(timeIntervalSince1970: 1_800_000_000)
        )
    }
}

private final class SourceControlURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body: String
        switch request.url?.path {
        case "/v1/host":
            body = """
            {"host":{"id":"sample-host","displayName":"Sample Mac","platform":"macos","homePath":"/Users/sample","codexAvailable":true,"capabilities":{"folderCreation":true,"pets":true,"sourceControl":["git","plastic"]}}}
            """
        case "/v1/projects":
            body = """
            {"projects":[{"id":"project-sample","name":"Sample Project","canonicalPath":"/Users/sample/Project","petID":null,"sourceControl":{"kind":"git","state":"unpushed","branch":"main","detail":"main...origin/main [ahead 1]","observedAt":1800000000}}]}
            """
        default:
            body = "{}"
        }
        let data = Data(body.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
