import CoFleetCore
import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CoFleetHostEndpoint: Hashable, Sendable {
    public var baseURL: URL

    public init(baseURL: URL) throws {
        let scheme = baseURL.scheme?.lowercased()
        let host = baseURL.host?.lowercased()
        let isLoopback = host == "127.0.0.1" || host == "localhost" || host == "::1"
        let hasCleanBase = baseURL.user == nil
            && baseURL.password == nil
            && baseURL.query == nil
            && baseURL.fragment == nil
            && (baseURL.path.isEmpty || baseURL.path == "/")
        guard host != nil,
              hasCleanBase,
              scheme == "https" || (scheme == "http" && isLoopback) else {
            throw CoFleetClientError.incompatible("CoFleet hosts require HTTPS outside loopback.")
        }
        self.baseURL = baseURL
    }
}

public actor CoFleetAPIClient {
    public typealias TokenProvider = @Sendable () async throws -> String?

    public static let defaultMaximumResponseBodyBytes = 8 * 1_024 * 1_024

    private let endpoint: CoFleetHostEndpoint
    private let session: URLSession
    private let tokenProvider: TokenProvider
    private let maximumResponseBodyBytes: Int
    private let maximumSSELineBytes: Int
    private let maximumSSEEventBytes: Int

    public init(
        endpoint: CoFleetHostEndpoint,
        session: URLSession = .shared,
        maximumResponseBodyBytes: Int = CoFleetAPIClient.defaultMaximumResponseBodyBytes,
        maximumSSELineBytes: Int = CoFleetSSEParser.defaultMaximumLineBytes,
        maximumSSEEventBytes: Int = CoFleetSSEParser.defaultMaximumEventBytes,
        tokenProvider: @escaping TokenProvider
    ) {
        self.endpoint = endpoint
        self.session = session
        self.maximumResponseBodyBytes = max(1, maximumResponseBodyBytes)
        self.maximumSSELineBytes = max(1, maximumSSELineBytes)
        self.maximumSSEEventBytes = max(1, maximumSSEEventBytes)
        self.tokenProvider = tokenProvider
    }

    public func get<Response: Decodable & Sendable>(
        _ path: String,
        query: [URLQueryItem] = []
    ) async throws -> Response {
        let request = try await makeRequest(method: "GET", path: path, query: query, body: Optional<String>.none)
        return try await send(request)
    }

    public func getData(
        _ path: String,
        maximumBytes: Int
    ) async throws -> CoFleetRawResponse {
        let request = try await makeRequest(
            method: "GET",
            path: path,
            query: [],
            body: Optional<String>.none
        )
        let (bytes, response) = try await session.bytes(for: request)
        let boundedMaximum = min(max(1, maximumBytes), CoFleetPetAsset.maximumByteCount)
        if response.expectedContentLength > Int64(boundedMaximum) {
            throw CoFleetTransportLimitError.responseBodyTooLarge(maxBytes: boundedMaximum)
        }
        var body = CoFleetBoundedBodyAccumulator(maximumBytes: boundedMaximum)
        for try await byte in bytes {
            try Task.checkCancellation()
            try body.append(byte)
        }
        let data = body.data
        try Self.validate(response: response, data: data)
        let mediaType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init) ?? "application/octet-stream"
        return CoFleetRawResponse(data: data, mediaType: mediaType)
    }

    public func post<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body,
        idempotencyKey: UUID? = nil,
        authenticated: Bool = true
    ) async throws -> Response {
        var request = try await makeRequest(
            method: "POST",
            path: path,
            query: [],
            body: body,
            authenticated: authenticated
        )
        if let idempotencyKey {
            request.setValue(idempotencyKey.uuidString, forHTTPHeaderField: "Idempotency-Key")
        }
        return try await send(request)
    }

    public func put<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body,
        ifMatch: String? = nil
    ) async throws -> Response {
        var request = try await makeRequest(method: "PUT", path: path, query: [], body: body)
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        return try await send(request)
    }

    public func patch<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        _ path: String,
        body: Body,
        ifMatch: String? = nil
    ) async throws -> Response {
        var request = try await makeRequest(method: "PATCH", path: path, query: [], body: body)
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        return try await send(request)
    }

    public func delete(_ path: String, ifMatch: String? = nil) async throws {
        var request = try await makeRequest(method: "DELETE", path: path, query: [], body: Optional<String>.none)
        if let ifMatch { request.setValue(ifMatch, forHTTPHeaderField: "If-Match") }
        let _: EmptyResponse = try await send(request, allowsEmptyBody: true)
    }

    public func eventStream(path: String, lastEventID: String?) async throws -> AsyncThrowingStream<CoFleetSSEEvent, Error> {
        var configuredRequest = try await makeRequest(method: "GET", path: path, query: [], body: Optional<String>.none)
        configuredRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if let lastEventID { configuredRequest.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        let request = configuredRequest
        let session = self.session
        let maximumLineBytes = maximumSSELineBytes
        let maximumEventBytes = maximumSSEEventBytes

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.validate(response: response, data: Data())
                    var parser = CoFleetSSEParser(
                        maximumLineBytes: maximumLineBytes,
                        maximumEventBytes: maximumEventBytes
                    )
                    var chunk = Data()
                    chunk.reserveCapacity(4_096)
                    for try await byte in bytes {
                        try Task.checkCancellation()
                        chunk.append(byte)
                        if byte == 0x0A || chunk.count == 4_096 {
                            for event in try parser.feed(chunk) { continuation.yield(event) }
                            chunk.removeAll(keepingCapacity: true)
                        }
                    }
                    if !chunk.isEmpty {
                        for event in try parser.feed(chunk) { continuation.yield(event) }
                    }
                    for event in try parser.finish() { continuation.yield(event) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest<Body: Encodable>(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: Body,
        authenticated: Bool = true
    ) async throws -> URLRequest {
        guard var components = URLComponents(
            url: endpoint.baseURL.appending(path: path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))),
            resolvingAgainstBaseURL: false
        ) else { throw CoFleetClientError.invalidResponse }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CoFleetClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if authenticated, let token = try await tokenProvider() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if method != "GET" && method != "DELETE" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try Self.encoder.encode(body)
        }
        return request
    }

    private func send<Response: Decodable & Sendable>(
        _ request: URLRequest,
        allowsEmptyBody: Bool = false
    ) async throws -> Response {
        let (bytes, response) = try await session.bytes(for: request)
        if response.expectedContentLength > Int64(maximumResponseBodyBytes) {
            throw CoFleetTransportLimitError.responseBodyTooLarge(maxBytes: maximumResponseBodyBytes)
        }
        var body = CoFleetBoundedBodyAccumulator(maximumBytes: maximumResponseBodyBytes)
        for try await byte in bytes {
            try Task.checkCancellation()
            try body.append(byte)
        }
        let data = body.data
        try Self.validate(response: response, data: data)
        if allowsEmptyBody, data.isEmpty, let empty = EmptyResponse() as? Response { return empty }
        do {
            return try Self.decoder.decode(Response.self, from: data)
        } catch {
            throw CoFleetClientError.transport("Could not decode the host response: \(error.localizedDescription)")
        }
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw CoFleetClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (
                try? decoder.decode(CoFleetAPIErrorEnvelope.self, from: data).error.message
            ) ?? (
                try? decoder.decode(CoFleetAPIError.self, from: data).message
            ) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            switch http.statusCode {
            case 401, 403: throw CoFleetClientError.unauthorized
            case 409, 412, 428: throw CoFleetClientError.conflict(detail)
            case 410: throw CoFleetClientError.expired(detail)
            case 426: throw CoFleetClientError.incompatible(detail)
            case 503: throw CoFleetClientError.unavailable(detail)
            default: throw CoFleetClientError.transport(detail)
            }
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

public struct CoFleetRawResponse: Hashable, Sendable {
    public var data: Data
    public var mediaType: String

    public init(data: Data, mediaType: String) {
        self.data = data
        self.mediaType = mediaType
    }
}

private struct EmptyResponse: Codable, Sendable {
    init() {}
}

private struct CoFleetAPIErrorEnvelope: Decodable, Sendable {
    var error: CoFleetAPIError
}
