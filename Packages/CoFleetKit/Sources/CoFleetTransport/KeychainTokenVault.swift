import CoFleetCore
import Foundation
import Security

public protocol CoFleetTokenVault: Sendable {
    func token(for hostID: CoFleetHostID) async throws -> String?
    func store(token: String, for hostID: CoFleetHostID) async throws
    func removeToken(for hostID: CoFleetHostID) async throws
}

public enum CoFleetPairingCredentialError: Error, Equatable, LocalizedError, Sendable {
    case rolledBack(storageError: String)
    case recoveryRequired(storageError: String, rollbackError: String)

    public var errorDescription: String? {
        switch self {
        case let .rolledBack(storageError):
            "The pairing code was redeemed, but Keychain could not save the device token. "
                + "CoFleet revoked the incomplete device pairing. Fix Keychain access and generate a new pairing code. "
                + storageError
        case let .recoveryRequired(storageError, rollbackError):
            "The pairing code was redeemed, but Keychain could not save the device token and the host could not revoke the incomplete pairing. "
                + "CoFleet is keeping the token only while this app remains open; do not quit before restoring Keychain access and rotating the token. "
                + "Keychain: \(storageError) Rollback: \(rollbackError)"
        }
    }
}

public actor CoFleetKeychainTokenVault: CoFleetTokenVault {
    private let service: String

    public init(service: String = "org.cofleet.host-pairing") {
        self.service = service
    }

    public func token(for hostID: CoFleetHostID) throws -> String? {
        var query = baseQuery(hostID: hostID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CoFleetClientError.transport("Keychain read failed (\(status)).")
        }
        return String(data: data, encoding: .utf8)
    }

    public func store(token: String, for hostID: CoFleetHostID) throws {
        let data = Data(token.utf8)
        var query = baseQuery(hostID: hostID)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw CoFleetClientError.transport("Keychain update failed (\(updateStatus)).")
        }
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CoFleetClientError.transport("Keychain write failed (\(addStatus)).")
        }
    }

    public func removeToken(for hostID: CoFleetHostID) throws {
        let status = SecItemDelete(baseQuery(hostID: hostID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CoFleetClientError.transport("Keychain deletion failed (\(status)).")
        }
    }

    private func baseQuery(hostID: CoFleetHostID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: hostID.rawValue,
        ]
    }
}

/// Keeps a newly rotated credential usable while it is being committed to secure storage.
/// If the Keychain write fails, the token remains available only for this process so the
/// caller can report the persistence failure without immediately stranding the host.
public actor CoFleetHostCredential {
    public let hostID: CoFleetHostID

    private let vault: any CoFleetTokenVault
    private var volatileToken: String?
    private var installGeneration = 0

    public init(hostID: CoFleetHostID, vault: any CoFleetTokenVault) {
        self.hostID = hostID
        self.vault = vault
    }

    public func token() async throws -> String? {
        if let volatileToken { return volatileToken }
        return try await vault.token(for: hostID)
    }

    public func install(token: String) async throws {
        installGeneration += 1
        let generation = installGeneration
        volatileToken = token
        do {
            try await vault.store(token: token, for: hostID)
            if installGeneration == generation { volatileToken = nil }
        } catch {
            // Keep the server-issued token alive for this process. It is intentionally not
            // cleared until a later successful install or an explicit device removal.
            throw error
        }
    }

    public func installPairingToken(
        _ token: String,
        rollback: @Sendable () async throws -> Void
    ) async throws {
        installGeneration += 1
        let generation = installGeneration
        volatileToken = token
        do {
            try await vault.store(token: token, for: hostID)
            if installGeneration == generation { volatileToken = nil }
        } catch {
            let storageMessage = error.localizedDescription
            do {
                try await rollback()
            } catch {
                throw CoFleetPairingCredentialError.recoveryRequired(
                    storageError: storageMessage,
                    rollbackError: error.localizedDescription
                )
            }
            // The server no longer accepts the new token. Clear only the volatile
            // replacement so a pre-existing durable pairing remains untouched.
            if installGeneration == generation { volatileToken = nil }
            throw CoFleetPairingCredentialError.rolledBack(storageError: storageMessage)
        }
    }

    public func remove() async throws {
        installGeneration += 1
        volatileToken = nil
        try await vault.removeToken(for: hostID)
    }
}
