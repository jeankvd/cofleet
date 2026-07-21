import CoFleetCore
import Foundation
import ImageIO

public enum CoFleetWatchRelayValidationError: Error, Equatable, LocalizedError {
    case payloadTooLarge
    case unsupportedVersion
    case malformedPayload
    case invalidIdentifier
    case promptRequired
    case promptTooLarge
    case staleRequest
    case snapshotTooLarge
    case invalidPetPreview

    public var errorDescription: String? {
        switch self {
        case .payloadTooLarge: "The Watch relay payload is too large."
        case .unsupportedVersion: "The Watch relay payload version is unsupported."
        case .malformedPayload: "The Watch relay payload is malformed."
        case .invalidIdentifier: "The Watch relay payload contains an invalid identifier."
        case .promptRequired: "Enter a message before sending."
        case .promptTooLarge: "The Watch message is too long."
        case .staleRequest: "The Watch request is too old to process safely."
        case .snapshotTooLarge: "The Watch snapshot contains too much data."
        case .invalidPetPreview: "The Watch snapshot contains an invalid pet preview."
        }
    }
}

public enum CoFleetWatchRelayCodec {
    public static let maximumPayloadBytes = 256 * 1_024
    public static let maximumPromptUTF8Bytes = 8 * 1_024
    public static let maximumProjects = 64
    public static let maximumIdentifierUTF8Bytes = 512
    public static let maximumLatestMessageUTF8Bytes = 4 * 1_024
    public static let maximumRequestAge: TimeInterval = 24 * 60 * 60
    public static let maximumPetPreviews = 3
    public static let maximumPetPreviewAggregateBytes =
        maximumPetPreviews * CoFleetPetPreview.maximumByteCount

    public static func encode(_ payload: CoFleetWatchRelayPayload) throws -> Data {
        try validate(payload)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(payload)
        guard data.count <= maximumPayloadBytes else {
            throw CoFleetWatchRelayValidationError.payloadTooLarge
        }
        return data
    }

    public static func decode(_ data: Data, now: Date = .now) throws -> CoFleetWatchRelayPayload {
        guard data.count <= maximumPayloadBytes else {
            throw CoFleetWatchRelayValidationError.payloadTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload: CoFleetWatchRelayPayload
        do {
            payload = try decoder.decode(CoFleetWatchRelayPayload.self, from: data)
        } catch {
            throw CoFleetWatchRelayValidationError.malformedPayload
        }
        try validate(payload, now: now)
        return payload
    }

    public static func validate(_ payload: CoFleetWatchRelayPayload, now: Date = .now) throws {
        guard payload.version == 1 else {
            throw CoFleetWatchRelayValidationError.unsupportedVersion
        }
        switch payload.kind {
        case .request:
            guard let request = payload.request, payload.delivery == nil, payload.snapshot == nil else {
                throw CoFleetWatchRelayValidationError.malformedPayload
            }
            try validate(request, now: now)
        case .delivery:
            guard let delivery = payload.delivery, payload.request == nil, payload.snapshot == nil else {
                throw CoFleetWatchRelayValidationError.malformedPayload
            }
            try validateIdentifier(delivery.hostID.rawValue)
            try validateIdentifier(delivery.projectID)
            if let sessionID = delivery.sessionID { try validateIdentifier(sessionID) }
            if let preview = delivery.responsePreview,
               preview.utf8.count > maximumLatestMessageUTF8Bytes {
                throw CoFleetWatchRelayValidationError.snapshotTooLarge
            }
        case .snapshot:
            guard let snapshot = payload.snapshot, payload.request == nil, payload.delivery == nil else {
                throw CoFleetWatchRelayValidationError.malformedPayload
            }
            try validate(snapshot)
        }
    }

    public static func validate(_ request: CoFleetWatchRequest, now: Date = .now) throws {
        try validateIdentifier(request.hostID.rawValue)
        try validateIdentifier(request.projectID)
        if let sessionID = request.sessionID { try validateIdentifier(sessionID) }
        if let todoID = request.todoID { try validateIdentifier(todoID) }
        guard request.createdAt <= now.addingTimeInterval(5 * 60),
              now.timeIntervalSince(request.createdAt) <= maximumRequestAge else {
            throw CoFleetWatchRelayValidationError.staleRequest
        }

        switch request.kind {
        case .startTurn:
            let prompt = request.prompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !prompt.isEmpty else { throw CoFleetWatchRelayValidationError.promptRequired }
            guard prompt.utf8.count <= maximumPromptUTF8Bytes else {
                throw CoFleetWatchRelayValidationError.promptTooLarge
            }
            guard request.todoID == nil else { throw CoFleetWatchRelayValidationError.malformedPayload }
        case .toggleTodo:
            guard request.prompt == nil else { throw CoFleetWatchRelayValidationError.malformedPayload }
        }
    }

    public static func validate(_ snapshot: CoFleetWatchSnapshot) throws {
        guard snapshot.projects.count <= maximumProjects else {
            throw CoFleetWatchRelayValidationError.snapshotTooLarge
        }
        var previewCount = 0
        var previewBytes = 0
        for project in snapshot.projects {
            try validateIdentifier(project.id)
            if let hostID = project.hostID { try validateIdentifier(hostID.rawValue) }
            if let sessionID = project.sessionID { try validateIdentifier(sessionID) }
            if project.name.utf8.count > 256 ||
                (project.latestMessage?.utf8.count ?? 0) > maximumLatestMessageUTF8Bytes {
                throw CoFleetWatchRelayValidationError.snapshotTooLarge
            }
            if let preview = project.petPreview {
                previewCount += 1
                previewBytes += preview.data.count
                guard previewCount <= maximumPetPreviews,
                      previewBytes <= maximumPetPreviewAggregateBytes else {
                    throw CoFleetWatchRelayValidationError.snapshotTooLarge
                }
                try validate(preview, selectedPetID: project.selectedPetID)
            }
        }
    }

    public static func validate(
        _ preview: CoFleetPetPreview,
        selectedPetID: String? = nil
    ) throws {
        try validateIdentifier(preview.petID)
        guard selectedPetID == nil || selectedPetID == preview.petID,
              preview.mediaType == "image/png",
              (1...CoFleetPetPreview.maximumDimension).contains(preview.pixelWidth),
              (1...CoFleetPetPreview.maximumDimension).contains(preview.pixelHeight),
              !preview.data.isEmpty,
              preview.data.count <= CoFleetPetPreview.maximumByteCount,
              preview.digest.wholeMatch(of: /^[0-9a-f]{64}$/) != nil,
              let source = CGImageSourceCreateWithData(preview.data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.png",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == preview.pixelWidth,
              (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == preview.pixelHeight else {
            throw CoFleetWatchRelayValidationError.invalidPetPreview
        }
    }

    private static func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty,
              value.utf8.count <= maximumIdentifierUTF8Bytes,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CoFleetWatchRelayValidationError.invalidIdentifier
        }
    }
}

public actor CoFleetWatchSnapshotStore {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() -> CoFleetWatchSnapshot {
        guard fileSize(at: fileURL) <= CoFleetWatchRelayCodec.maximumPayloadBytes,
              let data = try? Data(contentsOf: fileURL),
              let snapshot = try? decoder.decode(CoFleetWatchSnapshot.self, from: data) else {
            return .empty
        }
        guard (try? CoFleetWatchRelayCodec.validate(snapshot)) != nil else { return .empty }
        return snapshot
    }

    public func save(_ snapshot: CoFleetWatchSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(snapshot)
        guard data.count <= CoFleetWatchRelayCodec.maximumPayloadBytes else {
            throw CoFleetWatchRelayValidationError.payloadTooLarge
        }
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func fileSize(at url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }
}

public actor CoFleetWatchDeliveryStore {
    private static let maximumStoredBytes = 1_024 * 1_024
    private let fileURL: URL
    private var deliveries: [CoFleetWatchDelivery] = []
    private var didLoad = false
    private let maximumDeliveries = 100

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() {
        loadIfNeeded(force: true)
    }

    private func loadIfNeeded(force: Bool = false) {
        guard force || !didLoad else { return }
        didLoad = true
        guard fileSize(at: fileURL) <= Self.maximumStoredBytes,
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([CoFleetWatchDelivery].self, from: data) else {
            deliveries = []
            return
        }
        deliveries = Array(decoded.sorted { $0.updatedAt > $1.updatedAt }.prefix(maximumDeliveries))
    }

    public func all() -> [CoFleetWatchDelivery] {
        loadIfNeeded()
        return deliveries
    }

    public func delivery(id: UUID) -> CoFleetWatchDelivery? {
        loadIfNeeded()
        return deliveries.first { $0.id == id }
    }

    public func upsert(_ delivery: CoFleetWatchDelivery) throws {
        loadIfNeeded()
        if let index = deliveries.firstIndex(where: { $0.id == delivery.id }) {
            deliveries[index] = delivery
        } else {
            deliveries.append(delivery)
        }
        deliveries = Array(deliveries.sorted { $0.updatedAt > $1.updatedAt }.prefix(maximumDeliveries))
        try persist()
    }

    public func completedNeedingNotification() -> [CoFleetWatchDelivery] {
        loadIfNeeded()
        return deliveries.filter { $0.state == .completed }
    }

    public func pendingForRecovery() -> [CoFleetWatchDelivery] {
        loadIfNeeded()
        return deliveries.filter { $0.state == .pending || $0.state == .running }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(deliveries)
        guard data.count <= Self.maximumStoredBytes else {
            throw CoFleetWatchRelayValidationError.payloadTooLarge
        }
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func fileSize(at url: URL) -> Int {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize ?? 0
    }
}
