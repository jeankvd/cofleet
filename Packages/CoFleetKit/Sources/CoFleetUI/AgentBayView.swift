import CoFleetCore
import SwiftUI
import UniformTypeIdentifiers

#if !os(watchOS)

public struct CoFleetAgentBayView: View {
    @Bindable private var threadStore: ThreadStore
    @Bindable private var turnStore: TurnStore
    @Binding private var settings: CoFleetSessionSettings
    private let models: [CoFleetModelInfo]
    private let fleetStore: FleetStore?
    private let localHostID: CoFleetHostID?

    @State private var showsSessions = false
    @State private var showsAddProject = false
    @State private var showsImageURLPrompt = false
    @State private var showsLocalImagePicker = false
    @State private var imageURLDraft = ""
    @State private var composerErrorMessage: String?

    public init(
        threadStore: ThreadStore,
        turnStore: TurnStore,
        settings: Binding<CoFleetSessionSettings>,
        models: [CoFleetModelInfo],
        fleetStore: FleetStore? = nil,
        localHostID: CoFleetHostID? = nil
    ) {
        self.threadStore = threadStore
        self.turnStore = turnStore
        _settings = settings
        self.models = models
        self.fleetStore = fleetStore
        self.localHostID = localHostID
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(turnStore.items) { item in
                            CoFleetTurnItemView(item: item)
                                .id(item.id)
                        }
                        ForEach(turnStore.interactions) { interaction in
                            CoFleetInteractionView(interaction: interaction) { decision, answers in
                                Task { try? await turnStore.resolve(interactionID: interaction.id, decision: decision, answers: answers) }
                            }
                        }
                    }
                    .padding(14)
                }
                .onChange(of: turnStore.items.count) {
                    if let id = turnStore.items.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }

            Divider()
            composer
        }
        .background(CoFleetTheme.background)
        .sheet(isPresented: $showsSessions) { CoFleetSessionPicker(store: threadStore) }
        .sheet(isPresented: $showsAddProject) {
            if let fleetStore {
                CoFleetProjectRegistrationView(fleetStore: fleetStore)
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
    }

    private var header: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(threadStore.selectedSession?.title ?? "Agent Bay")
                        .font(.headline)
                    Text(threadStore.selectedSession?.modelID ?? settings.modelID ?? "Host default model")
                        .font(.caption)
                        .foregroundStyle(CoFleetTheme.cyan)
                }
                Spacer()
                Button { showsSessions = true } label: {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                if fleetStore != nil {
                    Button { showsAddProject = true } label: {
                        Label("Add Project", systemImage: "folder.badge.plus")
                    }
                }
                if turnStore.activeTurn != nil {
                    Button(role: .destructive) {
                        Task { try? await turnStore.interrupt() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                }
            }
            CoFleetRuntimeControls(settings: $settings, models: models)
        }
        .padding(14)
        .background(CoFleetTheme.surface)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !turnStore.attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(turnStore.attachments) { attachment in
                            attachmentChip(attachment)
                        }
                    }
                }
            }

            HStack(alignment: .bottom, spacing: 10) {
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
                    Image(systemName: "paperclip")
                        .font(.headline)
                        .frame(width: 38, height: 38)
                        .background(CoFleetTheme.elevated, in: Circle())
                }
                .accessibilityLabel("Add image attachment")

                TextField("Message Codex…", text: $turnStore.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(CoFleetTheme.elevated, in: RoundedRectangle(cornerRadius: 14))
                    .onSubmit(send)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.headline.bold())
                        .frame(width: 38, height: 38)
                        .background(CoFleetTheme.cyan, in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!turnStore.canSend)
                .accessibilityLabel("Send message")
            }

            if let composerErrorMessage {
                Text(composerErrorMessage)
                    .font(.caption)
                    .foregroundStyle(CoFleetTheme.danger)
                    .accessibilityLabel("Attachment error: \(composerErrorMessage)")
            } else {
                Text(attachmentHelp)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(CoFleetTheme.surface)
    }

    private func send() {
        composerErrorMessage = nil
        Task {
            do {
                _ = try await turnStore.send(settings: settings)
            } catch {
                composerErrorMessage = error.localizedDescription
            }
        }
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

public struct CoFleetTurnItemView: View {
    public var item: CoFleetTurnItem

    public init(item: CoFleetTurnItem) {
        self.item = item
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(label, systemImage: symbol)
                .font(.caption.bold())
                .foregroundStyle(tint)
            markdownText(item.text)
                .textSelection(.enabled)
            if item.state == .streaming { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: 680, alignment: .leading)
        .padding(12)
        .background(background, in: RoundedRectangle(cornerRadius: 14))
        .frame(maxWidth: .infinity, alignment: item.kind == .userMessage ? .trailing : .leading)
    }

    private func markdownText(_ source: String) -> Text {
        if let attributed = try? AttributedString(markdown: source) { return Text(attributed) }
        return Text(source)
    }

    private var label: String {
        switch item.kind {
        case .userMessage: "You"
        case .assistantMessage: "Codex"
        case .reasoning: "Reasoning"
        case .command: "Command"
        case .fileChange: "File change"
        case .tool: "Tool"
        case .system: "System"
        }
    }

    private var symbol: String {
        switch item.kind {
        case .userMessage: "person.fill"
        case .assistantMessage: "terminal.fill"
        case .reasoning: "brain.head.profile"
        case .command: "chevron.left.forwardslash.chevron.right"
        case .fileChange: "doc.badge.gearshape"
        case .tool: "wrench.and.screwdriver.fill"
        case .system: "info.circle.fill"
        }
    }

    private var tint: Color { item.kind == .userMessage ? CoFleetTheme.violet : CoFleetTheme.cyan }
    private var background: Color { item.kind == .userMessage ? CoFleetTheme.violet.opacity(0.16) : CoFleetTheme.elevated }
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
            Label(interaction.title, systemImage: "hand.raised.fill")
                .font(.headline)
                .foregroundStyle(CoFleetTheme.orange)
            Text(interaction.detail).font(.callout)
            if interaction.kind == .question {
                ForEach(interaction.questions) { question in
                    questionView(question)
                }
            }
            HStack {
                ForEach(interaction.choices, id: \.self) { choice in
                    Button(choiceLabel(choice)) {
                        resolve(choice)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(choice == .denyAndStop ? CoFleetTheme.danger : CoFleetTheme.cyan)
                    .disabled(choice == .submitAnswer && !canSubmitAnswers)
                }
            }
            Text("Expires \(interaction.expiresAt, style: .relative)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(CoFleetTheme.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).stroke(CoFleetTheme.orange.opacity(0.45)) }
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
#endif
