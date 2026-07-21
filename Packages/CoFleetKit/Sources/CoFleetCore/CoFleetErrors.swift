import Foundation

public struct CoFleetAPIError: Error, Codable, Hashable, Sendable, LocalizedError {
    public var code: String
    public var message: String
    public var retryAfterSeconds: Double?

    public init(code: String, message: String, retryAfterSeconds: Double? = nil) {
        self.code = code
        self.message = message
        self.retryAfterSeconds = retryAfterSeconds
    }

    public var errorDescription: String? { message }
}

public enum CoFleetClientError: Error, Equatable, LocalizedError {
    case invalidResponse
    case unauthorized
    case conflict(String)
    case expired(String)
    case incompatible(String)
    case unavailable(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "The host returned an invalid response."
        case .unauthorized: "This device is not authorized for the host."
        case let .conflict(message), let .expired(message), let .incompatible(message),
             let .unavailable(message), let .transport(message): message
        }
    }
}
