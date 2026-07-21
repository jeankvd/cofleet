import CoFleetCore
import CoFleetTransport
import Foundation
import XCTest

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class DeviceLifecycleTransportTests: XCTestCase {
    func testDeviceLifecycleUsesAuthenticatedSelfScopedEndpoints() async throws {
        DeviceLifecycleURLProtocol.recorder.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceLifecycleURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let endpoint = try CoFleetHostEndpoint(
            baseURL: URL(string: "https://sample.tailnet.ts.net")!
        )
        let client = CoFleetAPIClient(endpoint: endpoint, session: session) { "sample-token" }
        let service = CoFleetHostService(client: client)
        let hostID = CoFleetHostID(rawValue: "sample-host")

        let devices = try await service.fetchPairedDevices(hostID: hostID)
        XCTAssertEqual(devices.map(\.id), ["device-current", "device-old"])
        XCTAssertFalse(devices[0].isRevoked)
        XCTAssertTrue(devices[1].isRevoked)

        let rotation = try await service.rotateDevice(id: "device-current")
        XCTAssertEqual(rotation.device.id, "device-current")
        XCTAssertEqual(rotation.token, "replacement-token")

        try await service.revokeDevice(id: "device-current")

        let requests = DeviceLifecycleURLProtocol.recorder.snapshot()
        XCTAssertEqual(
            requests.map { "\($0.method) \($0.path)" },
            [
                "GET /v1/host",
                "GET /v1/devices",
                "POST /v1/devices/device-current/rotate",
                "DELETE /v1/devices/device-current",
            ]
        )
        XCTAssertTrue(requests.allSatisfy { $0.authorization == "Bearer sample-token" })
    }
}

private final class DeviceLifecycleURLProtocol: URLProtocol, @unchecked Sendable {
    static let recorder = DeviceLifecycleRequestRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        Self.recorder.append(
            .init(
                method: method,
                path: path,
                authorization: request.value(forHTTPHeaderField: "Authorization")
            )
        )

        let body: String
        switch (method, path) {
        case ("GET", "/v1/host"):
            body = #"{"host":{"id":"sample-host","displayName":"Sample Mac","platform":"macos","homePath":"/Users/sample","codexAvailable":true,"capabilities":{"folderCreation":true,"pets":true,"sourceControl":["git"]}}}"#
        case ("GET", "/v1/devices"):
            body = #"{"devices":[{"id":"device-current","name":"Sample iPhone","createdAt":1800000000,"lastSeenAt":1800000050,"revoked":false,"revokedAt":null},{"id":"device-old","name":"Old iPad","createdAt":1700000000,"lastSeenAt":1700000050,"revoked":true,"revokedAt":1750000000}]}"#
        case ("POST", "/v1/devices/device-current/rotate"):
            body = #"{"device":{"id":"device-current","name":"Sample iPhone","createdAt":1800000000,"lastSeenAt":1800000100,"revoked":false,"revokedAt":null},"token":"replacement-token"}"#
        case ("DELETE", "/v1/devices/device-current"):
            body = #"{"device":{"id":"device-current","name":"Sample iPhone","createdAt":1800000000,"lastSeenAt":1800000100,"revoked":true,"revokedAt":1800000200}}"#
        default:
            body = #"{"code":"unexpected_request","message":"Unexpected synthetic request."}"#
        }

        let statusCode = body.contains("unexpected_request") ? 404 : 200
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

private struct DeviceLifecycleRequest: Equatable {
    var method: String
    var path: String
    var authorization: String?
}

private final class DeviceLifecycleRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [DeviceLifecycleRequest] = []

    func append(_ request: DeviceLifecycleRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func snapshot() -> [DeviceLifecycleRequest] {
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
