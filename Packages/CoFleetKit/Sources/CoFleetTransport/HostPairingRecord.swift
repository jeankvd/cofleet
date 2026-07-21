import CoFleetCore
import Foundation

/// Non-secret metadata for a paired host. Bearer tokens are always stored separately
/// by `CoFleetTokenVault` and never encoded into this record.
public struct CoFleetStoredHostPairing: Codable, Sendable {
    public var host: CoFleetHostInfo
    public var endpoint: URL
    /// Optional so records written before device self-management continue to decode.
    public var deviceID: String?

    public init(host: CoFleetHostInfo, endpoint: URL, deviceID: String? = nil) {
        self.host = host
        self.endpoint = endpoint
        self.deviceID = deviceID
    }
}
