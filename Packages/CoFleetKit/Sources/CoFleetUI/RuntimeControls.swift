import CoFleetCore
import SwiftUI

#if !os(watchOS)

enum CoFleetConversationPresentationSettings {
    static let rendersMarkdownKey = "cofleet.agentBay.rendersMarkdown"
    static let rendersMarkdownDefault = true
    static let tracePresentationKey = "cofleet.agentBay.tracePresentation"
    static let tracePresentationDefault = CoFleetTracePresentationPreference.collapsed
}

enum CoFleetTracePresentationPreference: String, CaseIterable, Codable, Identifiable, Sendable {
    case hidden
    case collapsed
    case expanded

    var id: Self { self }
}

public struct CoFleetRuntimeControls: View {
    @Binding private var settings: CoFleetSessionSettings
    private let models: [CoFleetModelInfo]
    @AppStorage(CoFleetConversationPresentationSettings.rendersMarkdownKey)
    private var rendersMarkdown = CoFleetConversationPresentationSettings.rendersMarkdownDefault
    @AppStorage(CoFleetConversationPresentationSettings.tracePresentationKey)
    private var tracePresentationRawValue = CoFleetConversationPresentationSettings.tracePresentationDefault.rawValue

    public init(settings: Binding<CoFleetSessionSettings>, models: [CoFleetModelInfo]) {
        _settings = settings
        self.models = models
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                settingsCard
                speedCard
                accessCard
                presentationCard
                explanation
            }
            .padding(18)
        }
        .background(Color.black.opacity(0.96))
        .preferredColorScheme(.dark)
    }

    /// Manada presents model and reasoning as one runtime decision rather than
    /// unrelated dashboard tiles. Keep that hierarchy while sourcing every
    /// option from the selected Codex host.
    private var settingsCard: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Model").font(.headline)
                Spacer()
                Picker("Model", selection: $settings.modelID) {
                    Text(defaultModelDisplayName).tag(Optional<String>.none)
                    ForEach(nonDefaultModels) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("cofleet.runtime.model")
            }
            .padding(16)

            Divider().padding(.leading, 16)

            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("Reasoning").font(.headline)
                    Spacer()
                    Text(reasoningLabel)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }

                if !reasoningEfforts.isEmpty {
                    CoFleetAnimatedSliderFrame(isUltra: isUltraReasoning, accent: CoFleetTheme.cyan) {
                        Slider(
                            value: reasoningIndex,
                            in: 0...Double(reasoningEfforts.count),
                            step: 1
                        )
                        .tint(isUltraReasoning ? .white : CoFleetTheme.cyan)
                        .accessibilityLabel("Reasoning effort")
                        .accessibilityValue(reasoningLabel)
                        .accessibilityIdentifier("cofleet.runtime.reasoning")
                    }

                    HStack(spacing: 4) {
                        ForEach(Array(reasoningStopLabels.enumerated()), id: \.offset) { index, label in
                            Text(label)
                            if index < reasoningStopLabels.count - 1 { Spacer(minLength: 2) }
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                } else {
                    Text("This model uses the host default and does not advertise reasoning controls.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 22))
    }

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Speed").font(.headline)
                Spacer()
                Text(speedLabel).foregroundStyle(.secondary)
            }
            Picker("Speed", selection: $settings.serviceTier) {
                Text("Default").tag(Optional<String>.none)
                ForEach(selectedModel?.supportedServiceTiers ?? [], id: \.self) { tier in
                    Text(displayName(tier)).tag(Optional(tier))
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("cofleet.runtime.speed")
        }
        .coFleetManadaSettingsCard()
    }

    private var accessCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Access")
                .font(.headline)
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ForEach(CoFleetAccessLevel.allCases, id: \.self) { level in
                Button {
                    settings.accessLevel = level
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: accessIcon(level))
                            .frame(width: 22)
                            .foregroundStyle(level == .fullAccess ? CoFleetTheme.orange : CoFleetTheme.cyan)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)
                            Text(accessExplanation(level))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                        Spacer(minLength: 8)
                        if settings.accessLevel == level {
                            Image(systemName: "checkmark")
                                .font(.subheadline.bold())
                                .foregroundStyle(level == .fullAccess ? CoFleetTheme.orange : CoFleetTheme.cyan)
                        }
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("cofleet.runtime.access.\(level.rawValue)")

                if level != CoFleetAccessLevel.allCases.last {
                    Divider().padding(.leading, 50)
                }
            }

            Group {
                if settings.accessLevel.requiresProminentWarning {
                    Label(
                        "Full access can change files outside this workspace and use the network without asking.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(CoFleetTheme.danger)
                } else {
                    Text("Codex applies this policy to this task and every new turn.")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption2)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 16)
        }
        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 22))
        .accessibilityIdentifier("cofleet.runtime.access")
    }

    private var presentationCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Conversation").font(.headline)
            Toggle("Render completed replies as Markdown", isOn: $rendersMarkdown)
                .accessibilityIdentifier("cofleet.render-markdown")
            Picker("Turn activity", selection: $tracePresentationRawValue) {
                Text("Hide").tag(CoFleetTracePresentationPreference.hidden.rawValue)
                Text("Collapse").tag(CoFleetTracePresentationPreference.collapsed.rawValue)
                Text("Expand").tag(CoFleetTracePresentationPreference.expanded.rawValue)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("cofleet.trace-presentation")
            Text("Disable Markdown if a reply renders slowly. Live streaming always uses lightweight plain text.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .coFleetManadaSettingsCard()
    }

    private var explanation: some View {
        Text("Models, reasoning levels, and service tiers come directly from the selected Codex host. These choices stay with the task.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedModel: CoFleetModelInfo? {
        models.first { $0.id == settings.modelID } ?? models.first { $0.isDefault } ?? models.first
    }

    private var nonDefaultModels: [CoFleetModelInfo] {
        models.filter { !$0.isDefault }
    }

    private var defaultModelDisplayName: String {
        models.first(where: \.isDefault)?.displayName
            ?? models.first?.displayName
            ?? "Codex default"
    }

    private var reasoningEfforts: [String] {
        CoFleetReasoningSliderPolicy.efforts(
            supported: selectedModel?.supportedReasoningEfforts ?? [],
            current: settings.reasoningEffort
        )
    }

    private var reasoningStopLabels: [String] {
        [CoFleetReasoningSliderPolicy.displayName(nil)]
            + reasoningEfforts.map(CoFleetReasoningSliderPolicy.displayName)
    }

    private var reasoningIndex: Binding<Double> {
        Binding(
            get: {
                CoFleetReasoningSliderPolicy.index(
                    current: settings.reasoningEffort,
                    efforts: reasoningEfforts
                )
            },
            set: { value in
                settings.reasoningEffort = CoFleetReasoningSliderPolicy.selection(
                    at: value,
                    efforts: reasoningEfforts
                )
            }
        )
    }

    private var reasoningLabel: String {
        CoFleetReasoningSliderPolicy.displayName(settings.reasoningEffort)
    }

    private var speedLabel: String {
        settings.serviceTier.map(displayName) ?? "Default"
    }

    private var isUltraReasoning: Bool {
        guard let effort = settings.reasoningEffort?.lowercased() else { return false }
        return effort == "ultra" || effort == "xhigh"
    }

    private func displayName(_ value: String) -> String {
        value.lowercased() == "xhigh"
            ? "XHigh"
            : value.replacingOccurrences(of: "_", with: " ").capitalized
    }

    private func accessIcon(_ level: CoFleetAccessLevel) -> String {
        switch level {
        case .askForApproval: "hand.raised"
        case .approveForMe: "checkmark.shield"
        case .fullAccess: "exclamationmark.shield"
        }
    }

    private func accessExplanation(_ level: CoFleetAccessLevel) -> String {
        switch level {
        case .askForApproval: "Ask before commands or changes outside the trusted boundary."
        case .approveForMe: "Let Codex review routine actions and ask when risk escalates."
        case .fullAccess: "Run without normal approval prompts for this task."
        }
    }
}

enum CoFleetReasoningSliderPolicy {
    static func efforts(supported: [String], current: String?) -> [String] {
        var values: [String] = []
        for effort in supported where !effort.isEmpty && !values.contains(effort) {
            values.append(effort)
        }
        if let current, !current.isEmpty, !values.contains(current) {
            values.append(current)
        }
        return values
    }

    /// Index zero is deliberately reserved for the host default. Explicit
    /// efforts start at one, so an unset preference can never masquerade as Low.
    static func index(current: String?, efforts: [String]) -> Double {
        guard let current,
              let index = efforts.firstIndex(of: current) else { return 0 }
        return Double(index + 1)
    }

    static func selection(at value: Double, efforts: [String]) -> String? {
        let stop = min(max(Int(value.rounded()), 0), efforts.count)
        guard stop > 0 else { return nil }
        return efforts[stop - 1]
    }

    static func displayName(_ effort: String?) -> String {
        guard let effort, !effort.isEmpty else { return "Default" }
        return effort.lowercased() == "xhigh"
            ? "XHigh"
            : effort.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private struct CoFleetAnimatedSliderFrame<Content: View>: View {
    let isUltra: Bool
    let accent: Color
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(isUltra: Bool, accent: Color, @ViewBuilder content: () -> Content) {
        self.isUltra = isUltra
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, isUltra ? 8 : 0)
            .padding(.vertical, isUltra ? 6 : 0)
            .background {
                if isUltra {
                    TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30.0)) { timeline in
                        let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                        let offset = (sin(phase * 1.8) + 1) / 2
                        Capsule()
                            .fill(LinearGradient(
                                colors: [
                                    accent.opacity(0.18),
                                    .cyan.opacity(0.42),
                                    .white.opacity(0.22),
                                    .purple.opacity(0.38),
                                    accent.opacity(0.18),
                                ],
                                startPoint: UnitPoint(x: offset - 0.45, y: 0.5),
                                endPoint: UnitPoint(x: offset + 0.55, y: 0.5)
                            ))
                            .overlay(Capsule().stroke(.white.opacity(0.6), lineWidth: 1))
                            .shadow(color: accent.opacity(0.38), radius: 10)
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isUltra)
    }
}

private extension View {
    func coFleetManadaSettingsCard() -> some View {
        padding(16)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 22))
    }
}
#endif
