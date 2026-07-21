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

    private static let hostSetupURL = URL(
        string: "https://github.com/jeankvd/cofleet/tree/main/Services/CoFleetHost#run-locally"
    )!

    private static let hostSetupCommands = """
    git clone https://github.com/jeankvd/cofleet.git
    cd cofleet
    python3 -m venv .venv
    .venv/bin/pip install ./Services/CoFleetHost
    tailscale serve --bg http://127.0.0.1:47831
    .venv/bin/cofleet-host serve --host 127.0.0.1 --port 47831 --require-private-tailscale
    """

    private static let pairingCommands = """
    cd cofleet
    .venv/bin/cofleet-host pair
    tailscale serve status
    """

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
                    Text("STEP 1 OF 3  •  CONNECT")
                        .font(.caption.bold())
                        .foregroundStyle(CoFleetTheme.cyan)
                    Image(systemName: "shippingbox.fill")
                        .font(.system(size: 48, weight: .bold))
                        .foregroundStyle(CoFleetTheme.cyan)
                    Text("Bring your Codex projects together")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text("CoFleet pairs directly with each host through private Tailscale HTTPS. Codex remains responsible for your ChatGPT sign-in and task history.")
                        .foregroundStyle(.secondary)
                }

                hostSetupInstructions

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Host URL")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("From tailscale serve status", text: $endpoint)
                            .textContentType(.URL)
                            .accessibilityIdentifier("cofleet.onboarding.endpoint")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("10-minute pairing code")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("From cofleet-host pair", text: $code)
                            .textContentType(.oneTimeCode)
                            .accessibilityIdentifier("cofleet.onboarding.code")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Device name")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        TextField("How this Apple device appears on the host", text: $deviceName)
                    }
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

    private var hostSetupInstructions: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Get a pairing code from the project host", systemImage: "terminal.fill")
                .font(.headline)
                .foregroundStyle(CoFleetTheme.cyan)

            Text("On the Mac or Linux computer that has Codex and your project folders, install and start CoFleet Host. Skip the clone command if you already have the repository.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Link(destination: Self.hostSetupURL) {
                Label("Open the CoFleet Host installation guide", systemImage: "arrow.up.right.square")
                    .font(.callout.weight(.semibold))
            }

            instructionStep(
                "1. Install and start the host",
                commands: Self.hostSetupCommands
            )

            Text("Keep that Terminal window running. Then open a second Terminal window on the same host:")
                .font(.caption)
                .foregroundStyle(.secondary)

            instructionStep(
                "2. Generate the code and find the URL",
                commands: Self.pairingCommands
            )

            Label(
                "Paste the HTTPS URL and one-use code below. The code expires after 10 minutes.",
                systemImage: "clock.badge.checkmark"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
        }
        .coFleetPanel()
    }

    private func instructionStep(_ title: String, commands: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption.weight(.bold))
            Text(commands)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 9))
                .overlay {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.white.opacity(0.09))
                }
        }
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
