import CoFleetCore
import Foundation

public struct CodexRPCRequest<Params: Encodable & Sendable>: Encodable, Sendable {
    public var id: Int
    public var method: String
    public var params: Params

    public init(id: Int, method: String, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct CodexRPCResponse<Result: Decodable & Sendable>: Decodable, Sendable {
    public struct Failure: Decodable, Sendable {
        public var code: Int
        public var message: String
    }

    public var id: Int
    public var result: Result?
    public var error: Failure?
}

public struct CodexNotification<Params: Decodable & Sendable>: Decodable, Sendable {
    public var method: String
    public var params: Params
}

public struct CodexThreadListParams: Codable, Hashable, Sendable {
    public var cursor: String?
    public var limit: Int
    public var cwd: String?
    public var archived: Bool
    public var sortKey: String

    public init(cursor: String? = nil, limit: Int = 5, cwd: String? = nil, archived: Bool = false) {
        self.cursor = cursor
        self.limit = min(5, max(1, limit))
        self.cwd = cwd
        self.archived = archived
        sortKey = "updated_at"
    }
}

public struct CodexTurnStartParams: Codable, Hashable, Sendable {
    public var threadID: String
    public var prompt: String
    public var model: String?
    public var effort: String?
    public var serviceTier: String?
    public var sandbox: String
    public var approvalPolicy: String

    public init(threadID: String, prompt: String, settings: CoFleetSessionSettings) {
        self.threadID = threadID
        self.prompt = prompt
        model = settings.modelID
        effort = settings.reasoningEffort
        serviceTier = settings.serviceTier
        let profile = settings.accessLevel.codexPermissionProfile
        sandbox = profile.sandbox.rawValue
        approvalPolicy = profile.approvalPolicy.rawValue
    }
}

public enum CodexDeepLinkResolver {
    public static func localThreadURL(session: CoFleetSessionSummary, localHostID: CoFleetHostID) -> URL? {
        guard session.hostID == localHostID else { return nil }
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(session.id)"
        return components.url
    }
}
