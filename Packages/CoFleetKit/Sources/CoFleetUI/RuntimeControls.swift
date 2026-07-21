import CoFleetCore
import SwiftUI

#if !os(watchOS)

public struct CoFleetRuntimeControls: View {
    @Binding private var settings: CoFleetSessionSettings
    private let models: [CoFleetModelInfo]

    public init(settings: Binding<CoFleetSessionSettings>, models: [CoFleetModelInfo]) {
        _settings = settings
        self.models = models
    }

    public var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                modelCard
                reasoningCard
                speedCard
                accessCard
            }
            .padding(16)
        }
        .background(CoFleetTheme.background)
    }

    private var modelCard: some View {
        HStack(spacing: 12) {
            Label("Model", systemImage: "cpu")
                .font(.headline)
            Spacer()
            Picker("Model", selection: $settings.modelID) {
                Text("Host default").tag(Optional<String>.none)
                ForEach(models) { model in
                    Text(model.displayName).tag(Optional(model.id))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .accessibilityIdentifier("cofleet.runtime.model")
        }
        .coFleetSettingsCard()
    }

    private var reasoningCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("Reasoning", systemImage: "brain")
                    .font(.headline)
                Spacer()
                Text(reasoningLabel)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }

            if reasoningEfforts.count > 1 {
                Slider(
                    value: reasoningIndex,
                    in: 0...Double(reasoningEfforts.count - 1),
                    step: 1
                )
                .tint(CoFleetTheme.cyan)
                .accessibilityLabel("Reasoning effort")
                .accessibilityValue(reasoningLabel)
                .accessibilityIdentifier("cofleet.runtime.reasoning")

                HStack(spacing: 4) {
                    ForEach(Array(reasoningEfforts.enumerated()), id: \.offset) { index, effort in
                        Text(displayName(effort))
                        if index < reasoningEfforts.count - 1 { Spacer(minLength: 2) }
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
            } else {
                Text("This model does not advertise multiple reasoning levels.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .coFleetSettingsCard()
    }

    private var speedCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Speed", systemImage: "gauge.with.dots.needle.50percent")
                .font(.headline)
            Picker("Speed", selection: $settings.serviceTier) {
                Text("Default").tag(Optional<String>.none)
                ForEach(selectedModel?.supportedServiceTiers ?? [], id: \.self) { tier in
                    Text(displayName(tier)).tag(Optional(tier))
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("cofleet.runtime.speed")
        }
        .coFleetSettingsCard()
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

            if settings.accessLevel.requiresProminentWarning {
                Label(
                    "Full access can change files outside this workspace and use the network without asking.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(CoFleetTheme.danger)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            } else {
                Text("This policy stays with the selected Codex task.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
        .background(CoFleetTheme.panelFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(CoFleetTheme.hairline)
        }
        .accessibilityIdentifier("cofleet.runtime.access")
    }

    private var selectedModel: CoFleetModelInfo? {
        models.first { $0.id == settings.modelID } ?? models.first { $0.isDefault }
    }

    private var reasoningEfforts: [String] {
        var values = selectedModel?.supportedReasoningEfforts ?? []
        if let current = settings.reasoningEffort, !values.contains(current) {
            values.append(current)
        }
        return values
    }

    private var reasoningIndex: Binding<Double> {
        Binding(
            get: {
                guard let current = settings.reasoningEffort,
                      let index = reasoningEfforts.firstIndex(of: current) else { return 0 }
                return Double(index)
            },
            set: { value in
                guard !reasoningEfforts.isEmpty else { return }
                let index = min(max(Int(value.rounded()), 0), reasoningEfforts.count - 1)
                settings.reasoningEffort = reasoningEfforts[index]
            }
        )
    }

    private var reasoningLabel: String {
        settings.reasoningEffort.map(displayName) ?? "Default"
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

private extension View {
    func coFleetSettingsCard() -> some View {
        padding(16)
            .background(CoFleetTheme.panelFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(CoFleetTheme.hairline)
            }
    }
}
#endif
