import CoFleetCore
import SwiftUI

public struct CoFleetWatchPresentationPolicy {
    public static func roundedDisplayInset(for width: CGFloat) -> CGFloat {
        max(4, width * 0.02)
    }

    public static func shouldDismiss(
        startX: CGFloat,
        translation: CGSize
    ) -> Bool {
        startX < 30 &&
            translation.width > 44 &&
            abs(translation.height) < 55
    }

    public static func showsActivity(
        action: CoFleetActionIndicator,
        hasLocallyPendingTurn: Bool
    ) -> Bool {
        if hasLocallyPendingTurn { return true }
        return switch action {
        case .thinking, .runningCommand, .reasoning, .approvalNeeded,
             .questionAsked, .working:
            true
        case .idle, .replied:
            false
        }
    }

    public static func shouldAppendLatest(
        existingLastText: String?,
        latestText: String?
    ) -> Bool {
        guard let latestText else { return false }
        let latest = latestText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latest.isEmpty else { return false }
        return existingLastText?.trimmingCharacters(in: .whitespacesAndNewlines) != latest
    }

    public static func action(for state: CoFleetProjectState) -> CoFleetActionIndicator {
        switch state {
        case .idle: .idle
        case .working: .working
        case .waitingForApproval: .approvalNeeded
        case .waitingForAnswer: .questionAsked
        case .replied: .replied
        case .unavailable: .idle
        }
    }

    public static func action(for activity: CoFleetProjectActivity) -> CoFleetActionIndicator {
        switch activity {
        case .idle: .idle
        case .thinking: .thinking
        case .reasoning: .reasoning
        case .runningCommand: .runningCommand
        case .approval: .approvalNeeded
        case .question: .questionAsked
        case .replied: .replied
        }
    }

    /// Snapshot timestamps are transport metadata, not visible state. Ignoring them prevents
    /// repeated WatchConnectivity transfers when several observation callbacks describe the
    /// same meaningful project state.
    public static func snapshotContentChanged(
        from previous: CoFleetWatchSnapshot?,
        to candidate: CoFleetWatchSnapshot
    ) -> Bool {
        guard var previous else { return true }
        var candidate = candidate
        previous.generatedAt = .distantPast
        candidate.generatedAt = .distantPast
        return previous != candidate
    }

    /// A fresh host snapshot wins over old completed deliveries. In-flight Watch requests and
    /// deliveries newer than the snapshot are overlaid so a delayed connectivity packet cannot
    /// make a pending request look idle or hide its just-arrived reply.
    public static func shouldReapplyDelivery(
        state: CoFleetWatchDeliveryState,
        deliveryUpdatedAt: Date,
        snapshotGeneratedAt: Date
    ) -> Bool {
        switch state {
        case .pending, .running:
            true
        case .completed, .notified, .failed:
            deliveryUpdatedAt > snapshotGeneratedAt
        }
    }

    public static func shouldNotifyReply(
        previous: CoFleetWatchProjectSnapshot?,
        current: CoFleetWatchProjectSnapshot
    ) -> Bool {
        guard current.action == .replied,
              let previous,
              showsActivity(action: previous.action, hasLocallyPendingTurn: false),
              let latest = current.latestMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
              !latest.isEmpty else {
            return false
        }
        return true
    }
}

#if os(watchOS)
public enum CoFleetWatchScreen: String, CaseIterable, Identifiable, Hashable, Sendable {
    case agentBay = "Agent Bay"
    case battle = "Battle"
    case progress = "Progress"

    public var id: String { rawValue }

    public var symbol: String {
        switch self {
        case .agentBay: "bubble.left.and.bubble.right.fill"
        case .battle: "shield.lefthalf.filled"
        case .progress: "chart.bar.fill"
        }
    }
}

public struct CoFleetWatchRootView: View {
    public var snapshot: CoFleetWatchSnapshot
    public var onSend: (CoFleetWatchProjectSnapshot, String) -> Void
    public var onToggleTodo: (CoFleetWatchProjectSnapshot) -> Void

    @State private var path: [CoFleetWatchScreen] = []
    @State private var selectedProjectID: String?
    @State private var messagesByProjectID: [String: [CoFleetWatchChatMessage]] = [:]
    @State private var latestPreviewByProjectID: [String: String] = [:]
    @State private var pendingProjectIDs: Set<String> = []

    public init(
        snapshot: CoFleetWatchSnapshot,
        onSend: @escaping (CoFleetWatchProjectSnapshot, String) -> Void,
        onToggleTodo: @escaping (CoFleetWatchProjectSnapshot) -> Void
    ) {
        self.snapshot = snapshot
        self.onSend = onSend
        self.onToggleTodo = onToggleTodo

        let arguments = ProcessInfo.processInfo.arguments
        let requestedSurface = ProcessInfo.processInfo.environment["COFLEET_WATCH_INITIAL_SURFACE"]
        if arguments.contains("--ui-testing-agent-bay") || requestedSurface == "agent-bay" {
            _path = State(initialValue: [.agentBay])
        } else if arguments.contains("--ui-testing-battle") || requestedSurface == "battle" {
            _path = State(initialValue: [.battle])
        } else if arguments.contains("--ui-testing-progress") || requestedSurface == "progress" {
            _path = State(initialValue: [.progress])
        }
    }

    public var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 8) {
                    selectedProjectHeader
                    surfaceLink(
                        .agentBay,
                        title: "Agent Bay",
                        subtitle: selectedProject.map { "Chat with \($0.name)" } ?? "Connect a project",
                        systemImage: CoFleetWatchScreen.agentBay.symbol,
                        color: CoFleetTheme.cyan
                    )
                    surfaceLink(
                        .battle,
                        title: "Battle",
                        subtitle: "Fight the backlog",
                        systemImage: CoFleetWatchScreen.battle.symbol,
                        color: CoFleetTheme.orange
                    )
                    surfaceLink(
                        .progress,
                        title: "Progress",
                        subtitle: "\(snapshot.projects.count) projects",
                        systemImage: CoFleetWatchScreen.progress.symbol,
                        color: .cyan
                    )
                }
                .padding(.horizontal, 3)
                .padding(.bottom, 8)
            }
            .navigationTitle("CoFleet")
            .navigationDestination(for: CoFleetWatchScreen.self) { screen in
                destination(screen)
            }
        }
        .containerBackground(CoFleetTheme.background.gradient, for: .navigation)
        .onAppear(perform: reconcileSelection)
        .onChange(of: snapshot.projects.map(\.id)) { reconcileSelection() }
        .onOpenURL(perform: openDeepLink)
    }

    @ViewBuilder
    private func destination(_ screen: CoFleetWatchScreen) -> some View {
        switch screen {
        case .agentBay:
            CoFleetWatchAgentBayView(
                projects: snapshot.projects,
                selectedProjectID: $selectedProjectID,
                messagesByProjectID: $messagesByProjectID,
                latestPreviewByProjectID: $latestPreviewByProjectID,
                pendingProjectIDs: $pendingProjectIDs,
                onSend: onSend
            )
        case .battle:
            CoFleetWatchBattleView(
                projects: snapshot.projects,
                selectedProjectID: $selectedProjectID,
                onSend: onSend,
                onToggleTodo: onToggleTodo
            )
            .coFleetWatchEdgeSwipeBack()
        case .progress:
            CoFleetWatchProgressView(
                projects: snapshot.projects,
                selectedProjectID: $selectedProjectID,
                openProject: { project in
                    selectedProjectID = project.id
                    path.append(.agentBay)
                }
            )
        }
    }

    private var selectedProjectHeader: some View {
        HStack(spacing: 8) {
            CoFleetPetPreviewView(
                name: selectedProject?.name ?? "Codex",
                preview: selectedProject?.petPreview,
                size: 44
            )
            .background(CoFleetTheme.cyan.opacity(0.15), in: Circle())
            .overlay(Circle().stroke(CoFleetTheme.cyan.opacity(0.5), lineWidth: 1))

            VStack(alignment: .leading, spacing: 2) {
                Text(selectedProject?.name ?? "No project")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                Text(hostLabel(for: selectedProject).uppercased())
                    .font(.system(size: 8, weight: .black, design: .monospaced))
                    .foregroundStyle(CoFleetTheme.cyan)
                if let selectedProject {
                    CoFleetStatusIndicators(
                        reachability: selectedProject.hostReachability,
                        action: selectedProject.action,
                        sourceControl: selectedProject.sourceControl
                    )
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
    }

    private func surfaceLink(
        _ screen: CoFleetWatchScreen,
        title: String,
        subtitle: String,
        systemImage: String,
        color: Color
    ) -> some View {
        NavigationLink(value: screen) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 28, height: 28)
                    .background(color.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("watch-surface-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }

    private var selectedProject: CoFleetWatchProjectSnapshot? {
        snapshot.projects.first { $0.id == selectedProjectID } ?? snapshot.projects.first
    }

    private func hostLabel(for project: CoFleetWatchProjectSnapshot?) -> String {
        project?.hostID?.rawValue ?? "Codex host"
    }

    private func reconcileSelection() {
        if let selectedProjectID,
           snapshot.projects.contains(where: { $0.id == selectedProjectID }) {
            return
        }
        selectedProjectID = snapshot.focusedProjectID.flatMap { focusedID in
            snapshot.projects.contains(where: { $0.id == focusedID }) ? focusedID : nil
        } ?? snapshot.projects.first?.id
    }

    private func openDeepLink(_ url: URL) {
        guard url.scheme == "cofleet" else { return }
        switch url.host {
        case "battle": path = [.battle]
        case "progress": path = [.progress]
        case "project":
            let projectID = url.pathComponents.dropFirst().first
            if let projectID, snapshot.projects.contains(where: { $0.id == projectID }) {
                selectedProjectID = projectID
                path = [.agentBay]
            }
        default: break
        }
    }
}

private struct CoFleetWatchAgentBayView: View {
    let projects: [CoFleetWatchProjectSnapshot]
    @Binding var selectedProjectID: String?
    @Binding var messagesByProjectID: [String: [CoFleetWatchChatMessage]]
    @Binding var latestPreviewByProjectID: [String: String]
    @Binding var pendingProjectIDs: Set<String>
    let onSend: (CoFleetWatchProjectSnapshot, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var readerMessage: CoFleetWatchChatMessage?
    @State private var floating = false

    var body: some View {
        GeometryReader { geometry in
            let roundedDisplayInset = CoFleetWatchPresentationPolicy.roundedDisplayInset(for: geometry.size.width)

            ZStack {
                watchBackground
                VStack(spacing: 0) {
                    projectHeader(horizontalInset: roundedDisplayInset)
                    projectPickerLink
                    conversation
                        .padding(.horizontal, roundedDisplayInset)
                        .padding(.top, 2)
                    composer
                        .padding(.horizontal, roundedDisplayInset)
                        .padding(.top, 4)
                }
                .padding(.top, roundedDisplayInset * 0.75)
                .padding(.bottom, roundedDisplayInset + 4)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea(.container, edges: .all)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(item: $readerMessage) { message in
            CoFleetWatchMessageReaderView(message: message)
        }
        .onAppear {
            synchronizeLatestMessage()
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                floating = true
            }
        }
        .onChange(of: selectedProjectID) {
            draft = ""
            readerMessage = nil
            synchronizeLatestMessage()
        }
        .onChange(of: selectedProject?.latestMessage) {
            synchronizeLatestMessage()
        }
        .onChange(of: selectedProject?.action) {
            if selectedProject?.action == .replied { synchronizeLatestMessage() }
        }
        .simultaneousGesture(edgeSwipeGesture)
        .accessibilityIdentifier("watch-agent-bay")
    }

    private func projectHeader(horizontalInset: CGFloat) -> some View {
        HStack(spacing: 4) {
            ZStack {
                Circle().fill(CoFleetTheme.cyan.opacity(0.16))
                Circle().stroke(CoFleetTheme.cyan.opacity(0.42), lineWidth: 1)
                CoFleetPetPreviewView(
                    name: selectedProject?.name ?? "Codex",
                    preview: selectedProject?.petPreview,
                    size: 34
                )
                .padding(1)
                .scaleEffect(1.35)
                .offset(y: floating ? -1.5 : 1.5)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(selectedProject?.name ?? "No project")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                    if let selectedProject {
                        CoFleetStatusIndicators(
                            reachability: selectedProject.hostReachability,
                            action: selectedProject.action,
                            sourceControl: selectedProject.sourceControl
                        )
                    }
                }
                Text("\(hostLabel) · CODEX")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .foregroundStyle(CoFleetTheme.cyan)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text("\(selectedAction.watchLabel.uppercased()) · \(selectedProject?.pendingTodoCount ?? 0) TODO")
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            }
            Spacer(minLength: 30)
        }
        .frame(maxWidth: .infinity)
        .padding(.leading, horizontalInset + 2)
        .padding(.trailing, 2)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CoFleetTheme.cyan.opacity(0.42))
                .frame(height: 1)
        }
    }

    private var projectPickerLink: some View {
        NavigationLink {
            CoFleetWatchProjectPickerView(
                projects: projects,
                selectedProjectID: $selectedProjectID
            )
        } label: {
            HStack(spacing: 5) {
                ZStack {
                    Circle().fill(CoFleetTheme.green.opacity(0.9))
                    CoFleetWatchCodexMark()
                        .foregroundStyle(.black.opacity(0.82))
                        .padding(2)
                }
                .frame(width: 11, height: 11)
                Text("Codex")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                Text("· Switch project")
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 22)
            .background(CoFleetTheme.green.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(CoFleetTheme.green.opacity(0.22), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .accessibilityLabel("Choose Codex project. \(selectedProject?.name ?? "No project") selected.")
        .accessibilityIdentifier("watch-project-picker")
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 5) {
                    if messages.isEmpty && !showsActivity {
                        Text("No recent turn yet.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 7)
                            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))
                    }

                    ForEach(messages) { message in
                        Button {
                            readerMessage = message
                        } label: {
                            CoFleetWatchChatBubble(message: message)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier(message.accessibilityIdentifier)
                        .id(message.id)
                    }

                    if showsActivity {
                        thinkingRow.id("thinking")
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: .infinity)
            .onAppear { scrollToBottom(proxy) }
            .onChange(of: messages.count) {
                withAnimation(.easeOut(duration: 0.2)) { scrollToBottom(proxy) }
            }
            .onChange(of: showsActivity) { _, active in
                if active {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("thinking", anchor: .bottom)
                    }
                }
            }
            .onChange(of: selectedProjectID) {
                withAnimation(.easeOut(duration: 0.2)) { scrollToBottom(proxy) }
            }
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: 6) {
            CoFleetPetPreviewView(
                name: selectedProject?.name ?? "Codex",
                preview: selectedProject?.petPreview,
                size: 22
            )
            ProgressView()
                .controlSize(.mini)
                .tint(selectedAction.watchColor)
            Text(selectedAction == .idle ? "Sending…" : selectedAction.watchLabel)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.065), in: Capsule())
    }

    private var composer: some View {
        HStack(spacing: 5) {
            TextField("Type or dictate…", text: $draft)
                .font(.caption)
                .textFieldStyle(.plain)
                .lineLimit(1)
                .submitLabel(.send)
                .onSubmit(send)
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(Color.black.opacity(0.28), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.11), lineWidth: 1))
                .accessibilityIdentifier("watch-chat-field")

            Button(action: send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 12, weight: .black))
                    .foregroundStyle(Color(red: 0.01, green: 0.06, blue: 0.10))
                    .frame(width: 32, height: 32)
                    .background(CoFleetTheme.cyan, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(selectedProject == nil || showsActivity || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send to \(selectedProject?.name ?? "Codex")")
            .accessibilityIdentifier("watch-chat-send")
        }
    }

    private var selectedProject: CoFleetWatchProjectSnapshot? {
        projects.first { $0.id == selectedProjectID } ?? projects.first
    }

    private var selectedAction: CoFleetActionIndicator { selectedProject?.action ?? .idle }

    private var hostLabel: String {
        selectedProject?.hostID?.rawValue ?? "CODEX HOST"
    }

    private var messages: [CoFleetWatchChatMessage] {
        guard let projectID = selectedProject?.id else { return [] }
        return messagesByProjectID[projectID] ?? []
    }

    private var showsActivity: Bool {
        guard let project = selectedProject else { return false }
        return CoFleetWatchPresentationPolicy.showsActivity(
            action: project.action,
            hasLocallyPendingTurn: pendingProjectIDs.contains(project.id)
        )
    }

    private var edgeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onEnded { value in
                guard CoFleetWatchPresentationPolicy.shouldDismiss(
                    startX: value.startLocation.x,
                    translation: value.translation
                ) else { return }
                dismiss()
            }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        if showsActivity {
            proxy.scrollTo("thinking", anchor: .bottom)
        } else {
            proxy.scrollTo(messages.last?.id, anchor: .bottom)
        }
    }

    private func send() {
        guard let project = selectedProject else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messagesByProjectID[project.id, default: []].append(
            CoFleetWatchChatMessage(role: .user, text: text)
        )
        pendingProjectIDs.insert(project.id)
        draft = ""
        onSend(project, text)
    }

    private func synchronizeLatestMessage() {
        guard let project = selectedProject else { return }
        let previouslySeen = latestPreviewByProjectID[project.id]
        guard CoFleetWatchPresentationPolicy.shouldAppendLatest(
            existingLastText: previouslySeen,
            latestText: project.latestMessage
        ), let latest = project.latestMessage?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            if project.action == .replied || project.action == .idle {
                pendingProjectIDs.remove(project.id)
            }
            return
        }
        latestPreviewByProjectID[project.id] = latest
        messagesByProjectID[project.id, default: []].append(
            CoFleetWatchChatMessage(role: .assistant, text: latest)
        )
        if project.action == .replied || project.action == .idle {
            pendingProjectIDs.remove(project.id)
        }
    }

    private var watchBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.005, green: 0.04, blue: 0.08),
                    Color(red: 0.06, green: 0.02, blue: 0.09),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(CoFleetTheme.cyan.opacity(0.12))
                .frame(width: 150)
                .blur(radius: 38)
                .offset(x: -85, y: -85)
            Circle()
                .fill(CoFleetTheme.violet.opacity(0.09))
                .frame(width: 140)
                .blur(radius: 42)
                .offset(x: 90, y: 100)
        }
        .ignoresSafeArea()
    }
}

private struct CoFleetWatchProgressView: View {
    let projects: [CoFleetWatchProjectSnapshot]
    @Binding var selectedProjectID: String?
    let openProject: (CoFleetWatchProjectSnapshot) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 5) {
            HStack(spacing: 6) {
                Text("Progress")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer(minLength: 0)
                Text("\(projects.count)")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 5)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(projects) { project in
                        Button { openProject(project) } label: {
                            HStack(spacing: 7) {
                                CoFleetPetPreviewView(name: project.name, preview: project.petPreview, size: 34)
                                    .background(CoFleetTheme.cyan.opacity(0.13), in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text(project.name)
                                            .font(.system(size: 11, weight: .bold, design: .rounded))
                                            .lineLimit(1)
                                        CoFleetStatusIndicators(
                                            reachability: project.hostReachability,
                                            action: project.action,
                                            sourceControl: project.sourceControl
                                        )
                                    }
                                    Text(project.latestMessage ?? "No recent messages")
                                        .font(.system(size: 8.5, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(CoFleetTheme.cyan.opacity(0.07), in: RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(CoFleetTheme.cyan.opacity(0.2), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(project.name) in Agent Bay")
                    }
                }
                .padding(.horizontal, 3)
                .padding(.bottom, 8)
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .local)
                .onEnded { value in
                    if CoFleetWatchPresentationPolicy.shouldDismiss(
                        startX: value.startLocation.x,
                        translation: value.translation
                    ) {
                        dismiss()
                    }
                }
        )
        .accessibilityIdentifier("watch-progress")
    }
}

private struct CoFleetWatchProjectPickerView: View {
    let projects: [CoFleetWatchProjectSnapshot]
    @Binding var selectedProjectID: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(projects) { project in
            Button {
                selectedProjectID = project.id
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    CoFleetPetPreviewView(name: project.name, preview: project.petPreview, size: 30)
                        .background(CoFleetTheme.cyan.opacity(0.13), in: Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.name).font(.caption.bold())
                        Text(project.hostID?.rawValue ?? "Codex host")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundStyle(CoFleetTheme.cyan)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    CoFleetStatusIndicators(
                        reachability: project.hostReachability,
                        action: project.action,
                        sourceControl: project.sourceControl
                    )
                    if project.id == selectedProjectID {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(CoFleetTheme.cyan)
                    }
                }
            }
            .accessibilityLabel("Chat with \(project.name)")
        }
        .navigationTitle("Agent Bay")
        .toolbar(.hidden, for: .navigationBar)
        .coFleetWatchEdgeSwipeBack()
    }
}

private enum CoFleetWatchChatRole: Equatable {
    case user
    case assistant
    case notice
}

private struct CoFleetWatchChatMessage: Identifiable, Equatable {
    let id: UUID
    let role: CoFleetWatchChatRole
    let text: String

    init(id: UUID = UUID(), role: CoFleetWatchChatRole, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }

    var accessibilityIdentifier: String {
        switch role {
        case .user: "watch-user-message"
        case .assistant: "watch-reply-message"
        case .notice: "watch-notice-message"
        }
    }
}

private struct CoFleetWatchChatBubble: View {
    let message: CoFleetWatchChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 22) }
            Text(message.text)
                .font(.system(size: 11, weight: message.role == .notice ? .semibold : .regular, design: .rounded))
                .foregroundStyle(message.role == .notice ? Color.orange : Color.white)
                .multilineTextAlignment(.leading)
                .lineLimit(message.role == .assistant ? 7 : 5)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(bubbleColor, in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).stroke(strokeColor, lineWidth: 1))
            if message.role != .user { Spacer(minLength: 22) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel("\(roleLabel): \(message.text)")
    }

    private var bubbleColor: Color {
        switch message.role {
        case .user: Color.blue.opacity(0.34)
        case .assistant: Color.white.opacity(0.075)
        case .notice: Color.orange.opacity(0.10)
        }
    }

    private var strokeColor: Color {
        switch message.role {
        case .user: Color.cyan.opacity(0.22)
        case .assistant: Color.white.opacity(0.08)
        case .notice: Color.orange.opacity(0.22)
        }
    }

    private var roleLabel: String {
        switch message.role {
        case .user: "You"
        case .assistant: "Codex"
        case .notice: "Notice"
        }
    }
}

private struct CoFleetWatchMessageReaderView: View {
    let message: CoFleetWatchChatMessage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(message.text)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
            .navigationTitle(message.role == .user ? "You" : "Reply")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private extension CoFleetActionIndicator {
    var watchLabel: String {
        switch self {
        case .idle: "Idle"
        case .thinking: "Thinking"
        case .runningCommand: "Running commands"
        case .reasoning: "Reasoning"
        case .approvalNeeded: "Approval needed"
        case .questionAsked: "Question asked"
        case .working: "Working"
        case .replied: "Replied"
        }
    }

    var watchColor: Color {
        switch self {
        case .idle: .gray
        case .thinking: .cyan
        case .runningCommand: .orange
        case .reasoning: .purple
        case .approvalNeeded: .yellow
        case .questionAsked: .pink
        case .working: .blue
        case .replied: .green
        }
    }
}

private struct CoFleetWatchEdgeSwipeBackModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content.simultaneousGesture(
            DragGesture(minimumDistance: 12, coordinateSpace: .local)
                .onEnded { value in
                    if CoFleetWatchPresentationPolicy.shouldDismiss(
                        startX: value.startLocation.x,
                        translation: value.translation
                    ) {
                        dismiss()
                    }
                }
        )
    }
}

private extension View {
    func coFleetWatchEdgeSwipeBack() -> some View {
        modifier(CoFleetWatchEdgeSwipeBackModifier())
    }
}

private struct CoFleetWatchCodexMark: View {
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            CoFleetWatchCodexKnotShape()
                .stroke(
                    .foreground,
                    style: StrokeStyle(
                        lineWidth: max(0.7, side * 0.13),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: side, height: side)
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct CoFleetWatchCodexKnotShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height)

        func point(radius normalizedRadius: CGFloat, angle: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + cos(angle) * radius * normalizedRadius,
                y: center.y + sin(angle) * radius * normalizedRadius
            )
        }

        for index in 0..<6 {
            let angle = CGFloat(index) * .pi / 3 - .pi / 2
            path.move(to: point(radius: 0.14, angle: angle - .pi / 7))
            path.addCurve(
                to: point(radius: 0.25, angle: angle + .pi / 3),
                control1: point(radius: 0.38, angle: angle - .pi / 12),
                control2: point(radius: 0.43, angle: angle + .pi / 5)
            )
        }
        return path
    }
}
#endif
