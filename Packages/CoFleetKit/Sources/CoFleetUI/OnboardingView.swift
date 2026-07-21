import CoFleetCore
import SwiftUI

#if !os(watchOS)

public struct CoFleetPairingInput: Hashable, Sendable {
    public var endpoint: URL
    public var code: String
    public var deviceName: String

    public init(endpoint: URL, code: String, deviceName: String) {
        self.endpoint = endpoint
        self.code = code
        self.deviceName = deviceName
    }
}

public struct CoFleetOnboardingView: View {
    public typealias PairAction = @Sendable (CoFleetPairingInput) async throws -> CoFleetHostInfo

    private let pair: PairAction
    private let onPaired: (CoFleetHostInfo) -> Void
    @SceneStorage("cofleet.onboarding.endpoint")
    private var endpoint = "https://your-host.tailnet.ts.net"
    @SceneStorage("cofleet.onboarding.code")
    private var code = ""
    @SceneStorage("cofleet.onboarding.deviceName")
    private var deviceName = "My Apple device"
    @State private var isPairing = false
    @State private var errorMessage: String?

    public init(
        pair: @escaping PairAction,
        onPaired: @escaping (CoFleetHostInfo) -> Void
    ) {
        self.pair = pair
        self.onPaired = onPaired
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(CoFleetTheme.cyan)
                    Text("Bring your Codex projects together")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("CoFleet pairs directly with each host through private Tailscale HTTPS. Codex remains responsible for your ChatGPT sign-in and task history.")
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    TextField("Host URL", text: $endpoint)
                        .textContentType(.URL)
                        .accessibilityIdentifier("cofleet.onboarding.endpoint")
                    TextField("10-minute pairing code", text: $code)
                        .textContentType(.oneTimeCode)
                        .accessibilityIdentifier("cofleet.onboarding.code")
                    TextField("Device name", text: $deviceName)
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(CoFleetTheme.danger)
                    }
                    Button(action: beginPairing) {
                        HStack {
                            if isPairing { ProgressView().controlSize(.small) }
                            Text(isPairing ? "Pairing…" : "Pair Host")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CoFleetTheme.cyan)
                    .disabled(isPairing || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("cofleet.onboarding.pair")
                }
                .coFleetPanel()

                Label("CoFleet never reads or copies ~/.codex/auth.json.", systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(CoFleetTheme.background)
    }

    private func beginPairing() {
        guard let url = URL(string: endpoint),
              url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost" else {
            errorMessage = "Use the host's Tailscale Serve HTTPS URL, or loopback for local setup."
            return
        }
        let input = CoFleetPairingInput(
            endpoint: url,
            code: code.trimmingCharacters(in: .whitespacesAndNewlines),
            deviceName: deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        isPairing = true
        errorMessage = nil
        Task {
            do {
                let host = try await pair(input)
                await MainActor.run {
                    isPairing = false
                    code = ""
                    onPaired(host)
                }
            } catch {
                await MainActor.run {
                    isPairing = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
#endif
