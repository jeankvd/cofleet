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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("Model", selection: $settings.modelID) {
                    Text("Host default").tag(Optional<String>.none)
                    ForEach(models) { model in
                        Text(model.displayName).tag(Optional(model.id))
                    }
                }
                .accessibilityIdentifier("cofleet.runtime.model")

                Picker("Reasoning", selection: $settings.reasoningEffort) {
                    Text("Default").tag(Optional<String>.none)
                    ForEach(selectedModel?.supportedReasoningEfforts ?? [], id: \.self) { effort in
                        Text(effort.capitalized).tag(Optional(effort))
                    }
                }
                .accessibilityIdentifier("cofleet.runtime.reasoning")

                Picker("Speed", selection: $settings.serviceTier) {
                    Text("Default").tag(Optional<String>.none)
                    ForEach(selectedModel?.supportedServiceTiers ?? [], id: \.self) { tier in
                        Text(tier.capitalized).tag(Optional(tier))
                    }
                }
            }

            Picker("Access", selection: $settings.accessLevel) {
                ForEach(CoFleetAccessLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("cofleet.runtime.access")

            if settings.accessLevel.requiresProminentWarning {
                Label(
                    "Full access can read or change files outside this workspace and use the network without asking.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(CoFleetTheme.danger)
            }
        }
    }

    private var selectedModel: CoFleetModelInfo? {
        models.first { $0.id == settings.modelID } ?? models.first { $0.isDefault }
    }
}
#endif
