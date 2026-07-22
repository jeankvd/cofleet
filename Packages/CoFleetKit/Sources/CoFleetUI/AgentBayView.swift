import CoFleetCore
import SwiftUI
import UniformTypeIdentifiers

#if !os(watchOS)

public struct CoFleetAgentBayView: View {
    private static let initialMessagePageSize = 40
    private static let additionalMessagePageSize = 40
    private static let latestButtonDistance: CGFloat = 48
    private static let nearBottomDistance: CGFloat = 18

    @Bindable private var threadStore: ThreadStore
    @Bindable private var turnStore: TurnStore
    @Binding private var settings: CoFleetSessionSettings
    private let models: [CoFleetModelInfo]
    private let fleetStore: FleetStore?
    private let workspaceStore: WorkspaceStore?
    private let localHostID: CoFleetHostID?
    private let onHatchPet: (@MainActor (CoFleetProject) async throws -> Void)?

    @State private var showsSessions = false
    @State private var showsAddProject = false
    @State private var showsPetLibrary = false
    @State private var showsWorkspace = false
    @State private var showsRuntime = false
    @State private var showsImageURLPrompt = false
    @State private var showsLocalImagePicker = false
    @State private var imageURLDraft = ""
    @State private var composerErrorMessage: String?
    @State private var isPreparingSend = false
    @FocusState private var composerIsFocused: Bool
    @State private var messageLimitBySession: [String: Int] = [:]
    @State private var pendingHistoryAnchor: String?
    @State private var followsLatestMessage = true
    @State private var userIsDraggingConversation = false
    @State private var distanceFromConversationBottom: CGFloat = 0
    @State private var followScrollScheduled = false
    @State private var programmaticScrollGeneration = 0
    @AppStorage(CoFleetConversationPresentationSettings.rendersMarkdownKey)
    private var rendersMarkdown = CoFleetConversationPresentationSettings.rendersMarkdownDefault
    @AppStorage(CoFleetConversationPresentationSettings.tracePresentationKey)
    private var tracePresentationRawValue = CoFleetConversationPresentationSettings.tracePresentationDefault.rawValue

    public init(
        threadStore: ThreadStore,
        turnStore: TurnStore,
        settings: Binding<CoFleetSessionSettings>,
        models: [CoFleetModelInfo],
        fleetStore: FleetStore? = nil,
        workspaceStore: WorkspaceStore? = nil,
        localHostID: CoFleetHostID? = nil,
        onHatchPet: (@MainActor (CoFleetProject) async throws -> Void)? = nil
    ) {
        self.threadStore = threadStore
        self.turnStore = turnStore
        _settings = settings
        self.models = models
        self.fleetStore = fleetStore
        self.workspaceStore = workspaceStore
        self.localHostID = localHostID
        self.onHatchPet = onHatchPet
    }

    public var body: some View {
        ZStack {
            CoFleetTheme.agentBayBackground.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                Divider().opacity(0.3)
                conversation
                composer
            }
        }
        .sheet(isPresented: $showsSessions) {
            CoFleetSessionPicker(store: threadStore)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
        }
        .sheet(isPresented: $showsRuntime) {
            NavigationStack {
                CoFleetRuntimeControls(settings: $settings, models: models)
                    .navigationTitle("Codex Settings")
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsRuntime = false }
                        }
                    }
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            #endif
        }
        .sheet(isPresented: $showsAddProject) {
            if let fleetStore {
                CoFleetProjectRegistrationView(fleetStore: fleetStore)
            }
        }
        .sheet(isPresented: $showsPetLibrary) {
            if let fleetStore, let workspaceStore, let project = fleetStore.selectedProject {
                CoFleetPetLibraryView(
                    workspaceStore: workspaceStore,
                    project: project,
                    onProjectUpdated: fleetStore.applyProjectUpdate,
                    onHatchWithCodex: hatchAction(for: project)
                )
            }
        }
        .sheet(isPresented: $showsWorkspace) {
            if let workspaceStore, let project = selectedProject {
                CoFleetWorkspaceView(
                    workspaceStore: workspaceStore,
                    projectName: project.displayName
                )
            }
        }
        .alert("Add Image URL", isPresented: $showsImageURLPrompt) {
            TextField("https://example.com/image.png", text: $imageURLDraft)
                .textContentType(.URL)
            Button("Cancel", role: .cancel) { imageURLDraft = "" }
            Button("Add") { addImageURL() }
        } message: {
            Text("Use a public or host-reachable HTTPS image URL. Plain HTTP is intended only for trusted development hosts.")
        }
        #if os(macOS)
        .fileImporter(
            isPresented: $showsLocalImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            onCompletion: addLocalImages
        )
        #endif
        .onChange(of: turnStore.loadedSessionID) { _, _ in
            composerIsFocused = false
            pendingHistoryAnchor = nil
            followsLatestMessage = true
            userIsDraggingConversation = false
            distanceFromConversationBottom = 0
        }
    }

    private var conversation: some View {
        let entries = conversationEntries
        let visibleEntries = entries.suffix(min(currentMessageLimit, entries.count))
        let earlierCount = max(entries.count - currentMessageLimit, 0)
        let showsLatestButton = !visibleEntries.isEmpty
            && distanceFromConversationBottom > Self.latestButtonDistance

        return GeometryReader { viewport in
            ScrollViewReader { proxy in
                ZStack(alignment: .bottomTrailing) {
                    ScrollView {
                        // Manada intentionally pages a small regular stack. It is more
                        // stable than a lazy stack while the last Codex item is streaming.
                        VStack(alignment: .leading, spacing: 11) {
                            if earlierCount > 0 {
                                Button {
                                    loadOlderMessages(entries: entries)
                                } label: {
                                    Label(
                                        "Load earlier messages (\(min(earlierCount, Self.additionalMessagePageSize)))",
                                        systemImage: "arrow.up.circle"
                                    )
                                    .font(.caption.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 8)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(CoFleetTheme.cyan)
                                .accessibilityIdentifier("cofleet.messages.load-earlier")
                            }

                            if turnStore.isLoading && entries.isEmpty {
                                ProgressView("Loading conversation…")
                                    .frame(maxWidth: .infinity)
                                    .padding(24)
                            }

                            ForEach(visibleEntries) { entry in
                                conversationEntry(entry)
                                    .id(entry.id)
                            }

                            if entries.isEmpty && !turnStore.isLoading,
                               turnStore.loadedSessionID == nil {
                                ContentUnavailableView(
                                    "Choose a Codex session",
                                    systemImage: "bubble.left.and.bubble.right",
                                    description: Text("Open History to resume a task, or type below to start a new one.")
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                            }

                            GeometryReader { marker in
                                Color.clear.preference(
                                    key: CoFleetConversationBottomPositionPreferenceKey.self,
                                    value: marker.frame(in: .named(conversationCoordinateSpace)).maxY
                                )
                            }
                            .frame(height: 1)
                            .id(conversationBottomID)
                        }
                        .padding(14)
                    }
                    .coordinateSpace(name: conversationCoordinateSpace)
                    .scrollDismissesKeyboard(.interactively)
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 4)
                            .onChanged { value in handleConversationDragChanged(value) }
                            .onEnded { _ in handleConversationDragEnded() }
                    )
                    .coFleetReaderScrollPhaseChanged { isScrolling in
                        guard isScrolling else {
                            handleConversationDragEnded()
                            return
                        }
                        if distanceFromConversationBottom > Self.nearBottomDistance {
                            followsLatestMessage = false
                        }
                    }
                    .onPreferenceChange(CoFleetConversationBottomPositionPreferenceKey.self) { bottomPosition in
                        let distance = max(0, bottomPosition - viewport.size.height).rounded()
                        if abs(distanceFromConversationBottom - distance) >= 1 {
                            distanceFromConversationBottom = distance
                        }
                        if distance <= Self.nearBottomDistance, !userIsDraggingConversation {
                            followsLatestMessage = true
                        }
                    }

                    if showsLatestButton {
                        Button {
                            followsLatestMessage = true
                            userIsDraggingConversation = false
                            requestFollowScroll(using: proxy, animated: true)
                        } label: {
                            Label("Latest", systemImage: "arrow.down")
                                .font(.caption.bold())
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(.ultraThinMaterial, in: Capsule())
                                .overlay(Capsule().stroke(CoFleetTheme.cyan.opacity(0.3)))
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 14)
                        .padding(.bottom, 12)
                        .accessibilityIdentifier("cofleet.messages.latest")
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.easeInOut(duration: 0.18), value: showsLatestButton)
                .onAppear {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(conversationBottomID, anchor: .bottom)
                    }
                }
                .onChange(of: conversationRevision) { previous, current in
                    if current.sessionID != previous.sessionID {
                        pendingHistoryAnchor = nil
                        followsLatestMessage = true
                    } else if current.entryCount > previous.entryCount, !followsLatestMessage {
                        let increase = current.entryCount - previous.entryCount
                        if let sessionID = current.sessionID {
                            messageLimitBySession[sessionID] = min(
                                currentMessageLimit + increase,
                                current.entryCount
                            )
                        }
                    }
                    requestFollowScroll(using: proxy, animated: false)
                }
                .onChange(of: currentMessageLimit) { _, _ in
                    guard let anchor = pendingHistoryAnchor else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(anchor, anchor: .top)
                    }
                    pendingHistoryAnchor = nil
                }
            }
        }
    }

    @ViewBuilder
    private func conversationEntry(_ entry: CoFleetConversationEntry) -> some View {
        switch entry.content {
        case let .message(item):
            CoFleetTurnItemView(
                item: item,
                accent: CoFleetTheme.cyan,
                rendersMarkdown: rendersMarkdown,
                isStreaming: item.state == .streaming
            )
        case let .activity(items):
            if tracePresentation != .hidden {
                HStack {
                    CoFleetActivityTimeline(
                        items: items,
                        preference: tracePresentation,
                        accent: CoFleetTheme.cyan
                    )
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.08)))
                    Spacer(minLength: 36)
                }
                .accessibilityIdentifier("cofleet.activity.bubble")
            }
        }
    }

    private var currentMessageLimit: Int {
        guard let sessionID = turnStore.loadedSessionID else { return Self.initialMessagePageSize }
        return max(messageLimitBySession[sessionID] ?? Self.initialMessagePageSize, Self.initialMessagePageSize)
    }

    private var conversationBottomID: String {
        "cofleet-conversation-bottom-\(turnStore.loadedSessionID ?? "none")"
    }

    private var conversationCoordinateSpace: String {
        "cofleet-conversation-scroll-\(turnStore.loadedSessionID ?? "none")"
    }

    private var tracePresentation: CoFleetTracePresentationPreference {
        CoFleetTracePresentationPreference(rawValue: tracePresentationRawValue)
            ?? CoFleetConversationPresentationSettings.tracePresentationDefault
    }

    private var conversationRevision: CoFleetConversationRevision {
        CoFleetConversationRevision(
            sessionID: turnStore.loadedSessionID,
            entryCount: conversationEntries.count,
            lastItemID: turnStore.items.last?.id,
            lastTextCount: turnStore.items.last?.text.count ?? 0,
            lastState: turnStore.items.last?.state
        )
    }

    private func loadOlderMessages(entries: [CoFleetConversationEntry]) {
        guard currentMessageLimit < entries.count,
              let sessionID = turnStore.loadedSessionID else { return }
        pendingHistoryAnchor = entries.suffix(currentMessageLimit).first?.id
        followsLatestMessage = false
        messageLimitBySession[sessionID] = min(
            currentMessageLimit + Self.additionalMessagePageSize,
            entries.count
        )
    }

    private func requestFollowScroll(using proxy: ScrollViewProxy, animated: Bool) {
        guard followsLatestMessage, !userIsDraggingConversation, !followScrollScheduled else { return }
        followScrollScheduled = true
        DispatchQueue.main.async {
            followScrollScheduled = false
            guard followsLatestMessage, !userIsDraggingConversation else { return }
            programmaticScrollGeneration &+= 1
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(conversationBottomID, anchor: .bottom)
                }
            } else {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    proxy.scrollTo(conversationBottomID, anchor: .bottom)
                }
            }
        }
    }

    private func handleConversationDragChanged(_ value: DragGesture.Value) {
        guard abs(value.translation.height) >= 4 else { return }
        userIsDraggingConversation = true
        if value.translation.height > 0 || distanceFromConversationBottom > Self.nearBottomDistance {
            followsLatestMessage = false
        }
    }

    private func handleConversationDragEnded() {
        userIsDraggingConversation = false
        if distanceFromConversationBottom <= Self.nearBottomDistance {
            followsLatestMessage = true
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            if let fleetStore {
                Menu {
                    ForEach(fleetStore.visibleProjects) { project in
                        Button {
                            fleetStore.selectedProjectID = project.id
                        } label: {
                            Label(
                                project.displayName,
                                systemImage: fleetStore.selectedProjectID == project.id
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                        }
                    }
                    Divider()
                    Button {
                        showsAddProject = true
                    } label: {
                        Label("Add Project", systemImage: "folder.badge.plus")
                    }
                } label: {
                    CoFleetAgentBayAvatar(
                        name: selectedProject?.displayName ?? "Codex",
                        manifest: selectedProjectPetManifest,
                        asset: workspaceStore?.selectedPetAsset,
                        action: selectedProjectActivity?.actionIndicator
                            ?? selectedProject?.state.actionIndicator
                            ?? .idle,
                        working: turnStore.activeTurn != nil || selectedProjectIsWorking,
                        size: 62
                    )
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Choose project, current project \(selectedProject?.displayName ?? "none")")
            } else {
                CoFleetAgentBayAvatar(
                    name: "Codex",
                    manifest: nil,
                    asset: nil,
                    action: .idle,
                    working: turnStore.activeTurn != nil,
                    size: 62
                )
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Text((selectedProject?.displayName ?? "Agent Bay").uppercased())
                        .font(.system(size: 15, weight: .black, design: .rounded))
                        .tracking(1.1)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                    Spacer(minLength: 4)
                    if selectedProject != nil, workspaceStore != nil {
                        Button { showsWorkspace = true } label: {
                            Label("Notes and todos", systemImage: "note.text")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Project notes and todos")
                        .accessibilityIdentifier("cofleet-agent-bay-workspace")
                        Button { showsPetLibrary = true } label: {
                            Label("Choose pet", systemImage: "pawprint.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Choose project pet")
                    }
                    Button { openSessionHistory() } label: {
                        Label("Sessions", systemImage: "clock.arrow.circlepath")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Session history")
                    Button { showsRuntime = true } label: {
                        Label("Runtime", systemImage: "slider.horizontal.3")
                            .labelStyle(.iconOnly)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Model, reasoning, speed, access, and conversation display")
                }

                HStack(spacing: 7) {
                    Circle().fill(headerStatusColor).frame(width: 7, height: 7)
                    Text(headerStatusLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let host = selectedHost {
                        Text("·")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(host.displayName.uppercased())
                            .font(.caption2.monospaced().bold())
                            .foregroundStyle(CoFleetTheme.cyan)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                }

                HStack(spacing: 8) {
                    Text(currentModelDisplayName)
                        .font(.caption2.monospaced().bold())
                        .foregroundStyle(CoFleetTheme.cyan)
                        .lineLimit(1)
                        .accessibilityIdentifier("cofleet.current-model")
                    if let contextLabel = selectedModelContextLabel {
                        Text(contextLabel)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial.opacity(0.72))
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(turnStore.interactions) { interaction in
                CoFleetInteractionView(interaction: interaction) { decision, answers in
                    Task {
                        do {
                            try await turnStore.resolve(
                                interactionID: interaction.id,
                                decision: decision,
                                answers: answers
                            )
                        } catch {
                            composerErrorMessage = error.localizedDescription
                        }
                    }
                }
                .id(interaction.id)
            }

            if let composerErrorMessage {
                Label(composerErrorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(CoFleetTheme.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let error = turnStore.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(CoFleetTheme.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !turnStore.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(turnStore.attachments) { attachment in
                            attachmentChip(attachment)
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 9) {
                Menu {
                    Button {
                        composerErrorMessage = nil
                        showsImageURLPrompt = true
                    } label: {
                        Label("Image URL…", systemImage: "link")
                    }
                    .disabled(isAttachmentLimitReached)

                    #if os(macOS)
                    if canChooseLocalImages {
                        Button {
                            composerErrorMessage = nil
                            showsLocalImagePicker = true
                        } label: {
                            Label("Project Images…", systemImage: "photo.on.rectangle.angled")
                        }
                        .disabled(isAttachmentLimitReached)
                    }
                    #endif
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 34, height: 40)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel("Add image attachment")

                TextField("Message Codex…", text: $turnStore.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($composerIsFocused)
                    .submitLabel(.send)
                    .lineLimit(1...4)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 11)
                    .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 15))
                    .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.1)))
                    .onSubmit(send)
                    .disabled(turnStore.activeTurn != nil || isPreparingSend)
                    .accessibilityIdentifier("cofleet.message-field")

                if turnStore.activeTurn != nil {
                    Button {
                        Task {
                            do {
                                try await turnStore.interrupt()
                            } catch {
                                composerErrorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        Image(systemName: "stop.fill")
                            .fontWeight(.black)
                            .frame(width: 40, height: 40)
                            .foregroundStyle(Color.white)
                            .background(Color.red.opacity(0.85), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Stop turn")
                    .accessibilityIdentifier("cofleet.stop-button")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .fontWeight(.black)
                            .frame(width: 40, height: 40)
                            .foregroundStyle(Color(red: 0.02, green: 0.08, blue: 0.13))
                            .background(CoFleetTheme.cyan, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!turnStore.canSend || isPreparingSend)
                    .accessibilityLabel("Send message")
                    .accessibilityIdentifier("cofleet.send-button")
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
    }

    private func send() {
        guard !isPreparingSend else { return }
        composerErrorMessage = nil
        isPreparingSend = true
        composerIsFocused = false
        followsLatestMessage = true
        Task {
            defer { isPreparingSend = false }
            do {
                guard let project = fleetStore?.selectedProject else {
                    throw CoFleetClientError.unavailable("Choose a project before sending a message.")
                }
                if threadStore.loadedHostID != project.hostID
                    || threadStore.loadedProjectID != project.id {
                    await threadStore.loadInitial(hostID: project.hostID, projectID: project.id)
                }
                let session: CoFleetSessionSummary
                if let selected = threadStore.selectedSession,
                   selected.hostID == project.hostID,
                   selected.projectID == project.id {
                    session = selected
                } else {
                    session = try await threadStore.createSession(settings: settings)
                }
                if turnStore.loadedHostID != project.hostID
                    || turnStore.loadedProjectID != project.id
                    || turnStore.loadedSessionID != session.id {
                    await turnStore.open(
                        hostID: project.hostID,
                        projectID: project.id,
                        sessionID: session.id
                    )
                }
                _ = try await turnStore.send(settings: settings)
                threadStore.updateLoadedProjectPreview(items: turnStore.items)
            } catch {
                composerErrorMessage = error.localizedDescription
            }
        }
    }

    private var currentModelDisplayName: String {
        // `settings` is the live editor state for the selected task. Prefer it over
        // the immutable session summary so the label changes as soon as the user
        // moves a runtime control, before the next turn is sent.
        CoFleetRuntimeLabelResolver.label(settings: settings, models: models)
    }

    private var selectedProject: CoFleetProject? {
        fleetStore?.selectedProject
    }

    private var selectedProjectActivity: CoFleetProjectActivity? {
        guard let projectID = selectedProject?.id else { return nil }
        return fleetStore?.activity(for: projectID)?.activity
    }

    private var selectedProjectIsWorking: Bool {
        switch selectedProjectActivity {
        case .thinking, .reasoning, .runningCommand: true
        case .idle, .approval, .question, .replied, .none: false
        }
    }

    private var selectedHost: CoFleetHostInfo? {
        guard let hostID = selectedProject?.hostID else { return nil }
        return fleetStore?.hosts.first { $0.id == hostID }
    }

    private var selectedModelContextLabel: String? {
        let selected = settings.modelID.flatMap { selectedID in
            models.first { $0.id == selectedID }
        } ?? models.first(where: \.isDefault) ?? models.first
        guard let contextWindow = selected?.contextWindow, contextWindow > 0 else { return nil }
        return contextWindow >= 1_000
            ? "\(contextWindow / 1_000)K context"
            : "\(contextWindow) context"
    }

    private var headerStatusLabel: String {
        if turnStore.activeTurn != nil { return "Working" }
        if let selectedProjectActivity {
            switch selectedProjectActivity {
            case .idle: break
            case .thinking: return "Thinking"
            case .reasoning: return "Reasoning"
            case .runningCommand: return "Running command"
            case .approval: return "Approval needed"
            case .question: return "Question asked"
            case .replied: return "Replied"
            }
        }
        guard let project = selectedProject else { return "Choose a project" }
        switch project.state {
        case .idle: return selectedHost?.reachability == .online ? "Ready" : "Host unavailable"
        case .working: return "Working"
        case .waitingForApproval: return "Approval needed"
        case .waitingForAnswer: return "Question asked"
        case .replied: return "Replied"
        case .unavailable: return "Unavailable"
        }
    }

    private var headerStatusColor: Color {
        if turnStore.activeTurn != nil { return .yellow }
        switch selectedProject?.state {
        case .waitingForApproval, .waitingForAnswer: return CoFleetTheme.orange
        case .unavailable: return CoFleetTheme.orange
        case .replied: return CoFleetTheme.green
        case .idle, .working, .none:
            return selectedHost?.reachability == .online ? CoFleetTheme.green : CoFleetTheme.orange
        }
    }

    private var selectedProjectPetManifest: CoFleetPetManifest? {
        guard let selectedPetID = workspaceStore?.selectedPetID else { return nil }
        return workspaceStore?.pets.first { $0.id == selectedPetID }
    }

    private func hatchAction(
        for project: CoFleetProject
    ) -> (@MainActor () async throws -> Void)? {
        guard let onHatchPet else { return nil }
        return { try await onHatchPet(project) }
    }

    private func openSessionHistory() {
        composerErrorMessage = nil
        guard let project = fleetStore?.selectedProject else {
            showsSessions = true
            return
        }
        Task {
            await threadStore.loadInitial(hostID: project.hostID, projectID: project.id)
            showsSessions = true
        }
    }

    private var conversationEntries: [CoFleetConversationEntry] {
        CoFleetConversationEntry.make(from: turnStore.items)
    }

    private var isAttachmentLimitReached: Bool {
        turnStore.attachments.count >= CoFleetTurnAttachment.maximumCount
    }

    private var canChooseLocalImages: Bool {
        guard let localHostID, let project = fleetStore?.selectedProject else { return false }
        return project.hostID == localHostID
    }

    private var attachmentHelp: String {
        if canChooseLocalImages {
            return "Add an HTTPS image URL or choose up to \(CoFleetTurnAttachment.maximumCount) images inside this project (20 MB each)."
        }
        return "V1 accepts public or host-reachable HTTPS image URLs. Authenticated photo upload is not available in this release."
    }

    @ViewBuilder
    private func attachmentChip(_ attachment: CoFleetTurnAttachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: attachmentSymbol(attachment))
                .foregroundStyle(CoFleetTheme.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.displayName)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                if let byteCount = attachment.byteCount {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Button {
                turnStore.removeAttachment(id: attachment.id)
                composerErrorMessage = nil
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.displayName)")
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(CoFleetTheme.elevated, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private func attachmentSymbol(_ attachment: CoFleetTurnAttachment) -> String {
        switch attachment.source {
        case .imageURL: "link"
        case .localImage: "photo"
        }
    }

    private func addImageURL() {
        defer { imageURLDraft = "" }
        do {
            guard let url = URL(string: imageURLDraft.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw CoFleetTurnAttachmentError.invalidImageURL
            }
            try turnStore.addAttachment(try CoFleetTurnAttachment.imageURL(url))
            composerErrorMessage = nil
        } catch {
            composerErrorMessage = error.localizedDescription
        }
    }

    #if os(macOS)
    private func addLocalImages(_ result: Result<[URL], Error>) {
        do {
            guard canChooseLocalImages,
                  let rootPath = fleetStore?.selectedProject?.canonicalPath else {
                throw CoFleetClientError.unavailable(
                    "Project images can only be selected for a localhost project."
                )
            }
            let urls = try result.get()
            let availableSlots = CoFleetTurnAttachment.maximumCount - turnStore.attachments.count
            guard urls.count <= availableSlots else {
                throw CoFleetTurnAttachmentError.tooManyAttachments(
                    maximumCount: CoFleetTurnAttachment.maximumCount
                )
            }
            let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)
            var selectedAttachments: [CoFleetTurnAttachment] = []
            for url in urls {
                let hasAccess = url.startAccessingSecurityScopedResource()
                let attachment: CoFleetTurnAttachment
                do {
                    attachment = try CoFleetTurnAttachment.localImage(url, insideProjectRoot: rootURL)
                } catch {
                    if hasAccess { url.stopAccessingSecurityScopedResource() }
                    throw error
                }
                if hasAccess { url.stopAccessingSecurityScopedResource() }
                selectedAttachments.append(attachment)
            }
            let existingSources = Set(turnStore.attachments.map(\.source))
            let selectedSources = selectedAttachments.map(\.source)
            guard existingSources.isDisjoint(with: selectedSources),
                  Set(selectedSources).count == selectedSources.count else {
                throw CoFleetTurnAttachmentError.duplicateAttachment
            }
            for attachment in selectedAttachments {
                try turnStore.addAttachment(attachment)
            }
            composerErrorMessage = nil
        } catch {
            composerErrorMessage = error.localizedDescription
        }
    }
    #endif
}

enum CoFleetRuntimeLabelResolver {
    static func label(
        settings: CoFleetSessionSettings,
        models: [CoFleetModelInfo]
    ) -> String {
        let selectedID = settings.modelID
        let modelName: String
        if let selectedID {
            modelName = models.first(where: { $0.id == selectedID })?.displayName ?? selectedID
        } else {
            modelName = models.first(where: \.isDefault)?.displayName
                ?? models.first?.displayName
                ?? "Codex"
        }
        let effortName = CoFleetReasoningSliderPolicy.displayName(settings.reasoningEffort)
        return "\(modelName) · \(effortName)"
    }

}

enum CoFleetConversationPaging {
    static let initialLimit = 40
    static let additionalLimit = 40

    static func visibleItemIDs(_ ids: [String], limit: Int) -> [String] {
        Array(ids.suffix(max(initialLimit, limit)))
    }

    static func nextLimit(current: Int, total: Int) -> Int {
        min(max(initialLimit, current + additionalLimit), total)
    }
}

private struct CoFleetConversationRevision: Equatable {
    let sessionID: String?
    let entryCount: Int
    let lastItemID: String?
    let lastTextCount: Int
    let lastState: CoFleetTurnItemState?
}

private struct CoFleetConversationBottomPositionPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CoFleetAgentBayAvatar: View {
    let name: String
    let manifest: CoFleetPetManifest?
    let asset: CoFleetPetAsset?
    let action: CoFleetActionIndicator
    let working: Bool
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(CoFleetTheme.cyan.opacity(0.15))
                .frame(width: size * 1.15, height: size * 1.15)
                .blur(radius: working ? 1 : 3)
            Circle()
                .fill(Color(red: 0.04, green: 0.10, blue: 0.17))
                .overlay(Circle().stroke(CoFleetTheme.cyan.opacity(0.4)))
                .frame(width: size, height: size)
            CoFleetPetSpriteView(
                name: name,
                manifest: manifest,
                asset: asset,
                // Action state is already represented beside the avatar. Keep
                // the portrait on the complete idle loop, as Manada does.
                action: .idle,
                size: size * 0.92
            )
            .shadow(color: CoFleetTheme.cyan.opacity(0.45), radius: 7, y: 3)
        }
        .frame(width: size * 1.15, height: size * 1.15)
    }
}

private struct CoFleetConversationEntry: Identifiable {
    enum Content {
        case message(CoFleetTurnItem)
        case activity([CoFleetTurnItem])
    }

    let id: String
    let content: Content

    static func make(from items: [CoFleetTurnItem]) -> [Self] {
        var entries: [Self] = []
        var activities: [CoFleetTurnItem] = []

        func flushActivities() {
            guard let first = activities.first else { return }
            entries.append(Self(id: "activity-\(first.turnID)-\(first.id)", content: .activity(activities)))
            activities.removeAll(keepingCapacity: true)
        }

        for item in items {
            if item.kind.isWorkActivity {
                if let previous = activities.last, previous.turnID != item.turnID {
                    flushActivities()
                }
                activities.append(item)
            } else {
                flushActivities()
                entries.append(Self(id: item.id, content: .message(item)))
            }
        }
        flushActivities()
        return entries
    }
}

private extension CoFleetTurnItemKind {
    var isWorkActivity: Bool {
        switch self {
        case .reasoning, .command, .fileChange, .tool: true
        case .userMessage, .assistantMessage, .system: false
        }
    }
}

private struct CoFleetActivityTimeline: View {
    let items: [CoFleetTurnItem]
    let preference: CoFleetTracePresentationPreference
    let accent: Color
    @State private var isExpanded: Bool

    init(
        items: [CoFleetTurnItem],
        preference: CoFleetTracePresentationPreference = .collapsed,
        accent: Color = CoFleetTheme.cyan
    ) {
        self.items = items
        self.preference = preference
        self.accent = accent
        _isExpanded = State(initialValue: preference == .expanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: statusSymbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)

                    Text(workLabel)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(workLabel), \(summary), \(isExpanded ? "collapse" : "expand")")

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        activityRow(item, drawsConnector: index < items.count - 1)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: 700, alignment: .leading)
        .onChange(of: preference) { _, value in
            isExpanded = value == .expanded
        }
    }

    private func activityRow(_ item: CoFleetTurnItem, drawsConnector: Bool) -> some View {
        HStack(alignment: .top, spacing: 9) {
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(color(for: item).opacity(0.14))
                        .frame(width: 24, height: 24)
                    Image(systemName: symbol(for: item))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(color(for: item))
                }
                if drawsConnector {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.18))
                        .frame(width: 1, height: 12)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(label(for: item))
                        .font(.caption.weight(.semibold))
                    if item.state == .streaming {
                        ProgressView().controlSize(.mini).tint(accent)
                    } else if item.state == .failed {
                        Text("Failed").font(.caption2.weight(.semibold)).foregroundStyle(CoFleetTheme.danger)
                    }
                }
                if !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(item.text)
                        .font(item.kind == .reasoning ? .caption : .caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.bottom, drawsConnector ? 8 : 0)
        }
    }

    private var isActive: Bool { items.contains { $0.state == .streaming || $0.state == .pending } }
    private var hasFailure: Bool { items.contains { $0.state == .failed } }
    private var statusSymbol: String { hasFailure ? "xmark.circle.fill" : (isActive ? "circle.dotted" : "checkmark.circle.fill") }
    private var statusColor: Color { hasFailure ? CoFleetTheme.danger : (isActive ? accent : CoFleetTheme.green) }

    private var workLabel: String {
        if hasFailure { return "Needs attention after \(durationLabel)" }
        return "\(isActive ? "Working" : "Worked") for \(durationLabel)"
    }

    private var durationLabel: String {
        guard let first = items.map(\.createdAt).min() else { return "<1s" }
        let end = isActive ? Date() : (items.map(\.createdAt).max() ?? first)
        let duration = max(0, end.timeIntervalSince(first))
        if duration < 1 { return "<1s" }
        if duration < 60 { return "\(Int(duration.rounded()))s" }
        return "\(Int(duration) / 60)m \(Int(duration) % 60)s"
    }

    private var summary: String {
        var parts: [String] = []
        let reasoning = items.filter { $0.kind == .reasoning }.count
        let commands = items.filter { $0.kind == .command }.count
        let changes = items.filter { $0.kind == .fileChange }.count
        let tools = items.filter { $0.kind == .tool }.count
        if reasoning > 0 { parts.append("Thinking") }
        if commands > 0 { parts.append("Ran \(commands) \(commands == 1 ? "command" : "commands")") }
        if changes > 0 { parts.append("Changed \(changes) \(changes == 1 ? "file" : "files")") }
        if tools > 0 { parts.append("Used \(tools) \(tools == 1 ? "tool" : "tools")") }
        return parts.isEmpty ? "Codex activity" : parts.joined(separator: " · ")
    }

    private func label(for item: CoFleetTurnItem) -> String {
        switch item.kind {
        case .reasoning: "Reasoning"
        case .command: "Running command"
        case .fileChange: "Changing files"
        case .tool: "Using tool"
        case .userMessage, .assistantMessage, .system: "Activity"
        }
    }

    private func symbol(for item: CoFleetTurnItem) -> String {
        switch item.kind {
        case .reasoning: "brain"
        case .command: "terminal"
        case .fileChange: "pencil.and.outline"
        case .tool: "wrench.and.screwdriver"
        case .userMessage: "person.fill"
        case .assistantMessage: "terminal.fill"
        case .system: "info.circle"
        }
    }

    private func color(for item: CoFleetTurnItem) -> Color {
        if item.state == .failed { return CoFleetTheme.danger }
        return item.kind == .fileChange ? CoFleetTheme.green : accent
    }
}

public struct CoFleetTurnItemView: View {
    public var item: CoFleetTurnItem
    public var accent: Color
    public var rendersMarkdown: Bool
    public var isStreaming: Bool

    public init(
        item: CoFleetTurnItem,
        accent: Color = CoFleetTheme.cyan,
        rendersMarkdown: Bool = true,
        isStreaming: Bool = false
    ) {
        self.item = item
        self.accent = accent
        self.rendersMarkdown = rendersMarkdown
        self.isStreaming = isStreaming
    }

    @ViewBuilder
    public var body: some View {
        if item.kind == .system {
            Label(item.text, systemImage: "arrow.triangle.swap")
                .font(.caption.bold())
                .foregroundStyle(CoFleetTheme.orange)
                .padding(9)
                .background(CoFleetTheme.orange.opacity(0.1), in: Capsule())
        } else {
            HStack {
                if item.kind == .userMessage { Spacer(minLength: 60) }
                VStack(alignment: .leading, spacing: 7) {
                    if !item.text.isEmpty {
                        if item.kind == .assistantMessage, rendersMarkdown, !isStreaming {
                            CoFleetMessageMarkdownView(source: item.text)
                        } else {
                            Text(item.text)
                                .font(.subheadline)
                                .textSelection(.enabled)
                        }
                    }
                    if isStreaming {
                        ProgressView()
                            .controlSize(.small)
                            .tint(accent)
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 11)
                .background(
                    item.kind == .userMessage ? accent.opacity(0.22) : Color.white.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 15)
                )
                .overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.white.opacity(0.08)))
                if item.kind == .assistantMessage { Spacer(minLength: 60) }
            }
        }
    }
}

private struct CoFleetMessageMarkdownView: View {
    let source: String

    var body: some View {
        Group {
            if let attributed = try? AttributedString(markdown: source) {
                Text(attributed)
            } else {
                Text(source)
            }
        }
        .font(.subheadline)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct CoFleetInteractionView: View {
    public var interaction: CoFleetInteraction
    public var onResolve: (CoFleetInteractionDecision, [String: [String]]?) -> Void
    @State private var answers: [String: String] = [:]

    public init(
        interaction: CoFleetInteraction,
        onResolve: @escaping (CoFleetInteractionDecision, [String: [String]]?) -> Void
    ) {
        self.interaction = interaction
        self.onResolve = onResolve
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Label(interaction.title, systemImage: "hand.raised.fill")
                    .font(.headline)
                    .foregroundStyle(CoFleetTheme.orange)
                Spacer(minLength: 8)
                Text("CODEX")
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(CoFleetTheme.cyan)
            }
            if !interaction.detail.isEmpty {
                Text(interaction.detail)
                    .font(interaction.kind == .question ? .callout : .caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(interaction.kind == .question ? 0 : 9)
                    .background(
                        interaction.kind == .question ? Color.clear : Color.black.opacity(0.24),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
            }
            if interaction.kind == .question {
                ForEach(interaction.questions) { question in
                    questionView(question)
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 115), spacing: 8)], spacing: 8) {
                ForEach(interaction.choices, id: \.self) { choice in
                    Button(choiceLabel(choice)) {
                        resolve(choice)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(choice == .denyAndStop ? CoFleetTheme.danger : CoFleetTheme.cyan)
                    .frame(maxWidth: .infinity)
                    .disabled(choice == .submitAnswer && !canSubmitAnswers)
                }
            }
            Text("Expires \(interaction.expiresAt, style: .relative)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(CoFleetTheme.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 15))
        .overlay { RoundedRectangle(cornerRadius: 15).stroke(CoFleetTheme.orange.opacity(0.35)) }
    }

    private func choiceLabel(_ choice: CoFleetInteractionDecision) -> String {
        switch choice {
        case .allowOnce: "Allow once"
        case .allowForSession: "Allow for session"
        case .deny: "Deny"
        case .denyAndStop: "Deny and stop"
        case .submitAnswer: "Send answer"
        case .accept: "Accept"
        case .decline: "Decline"
        case .cancel: "Cancel"
        }
    }

    private func resolve(_ choice: CoFleetInteractionDecision) {
        let submitted = answers.reduce(into: [String: [String]]()) { result, entry in
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result[entry.key] = [value] }
        }
        onResolve(choice, submitted.isEmpty ? nil : submitted)
    }

    @ViewBuilder
    private func questionView(_ question: CoFleetInteractionQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !question.header.isEmpty {
                Text(question.header.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(question.prompt).font(.callout)
            if !question.options.isEmpty {
                Picker("Answer", selection: answerBinding(for: question.id)) {
                    Text("Choose…").tag("")
                    ForEach(question.options) { option in
                        Text(option.label).tag(option.label)
                    }
                }
                .pickerStyle(.menu)
                ForEach(question.options.filter { $0.label == answers[question.id] }) { option in
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } else if question.isSecret {
                SecureField("Answer", text: answerBinding(for: question.id))
                    .textFieldStyle(.roundedBorder)
            } else {
                TextField("Answer", text: answerBinding(for: question.id), axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            }
            if question.allowsFreeform && !question.options.isEmpty {
                TextField("Or enter another answer", text: answerBinding(for: question.id))
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(.vertical, 2)
    }

    private func answerBinding(for id: String) -> Binding<String> {
        Binding(
            get: { answers[id, default: ""] },
            set: { answers[id] = $0 }
        )
    }

    private var canSubmitAnswers: Bool {
        !interaction.questions.isEmpty && interaction.questions.allSatisfy {
            !(answers[$0.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

private extension View {
    @ViewBuilder
    func coFleetReaderScrollPhaseChanged(_ action: @escaping @MainActor (Bool) -> Void) -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            onScrollPhaseChange { _, phase in
                action(phase != .idle)
            }
        } else {
            self
        }
    }
}
#endif
