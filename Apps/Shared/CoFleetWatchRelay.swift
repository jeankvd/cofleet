#if os(iOS) || os(watchOS)
import CoFleetCore
import CoFleetTransport
import CoFleetUI
import Combine
import Foundation
import UserNotifications
@preconcurrency import WatchConnectivity

#if os(iOS)
import CoreGraphics
import ImageIO
#endif

#if canImport(WidgetKit)
import WidgetKit
#endif

private enum CoFleetWatchConnectivityKeys {
    static let payload = "cofleet.relay.payload.v1"
    static let snapshot = "cofleet.relay.snapshot.v1"
    static let delivery = "cofleet.relay.delivery.v1"
}

private enum CoFleetWatchRelayRuntimeError: LocalizedError, Equatable {
    case projectUnavailable
    case sessionUnavailable
    case todoUnavailable
    case turnEndedWithoutReply
    case turnTimedOut

    var errorDescription: String? {
        switch self {
        case .projectUnavailable: "The selected project is not available on its paired host."
        case .sessionUnavailable: "No Codex session is available for this project."
        case .todoUnavailable: "There is no pending todo to complete."
        case .turnEndedWithoutReply: "Codex finished without returning an assistant message."
        case .turnTimedOut: "The reply is still running. CoFleet will restore it when iPhone reconnects."
        }
    }
}

#if os(iOS)
@MainActor
final class CoFleetPhoneRelay: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var lastErrorMessage: String?

    private let controller: CoFleetAppController
    private let connectivitySession: WCSession?
    private let deliveryStore: CoFleetWatchDeliveryStore
    private let snapshotStore: CoFleetWatchSnapshotStore
    private var processing: Set<UUID> = []
    private var scheduledSnapshotTask: Task<Void, Never>?
    private var latestSnapshot: CoFleetWatchSnapshot?
    private var latestSnapshotData: Data?
    private var latestDeliveryData: Data?

    init(
        controller: CoFleetAppController,
        connectivitySession: WCSession? = WCSession.isSupported() ? .default : nil,
        deliveryStore: CoFleetWatchDeliveryStore = .init(fileURL: CoFleetSharedFiles.watchDeliveryURL),
        snapshotStore: CoFleetWatchSnapshotStore = .init(fileURL: CoFleetSharedFiles.watchSnapshotURL)
    ) {
        self.controller = controller
        self.connectivitySession = connectivitySession
        self.deliveryStore = deliveryStore
        self.snapshotStore = snapshotStore
        super.init()
        connectivitySession?.delegate = self
        connectivitySession?.activate()
    }

    deinit {
        scheduledSnapshotTask?.cancel()
    }

    func resumeAndPublish() async {
        if latestSnapshot == nil {
            let restored = await snapshotStore.load()
            if !restored.projects.isEmpty {
                latestSnapshot = restored
                latestSnapshotData = try? CoFleetWatchRelayCodec.encode(.init(snapshot: restored))
            }
        }
        await recoverPendingDeliveries()
        await publishSnapshot()
    }

    /// Coalesces bursty provider events into one credential-free Watch snapshot. This path only
    /// reads the controller's event-projected caches; it never polls a host or reloads a catalog.
    func scheduleProjectedSnapshotPublish() {
        scheduledSnapshotTask?.cancel()
        scheduledSnapshotTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            await self.publishProjectedSnapshot()
            self.scheduledSnapshotTask = nil
        }
    }

    func publishSnapshot() async {
        scheduledSnapshotTask?.cancel()
        scheduledSnapshotTask = nil
        if controller.fleetStore.projects.isEmpty {
            await controller.fleetStore.refresh()
        }
        let projects = Array(controller.fleetStore.visibleProjects.prefix(CoFleetWatchRelayCodec.maximumProjects))
        let hosts = Dictionary(uniqueKeysWithValues: controller.fleetStore.hosts.map { ($0.id, $0) })
        let cachedPreviews = controller.threadStore.latestPreviewByProjectID
        let selectedProjectID = controller.fleetStore.selectedProjectID
        let selectedSessionID = controller.threadStore.selectedSessionID
        let previousByID = Dictionary(uniqueKeysWithValues: (latestSnapshot?.projects ?? []).map { ($0.id, $0) })
        let activityByProjectID = Dictionary(uniqueKeysWithValues: projects.compactMap { project in
            controller.fleetStore.activity(for: project.id).map { (project.id, $0) }
        })
        let actions = Dictionary(uniqueKeysWithValues: projects.map { project in
            let action = activityByProjectID[project.id]
                .map { CoFleetWatchPresentationPolicy.action(for: $0.activity) }
                ?? CoFleetWatchPresentationPolicy.action(for: project.state)
            return (project.id, action)
        })
        let repository = controller.repository
        let petPreviews = await loadPetPreviews(for: projects, repository: repository)

        let projectSnapshots = await withTaskGroup(
            of: CoFleetWatchProjectSnapshot.self,
            returning: [CoFleetWatchProjectSnapshot].self
        ) { group in
            for project in projects {
                group.addTask {
                    let previous = previousByID[project.id]
                    let cachedPreview = cachedPreviews[project.id]
                    let preferredSessionID = (project.id == selectedProjectID ? selectedSessionID : nil)
                        ?? activityByProjectID[project.id]?.sessionID
                        ?? project.currentSessionID
                        ?? cachedPreview?.session.id
                    let page = try? await repository.fetchSessions(
                        hostID: project.hostID,
                        projectID: project.id,
                        cursor: nil,
                        limit: 5,
                        archived: false
                    )
                    let session = preferredSessionID.flatMap { sessionID in
                        page?.items.first { $0.id == sessionID }
                            ?? (cachedPreview?.session.id == sessionID ? cachedPreview?.session : nil)
                    } ?? cachedPreview?.session ?? page?.items.first
                    let sessionID = preferredSessionID ?? session?.id
                    let cachedLatestMessage: String? = sessionID.flatMap { sessionID in
                        guard cachedPreview?.session.id == sessionID else { return nil }
                        return cachedPreview?.messages.last(where: { $0.kind == .assistantMessage })?.text
                            ?? cachedPreview?.session.preview
                    }
                    let todos = try? await repository.fetchTodos(
                        hostID: project.hostID,
                        projectID: project.id
                    )
                    let pendingTodos = todos?.filter { !$0.isCompleted }
                    return CoFleetWatchProjectSnapshot(
                        id: project.id,
                        hostID: project.hostID,
                        sessionID: sessionID,
                        name: project.displayName,
                        hostReachability: hosts[project.hostID]?.reachability ?? .unknown,
                        action: actions[project.id] ?? .idle,
                        latestMessage: Self.truncatedPreview(
                            cachedLatestMessage ?? session?.preview ?? previous?.latestMessage,
                            maximumBytes: 1_024
                        ),
                        pendingTodoCount: pendingTodos?.count ?? previous?.pendingTodoCount ?? 0,
                        nextPendingTodoID: pendingTodos?.first?.id ?? previous?.nextPendingTodoID,
                        selectedPetID: project.selectedPetID,
                        petPreview: petPreviews[project.id]
                            ?? (previous?.selectedPetID == project.selectedPetID ? previous?.petPreview : nil),
                        sourceControl: project.sourceControl
                    )
                }
            }

            var snapshotsByID: [String: CoFleetWatchProjectSnapshot] = [:]
            for await snapshot in group { snapshotsByID[snapshot.id] = snapshot }
            return projects.compactMap { snapshotsByID[$0.id] }
        }

        let snapshot = CoFleetWatchSnapshot(
            projects: projectSnapshots,
            focusedProjectID: controller.fleetStore.selectedProjectID
        )
        await publish(snapshot)
    }

    private func publishProjectedSnapshot() async {
        guard let latestSnapshot else {
            await publishSnapshot()
            return
        }

        let projects = Array(controller.fleetStore.visibleProjects.prefix(CoFleetWatchRelayCodec.maximumProjects))
        let hosts = Dictionary(uniqueKeysWithValues: controller.fleetStore.hosts.map { ($0.id, $0) })
        let cachedPreviews = controller.threadStore.latestPreviewByProjectID
        let selectedProjectID = controller.fleetStore.selectedProjectID
        let selectedSessionID = controller.threadStore.selectedSessionID
        let previousByID = Dictionary(uniqueKeysWithValues: latestSnapshot.projects.map { ($0.id, $0) })
        let activityByProjectID = Dictionary(uniqueKeysWithValues: projects.compactMap { project in
            controller.fleetStore.activity(for: project.id).map { (project.id, $0) }
        })

        let projectedProjects = projects.map { project in
            let previous = previousByID[project.id]
            let cachedPreview = cachedPreviews[project.id]
            let sessionID = (project.id == selectedProjectID ? selectedSessionID : nil)
                ?? activityByProjectID[project.id]?.sessionID
                ?? project.currentSessionID
                ?? cachedPreview?.session.id
                ?? previous?.sessionID
            let cachedLatestMessage: String? = sessionID.flatMap { sessionID in
                guard cachedPreview?.session.id == sessionID else { return nil }
                return cachedPreview?.messages.last(where: { $0.kind == .assistantMessage })?.text
                    ?? cachedPreview?.session.preview
            }
            let action = activityByProjectID[project.id]
                .map { CoFleetWatchPresentationPolicy.action(for: $0.activity) }
                ?? CoFleetWatchPresentationPolicy.action(for: project.state)
            // Streaming text can change for every token. Watch only needs the meaningful action
            // transitions; publish the canonical message once the assistant reply completes.
            let latestMessage = action == .replied || previous == nil
                ? (cachedLatestMessage ?? previous?.latestMessage)
                : previous?.latestMessage
            return CoFleetWatchProjectSnapshot(
                id: project.id,
                hostID: project.hostID,
                sessionID: sessionID,
                name: project.displayName,
                hostReachability: hosts[project.hostID]?.reachability ?? .unknown,
                action: action,
                latestMessage: Self.truncatedPreview(
                    latestMessage,
                    maximumBytes: 1_024
                ),
                pendingTodoCount: previous?.pendingTodoCount ?? 0,
                nextPendingTodoID: previous?.nextPendingTodoID,
                selectedPetID: project.selectedPetID,
                petPreview: previous?.selectedPetID == project.selectedPetID ? previous?.petPreview : nil,
                sourceControl: project.sourceControl
            )
        }

        await publish(CoFleetWatchSnapshot(
            projects: projectedProjects,
            focusedProjectID: selectedProjectID,
            mode: latestSnapshot.mode
        ))
    }

    private func publish(_ candidate: CoFleetWatchSnapshot) async {
        guard CoFleetWatchPresentationPolicy.snapshotContentChanged(
            from: latestSnapshot,
            to: candidate
        ) else { return }

        var snapshot = candidate
        snapshot.generatedAt = .now
        do {
            try await snapshotStore.save(snapshot)
            let data = try CoFleetWatchRelayCodec.encode(.init(snapshot: snapshot))
            latestSnapshot = snapshot
            latestSnapshotData = data
            try updateApplicationContext()
            WidgetCenter.shared.reloadAllTimelines()
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func recoverPendingDeliveries() async {
        for delivery in await deliveryStore.pendingForRecovery() {
            guard !processing.contains(delivery.id) else { continue }
            if delivery.state == .running,
               let sessionID = delivery.sessionID,
               let turnID = delivery.turnID {
                processing.insert(delivery.id)
                Task { @MainActor [weak self] in
                    await self?.recoverRunningTurn(delivery, sessionID: sessionID, turnID: turnID)
                }
            } else if let request = delivery.request {
                await accept(request)
            }
        }
    }

    private func accept(_ request: CoFleetWatchRequest) async {
        guard !processing.contains(request.id) else { return }
        if let existing = await deliveryStore.delivery(id: request.id) {
            if existing.state == .completed || existing.state == .failed || existing.state == .notified {
                await publish(existing)
                return
            }
            if existing.state == .running,
               request.kind == .startTurn,
               let sessionID = existing.sessionID,
               let turnID = existing.turnID {
                processing.insert(request.id)
                await recoverRunningTurn(existing, sessionID: sessionID, turnID: turnID)
                return
            }
        }

        processing.insert(request.id)
        var delivery = CoFleetWatchDelivery(
            id: request.id,
            hostID: request.hostID,
            projectID: request.projectID,
            sessionID: request.sessionID,
            state: .pending,
            request: request
        )
        do {
            try await deliveryStore.upsert(delivery)
            switch request.kind {
            case .startTurn:
                try await routeTurn(request, delivery: &delivery)
            case .toggleTodo:
                try await routeTodo(request, delivery: &delivery)
            }
        } catch {
            delivery.state = error is CoFleetWatchRelayRuntimeError
                && (error as? CoFleetWatchRelayRuntimeError) == .turnTimedOut
                ? .running
                : .failed
            delivery.errorMessage = error.localizedDescription
            if delivery.state == .failed { delivery.request = nil }
            delivery.updatedAt = .now
            try? await deliveryStore.upsert(delivery)
            await publish(delivery)
        }
        processing.remove(request.id)
        if request.kind == .toggleTodo {
            await publishSnapshot()
        }
    }

    private func routeTurn(
        _ request: CoFleetWatchRequest,
        delivery: inout CoFleetWatchDelivery
    ) async throws {
        let project = try await resolvedProject(for: request)
        let sessionPage = try await controller.repository.fetchSessions(
            hostID: request.hostID,
            projectID: request.projectID,
            cursor: nil,
            limit: 5,
            archived: false
        )
        var settings = CoFleetSessionSettings()
        let sessionID: String
        if let requestedSessionID = request.sessionID {
            sessionID = requestedSessionID
            settings = sessionPage.items.first { $0.id == requestedSessionID }?.settings ?? settings
        } else if let currentSessionID = project.currentSessionID {
            sessionID = currentSessionID
            settings = sessionPage.items.first { $0.id == currentSessionID }?.settings ?? settings
        } else if let latest = sessionPage.items.first {
            sessionID = latest.id
            settings = latest.settings
        } else {
            let created = try await controller.repository.createSession(
                hostID: request.hostID,
                projectID: request.projectID
            )
            sessionID = created.id
            settings = created.settings
        }

        guard let prompt = request.prompt else { throw CoFleetWatchRelayValidationError.promptRequired }
        _ = try await controller.repository.resumeSession(
            hostID: request.hostID,
            projectID: request.projectID,
            sessionID: sessionID,
            settings: settings
        )
        let turn = try await controller.repository.startTurn(
            hostID: request.hostID,
            projectID: request.projectID,
            sessionID: sessionID,
            input: [.text(prompt)],
            settings: settings,
            idempotencyKey: request.id
        )
        delivery.sessionID = sessionID
        delivery.turnID = turn.id
        delivery.state = .running
        delivery.request = nil
        delivery.updatedAt = .now
        try await deliveryStore.upsert(delivery)
        await publish(delivery)

        let response = try await waitForReply(
            hostID: request.hostID,
            sessionID: sessionID,
            turnID: turn.id
        )
        delivery.state = .completed
        delivery.responsePreview = Self.truncatedPreview(response)
        delivery.updatedAt = .now
        try await deliveryStore.upsert(delivery)
        await publish(delivery)
    }

    private func routeTodo(
        _ request: CoFleetWatchRequest,
        delivery: inout CoFleetWatchDelivery
    ) async throws {
        _ = try await resolvedProject(for: request)
        delivery.state = .running
        delivery.updatedAt = .now
        try await deliveryStore.upsert(delivery)

        let todos = try await controller.repository.fetchTodos(
            hostID: request.hostID,
            projectID: request.projectID
        )
        guard var todo = request.todoID.flatMap({ id in todos.first { $0.id == id } })
                ?? todos.first(where: { !$0.isCompleted }) else {
            throw CoFleetWatchRelayRuntimeError.todoUnavailable
        }
        if !todo.isCompleted {
            todo.isCompleted = true
            todo = try await controller.repository.saveTodo(todo, expectedETag: todo.eTag)
        }
        delivery.state = .completed
        delivery.responsePreview = "Completed: \(todo.title)"
        delivery.request = nil
        delivery.updatedAt = .now
        try await deliveryStore.upsert(delivery)
        await publish(delivery)
    }

    private func recoverRunningTurn(
        _ delivery: CoFleetWatchDelivery,
        sessionID: String,
        turnID: String
    ) async {
        var recovered = delivery
        do {
            recovered.responsePreview = Self.truncatedPreview(try await waitForReply(
                hostID: delivery.hostID,
                sessionID: sessionID,
                turnID: turnID
            ))
            recovered.state = .completed
            recovered.errorMessage = nil
        } catch {
            recovered.state = error is CoFleetWatchRelayRuntimeError
                && (error as? CoFleetWatchRelayRuntimeError) == .turnTimedOut
                ? .running
                : .failed
            recovered.errorMessage = error.localizedDescription
        }
        if recovered.state != .running { recovered.request = nil }
        recovered.updatedAt = .now
        try? await deliveryStore.upsert(recovered)
        processing.remove(delivery.id)
        await publish(recovered)
    }

    private func resolvedProject(for request: CoFleetWatchRequest) async throws -> CoFleetProject {
        let projects = try await controller.repository.fetchProjects()
        guard let project = projects.first(where: {
            $0.id == request.projectID && $0.hostID == request.hostID
        }) else {
            throw CoFleetWatchRelayRuntimeError.projectUnavailable
        }
        return project
    }

    private func waitForReply(
        hostID: CoFleetHostID,
        sessionID: String,
        turnID: String
    ) async throws -> String {
        let repository = controller.repository
        if let completed = try await Self.completedReply(
            repository: repository,
            hostID: hostID,
            sessionID: sessionID,
            turnID: turnID
        ) {
            return completed
        }

        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                let stream = try await repository.events(
                    hostID: hostID,
                    sessionID: sessionID,
                    afterEventID: nil
                )
                var latestReply: String?
                for try await sequenced in stream {
                    switch sequenced.event {
                    case let .upsertItem(item)
                        where item.turnID == turnID && item.kind == .assistantMessage:
                        latestReply = item.text
                        if item.state == .completed { return item.text }
                    case let .turn(turn)
                        where turn.id == turnID && [.completed, .failed, .interrupted].contains(turn.state):
                        if let reply = latestReply { return reply }
                        if let restored = try await Self.completedReply(
                            repository: repository,
                            hostID: hostID,
                            sessionID: sessionID,
                            turnID: turnID
                        ) {
                            return restored
                        }
                        throw CoFleetWatchRelayRuntimeError.turnEndedWithoutReply
                    case .resetRequired:
                        if let restored = try await Self.completedReply(
                            repository: repository,
                            hostID: hostID,
                            sessionID: sessionID,
                            turnID: turnID
                        ) {
                            return restored
                        }
                    default:
                        break
                    }
                }
                throw CoFleetWatchRelayRuntimeError.turnEndedWithoutReply
            }
            group.addTask {
                try await Task.sleep(for: .seconds(600))
                throw CoFleetWatchRelayRuntimeError.turnTimedOut
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else {
                throw CoFleetWatchRelayRuntimeError.turnEndedWithoutReply
            }
            return response
        }
    }

    private nonisolated static func completedReply(
        repository: CoFleetAppRepository,
        hostID: CoFleetHostID,
        sessionID: String,
        turnID: String
    ) async throws -> String? {
        try await repository.fetchTranscript(hostID: hostID, sessionID: sessionID)
            .last { item in
                item.turnID == turnID &&
                    item.kind == .assistantMessage &&
                    item.state == .completed
            }?.text
    }

    private func publish(_ delivery: CoFleetWatchDelivery) async {
        do {
            let data = try CoFleetWatchRelayCodec.encode(.init(delivery: delivery))
            latestDeliveryData = data
            connectivitySession?.transferUserInfo([CoFleetWatchConnectivityKeys.payload: data])
            if connectivitySession?.isReachable == true {
                connectivitySession?.sendMessage(
                    [CoFleetWatchConnectivityKeys.payload: data],
                    replyHandler: nil,
                    errorHandler: nil
                )
            }
            try updateApplicationContext()
            await publishDeliverySnapshot(delivery)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func publishDeliverySnapshot(_ delivery: CoFleetWatchDelivery) async {
        guard var snapshot = latestSnapshot,
              let index = snapshot.projects.firstIndex(where: { $0.id == delivery.projectID }) else {
            return
        }
        if let sessionID = delivery.sessionID {
            snapshot.projects[index].sessionID = sessionID
        }
        switch delivery.state {
        case .pending, .running:
            snapshot.projects[index].action = .working
        case .completed, .notified:
            snapshot.projects[index].action = .replied
            if let responsePreview = delivery.responsePreview {
                snapshot.projects[index].latestMessage = responsePreview
            }
        case .failed:
            snapshot.projects[index].action = .idle
            if let errorMessage = delivery.errorMessage {
                snapshot.projects[index].latestMessage = errorMessage
            }
        }
        await publish(snapshot)
    }

    private func updateApplicationContext() throws {
        guard let connectivitySession else { return }
        var context: [String: Any] = [:]
        if let latestSnapshotData { context[CoFleetWatchConnectivityKeys.snapshot] = latestSnapshotData }
        if let latestDeliveryData { context[CoFleetWatchConnectivityKeys.delivery] = latestDeliveryData }
        if !context.isEmpty { try connectivitySession.updateApplicationContext(context) }
    }

    private nonisolated static func truncatedPreview(_ value: String?) -> String? {
        truncatedPreview(value, maximumBytes: CoFleetWatchRelayCodec.maximumLatestMessageUTF8Bytes)
    }

    private nonisolated static func truncatedPreview(
        _ value: String?,
        maximumBytes: Int
    ) -> String? {
        guard let value else { return nil }
        var bytes = 0
        let scalars = value.unicodeScalars.prefix { scalar in
            let count = String(scalar).utf8.count
            guard bytes + count <= maximumBytes else { return false }
            bytes += count
            return true
        }
        return String(String.UnicodeScalarView(scalars))
    }

    private func loadPetPreviews(
        for projects: [CoFleetProject],
        repository: CoFleetAppRepository
    ) async -> [String: CoFleetPetPreview] {
        var candidates: [CoFleetProject] = []
        if let focusedID = controller.fleetStore.selectedProjectID,
           let focused = projects.first(where: { $0.id == focusedID }),
           focused.selectedPetID != nil {
            candidates.append(focused)
        }
        for project in projects where project.selectedPetID != nil {
            guard candidates.count < CoFleetWatchRelayCodec.maximumPetPreviews else { break }
            if !candidates.contains(where: { $0.id == project.id }) { candidates.append(project) }
        }

        var manifestsByHost: [CoFleetHostID: [CoFleetPetManifest]] = [:]
        var previews: [String: CoFleetPetPreview] = [:]
        for project in candidates {
            guard let petID = project.selectedPetID else { continue }
            let manifests: [CoFleetPetManifest]
            if let cached = manifestsByHost[project.hostID] {
                manifests = cached
            } else {
                manifests = (try? await repository.fetchPets(hostID: project.hostID)) ?? []
                manifestsByHost[project.hostID] = manifests
            }
            guard let manifest = manifests.first(where: { $0.id == petID }),
                  let asset = try? await repository.fetchPetAsset(
                      hostID: project.hostID,
                      petID: petID,
                      assetName: manifest.spritesheetPath
                  ),
                  let preview = Self.makePetPreview(manifest: manifest, asset: asset) else { continue }
            previews[project.id] = preview
        }
        return previews
    }

    private nonisolated static func makePetPreview(
        manifest: CoFleetPetManifest,
        asset: CoFleetPetAsset
    ) -> CoFleetPetPreview? {
        guard (try? CoFleetPetManifestValidator.validate(manifest)) != nil,
              manifest.hostID == asset.hostID,
              manifest.id == asset.petID,
              manifest.spritesheetPath == asset.assetName,
              let source = CGImageSourceCreateWithData(asset.data as CFData, nil),
              let atlas = CGImageSourceCreateImageAtIndex(source, 0, [
                  kCGImageSourceShouldCache: false,
                  kCGImageSourceShouldAllowFloat: false,
              ] as CFDictionary),
              atlas.width == manifest.pixelWidth,
              atlas.height == manifest.pixelHeight,
              let frame = atlas.cropping(to: CGRect(
                  x: 0,
                  y: 0,
                  width: manifest.frameWidth,
                  height: manifest.frameHeight
              )) else { return nil }

        // Exactly half-size preserves the source pixel grid while keeping the snapshot compact.
        let width = manifest.frameWidth / 2
        let height = manifest.frameHeight / 2
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .none
        context.draw(frame, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let rendered = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, rendered, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let preview = CoFleetPetPreview(
            petID: manifest.id,
            pixelWidth: width,
            pixelHeight: height,
            digest: manifest.digest,
            data: output as Data
        )
        guard (try? CoFleetWatchRelayCodec.validate(preview, selectedPetID: manifest.id)) != nil else {
            return nil
        }
        return preview
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor [weak self] in self?.lastErrorMessage = error.localizedDescription }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let data = message[CoFleetWatchConnectivityKeys.payload] as? Data,
              let payload = try? CoFleetWatchRelayCodec.decode(data),
              let request = payload.request,
              payload.kind == .request else {
            replyHandler(["accepted": false])
            return
        }
        replyHandler(["accepted": true])
        Task { @MainActor [weak self] in await self?.accept(request) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[CoFleetWatchConnectivityKeys.payload] as? Data,
              let payload = try? CoFleetWatchRelayCodec.decode(data),
              let request = payload.request,
              payload.kind == .request else { return }
        Task { @MainActor [weak self] in await self?.accept(request) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[CoFleetWatchConnectivityKeys.payload] as? Data,
              let payload = try? CoFleetWatchRelayCodec.decode(data),
              let request = payload.request,
              payload.kind == .request else { return }
        Task { @MainActor [weak self] in await self?.accept(request) }
    }
}
#endif

#if os(watchOS)
import WatchKit

@MainActor
final class CoFleetWatchRelay: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var snapshot = CoFleetWatchSnapshot.empty
    @Published private(set) var lastErrorMessage: String?

    private let connectivitySession: WCSession?
    private let deliveryStore: CoFleetWatchDeliveryStore
    private let snapshotStore: CoFleetWatchSnapshotStore
    private var notifiedDeliveryIDs: Set<UUID> = []
    private var notifiedReplySignatures: Set<String> = []

    override init() {
        connectivitySession = WCSession.isSupported() ? .default : nil
        deliveryStore = .init(fileURL: CoFleetSharedFiles.watchDeliveryURL)
        snapshotStore = .init(fileURL: CoFleetSharedFiles.watchSnapshotURL)
        super.init()
        connectivitySession?.delegate = self
        connectivitySession?.activate()
        Task { @MainActor [weak self] in await self?.restore() }
    }

    func dismissError() {
        lastErrorMessage = nil
    }

    func send(project: CoFleetWatchProjectSnapshot, prompt: String) {
        guard let hostID = project.hostID else {
            lastErrorMessage = CoFleetWatchRelayRuntimeError.projectUnavailable.localizedDescription
            return
        }
        let request = CoFleetWatchRequest(
            kind: .startTurn,
            hostID: hostID,
            projectID: project.id,
            sessionID: project.sessionID,
            prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        enqueue(request)
    }

    func toggleTodo(project: CoFleetWatchProjectSnapshot) {
        guard let hostID = project.hostID else {
            lastErrorMessage = CoFleetWatchRelayRuntimeError.projectUnavailable.localizedDescription
            return
        }
        enqueue(CoFleetWatchRequest(
            kind: .toggleTodo,
            hostID: hostID,
            projectID: project.id,
            sessionID: project.sessionID,
            todoID: project.nextPendingTodoID
        ))
    }

    private func enqueue(_ request: CoFleetWatchRequest) {
        do {
            let data = try CoFleetWatchRelayCodec.encode(.init(request: request))
            let delivery = CoFleetWatchDelivery(
                id: request.id,
                hostID: request.hostID,
                projectID: request.projectID,
                sessionID: request.sessionID,
                state: .pending,
                request: request
            )
            Task { try? await deliveryStore.upsert(delivery) }
            connectivitySession?.transferUserInfo([CoFleetWatchConnectivityKeys.payload: data])
            if connectivitySession?.isReachable == true {
                connectivitySession?.sendMessage(
                    [CoFleetWatchConnectivityKeys.payload: data],
                    replyHandler: nil,
                    errorHandler: { _ in }
                )
            }
            updateProject(projectID: request.projectID, action: .working, latestMessage: nil)
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func restore() async {
        snapshot = await snapshotStore.load()
        await deliveryStore.load()
        let deliveries = await deliveryStore.all()
        notifiedDeliveryIDs = Set(deliveries.filter { $0.state == .notified }.map(\.id))
        for delivery in deliveries.reversed() {
            let needsNotification = delivery.state == .completed
                && !notifiedDeliveryIDs.contains(delivery.id)
            if CoFleetWatchPresentationPolicy.shouldReapplyDelivery(
                state: delivery.state,
                deliveryUpdatedAt: delivery.updatedAt,
                snapshotGeneratedAt: snapshot.generatedAt
            ) {
                apply(delivery, notify: needsNotification)
            } else if needsNotification {
                notifyCompletion(delivery)
            }
        }
        for project in snapshot.projects where project.action == .replied {
            if let signature = replySignature(
                projectID: project.id,
                sessionID: project.sessionID,
                preview: project.latestMessage
            ) {
                notifiedReplySignatures.insert(signature)
            }
        }
        requestNotificationAuthorization()
    }

    private func receive(_ data: Data) async {
        do {
            let payload = try CoFleetWatchRelayCodec.decode(data)
            switch payload.kind {
            case .snapshot:
                guard let received = payload.snapshot else { return }
                let previousSnapshot = snapshot
                snapshot = received
                for delivery in (await deliveryStore.all()).reversed()
                    where CoFleetWatchPresentationPolicy.shouldReapplyDelivery(
                        state: delivery.state,
                        deliveryUpdatedAt: delivery.updatedAt,
                        snapshotGeneratedAt: received.generatedAt
                    ) {
                    apply(delivery, notify: false)
                }
                notifySnapshotCompletions(previous: previousSnapshot, current: snapshot)
                try await snapshotStore.save(snapshot)
                WidgetCenter.shared.reloadAllTimelines()
            case .delivery:
                guard let delivery = payload.delivery else { return }
                let previous = await deliveryStore.delivery(id: delivery.id)
                try await deliveryStore.upsert(delivery)
                apply(delivery, notify: delivery.state == .completed && previous?.state != .notified)
            case .request:
                break
            }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    private func apply(_ delivery: CoFleetWatchDelivery, notify: Bool) {
        switch delivery.state {
        case .pending, .running:
            updateProject(
                projectID: delivery.projectID,
                sessionID: delivery.sessionID,
                action: .working,
                latestMessage: nil
            )
        case .completed, .notified:
            updateProject(
                projectID: delivery.projectID,
                sessionID: delivery.sessionID,
                action: .replied,
                latestMessage: delivery.responsePreview
            )
            if notify { notifyCompletion(delivery) }
        case .failed:
            updateProject(
                projectID: delivery.projectID,
                sessionID: delivery.sessionID,
                action: .idle,
                latestMessage: delivery.errorMessage
            )
        }
    }

    private func updateProject(
        projectID: String,
        sessionID: String? = nil,
        action: CoFleetActionIndicator,
        latestMessage: String?
    ) {
        guard let index = snapshot.projects.firstIndex(where: { $0.id == projectID }) else { return }
        if let sessionID { snapshot.projects[index].sessionID = sessionID }
        snapshot.projects[index].action = action
        if let latestMessage { snapshot.projects[index].latestMessage = latestMessage }
        snapshot.generatedAt = .now
        let updated = snapshot
        Task {
            try? await snapshotStore.save(updated)
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private func requestNotificationAuthorization() {
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        }
    }

    private func notifyCompletion(_ delivery: CoFleetWatchDelivery) {
        guard notifiedDeliveryIDs.insert(delivery.id).inserted else { return }
        let shouldAlert = replySignature(
            projectID: delivery.projectID,
            sessionID: delivery.sessionID,
            preview: delivery.responsePreview
        ).map { notifiedReplySignatures.insert($0).inserted } ?? true
        if shouldAlert {
            notifyReply(
                title: "CoFleet reply",
                body: delivery.responsePreview ?? "Codex finished the turn.",
                identifier: "cofleet-watch-\(delivery.id.uuidString)"
            )
        }
        markNotified(delivery)
    }

    private func notifySnapshotCompletions(
        previous: CoFleetWatchSnapshot,
        current: CoFleetWatchSnapshot
    ) {
        let previousByID = Dictionary(uniqueKeysWithValues: previous.projects.map { ($0.id, $0) })
        for project in current.projects where project.action == .replied {
            guard CoFleetWatchPresentationPolicy.shouldNotifyReply(
                      previous: previousByID[project.id],
                      current: project
                  ),
                  let preview = project.latestMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let signature = replySignature(
                      projectID: project.id,
                      sessionID: project.sessionID,
                      preview: preview
                  ),
                  notifiedReplySignatures.insert(signature).inserted else { continue }
            notifyReply(
                title: project.name,
                body: preview,
                identifier: "cofleet-watch-reply-\(project.id)-\(project.sessionID ?? "latest")"
            )
        }
    }

    private func notifyReply(title: String, body: String, identifier: String) {
        WKInterfaceDevice.current().play(.notification)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        Task {
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func markNotified(_ delivery: CoFleetWatchDelivery) {
        Task {
            var notified = delivery
            notified.state = .notified
            notified.updatedAt = .now
            try? await deliveryStore.upsert(notified)
        }
    }

    private func replySignature(
        projectID: String,
        sessionID: String?,
        preview: String?
    ) -> String? {
        guard let preview = preview?.trimmingCharacters(in: .whitespacesAndNewlines),
              !preview.isEmpty else { return nil }
        return "\(projectID)\u{1f}\(sessionID ?? "")\u{1f}\(preview)"
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard let error else { return }
        Task { @MainActor [weak self] in self?.lastErrorMessage = error.localizedDescription }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        guard let data = message[CoFleetWatchConnectivityKeys.payload] as? Data else {
            replyHandler(["accepted": false])
            return
        }
        replyHandler(["accepted": true])
        Task { @MainActor [weak self] in await self?.receive(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message[CoFleetWatchConnectivityKeys.payload] as? Data else { return }
        Task { @MainActor [weak self] in await self?.receive(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo[CoFleetWatchConnectivityKeys.payload] as? Data else { return }
        Task { @MainActor [weak self] in await self?.receive(data) }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let payloads = [
            applicationContext[CoFleetWatchConnectivityKeys.snapshot] as? Data,
            applicationContext[CoFleetWatchConnectivityKeys.delivery] as? Data,
        ].compactMap { $0 }
        for data in payloads {
            Task { @MainActor [weak self] in await self?.receive(data) }
        }
    }
}
#endif
#endif
