import CoFleetCore
import CoFleetTransport
import Foundation
import XCTest

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class APIClientContractTests: XCTestCase {
    func testSaveNoteReconcilesNestedHostErrorOnPreconditionFailure() async throws {
        let service = try makeService()
        let local = CoFleetNote(
            id: "note-local",
            hostID: .init(rawValue: "sample-host"),
            projectID: "project-1",
            markdown: "local draft",
            revision: 1
        )

        let result = try await service.saveNote(local, expectedETag: local.eTag)
        guard case let .conflict(server, localMarkdown) = result else {
            return XCTFail("Expected optimistic-concurrency reconciliation")
        }
        XCTAssertEqual(server.id, "note-server")
        XCTAssertEqual(server.markdown, "server draft")
        XCTAssertEqual(localMarkdown, "local draft")
    }

    func testTodoUpdateUsesPatchWithIfMatch() async throws {
        let service = try makeService()
        let todo = CoFleetTodoItem(
            id: "todo-1",
            hostID: .init(rawValue: "sample-host"),
            projectID: "project-1",
            title: "Ship the release",
            isCompleted: true,
            sortIndex: 4,
            revision: 2
        )

        let saved = try await service.saveTodo(todo, expectedETag: todo.eTag)
        XCTAssertEqual(saved.id, todo.id)
        XCTAssertTrue(saved.isCompleted)
        XCTAssertEqual(saved.revision, 3)
    }

    func testPreconditionRequiredIsTypedConflictWithNestedMessage() async throws {
        let client = try makeClient()
        do {
            let _: [String: String] = try await client.get("/v1/precondition-required")
            XCTFail("Expected a typed precondition error")
        } catch let error as CoFleetClientError {
            XCTAssertEqual(error, .conflict("If-Match is required."))
        }
    }

    private func makeService() throws -> CoFleetHostService {
        CoFleetHostService(client: try makeClient())
    }

    private func makeClient() throws -> CoFleetAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContractURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let endpoint = try CoFleetHostEndpoint(
            baseURL: URL(string: "https://sample.tailnet.ts.net")!
        )
        return CoFleetAPIClient(endpoint: endpoint, session: session) { "sample-token" }
    }
}

private final class ContractURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let status: Int
        let body: String
        switch (request.httpMethod, request.url?.path) {
        case ("PUT", "/v1/projects/project-1/note"):
            status = 412
            body = #"{"error":{"code":"revision_conflict","message":"Server note changed."}}"#
        case ("GET", "/v1/projects/project-1/note"):
            status = 200
            body = #"{"note":{"id":"note-server","projectID":"project-1","sessionID":null,"markdown":"server draft","revision":2,"updatedAt":1800000000}}"#
        case ("PATCH", "/v1/todos/todo-1")
            where request.value(forHTTPHeaderField: "If-Match") == #""todo-todo-1-2""#:
            status = 200
            body = #"{"todo":{"id":"todo-1","projectID":"project-1","text":"Ship the release","completed":true,"position":4,"revision":3,"updatedAt":1800000000}}"#
        case ("GET", "/v1/precondition-required"):
            status = 428
            body = #"{"error":{"code":"precondition_required","message":"If-Match is required."}}"#
        default:
            status = 400
            body = #"{"error":{"code":"unexpected_request","message":"Unexpected method or path."}}"#
        }

        let data = Data(body.utf8)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
