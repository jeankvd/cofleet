import CoFleetCore
import SwiftUI

#if !os(watchOS)

public struct CoFleetDashboardView: View {
    @Environment(\.openURL) private var openURL
    @Bindable private var fleetStore: FleetStore
    @Bindable private var threadStore: ThreadStore
    @Bindable private var turnStore: TurnStore
    private let pairAction: CoFleetOnboardingView.PairAction
    @State private var showsPairing = false
    @State private var deviceHost: CoFleetHostInfo?
    @State private var loginChallenge: CoFleetLoginChallenge?
    @State private var loginHostName = "Codex host"
    @State private var loginErrorMessage: String?

    public init(
        fleetStore: FleetStore,
        threadStore: ThreadStore,
        turnStore: TurnStore,
        pairAction: @escaping CoFleetOnboardingView.PairAction
    ) {
        self.fleetStore = fleetStore
        self.threadStore = threadStore
        self.turnStore = turnStore
        self.pairAction = pairAction
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Dashboard")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Spacer()
                    Button {
                        showsPairing = true
                    } label: {
                        Label("Pair Host", systemImage: "server.rack")
                    }
                    Button {
                        Task {
                            await fleetStore.refresh()
                            await fleetStore.refreshAccountState()
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 12)], spacing: 12) {
                    metric("Hosts", value: "\(fleetStore.hosts.count)", symbol: "server.rack")
                    metric("Online", value: "\(fleetStore.hosts.filter { $0.reachability == .online }.count)", symbol: "network")
                    metric("Active turns", value: turnStore.activeTurn == nil ? "0" : "1", symbol: "bolt.fill")
                    metric("Approvals", value: "\(turnStore.interactions.count)", symbol: "hand.raised.fill")
                }

                GroupBox("Hosts") {
                    VStack(spacing: 0) {
                        ForEach(fleetStore.hosts) { host in
                            HStack {
                                Circle()
                                    .fill(host.reachability == .online ? CoFleetTheme.green : Color.gray)
                                    .frame(width: 9, height: 9)
                                VStack(alignment: .leading) {
                                    Text(host.displayName).font(.headline)
                                    Text(host.platform).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Devices") {
                                    deviceHost = host
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                Text(host.reachability.rawValue.capitalized)
                                    .font(.caption.bold())
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }

                GroupBox("Recent Sessions") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(threadStore.sessions.prefix(5)) { session in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(session.title).font(.headline)
                                    Text(session.updatedAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(session.state.rawValue.capitalized)
                                    .font(.caption.bold())
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                GroupBox("Codex Accounts & Limits") {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(fleetStore.hosts) { host in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(host.displayName).font(.headline)
                                    Spacer()
                                    if let account = fleetStore.accounts[host.id] {
                                        Text(account.planType?.replacingOccurrences(of: "_", with: " ").capitalized ?? account.authenticationType?.capitalized ?? "Signed in")
                                            .font(.caption.bold())
                                            .foregroundStyle(account.isSignedIn ? CoFleetTheme.green : CoFleetTheme.orange)
                                    } else {
                                        Text(host.reachability == .offline ? "Offline" : "Unavailable")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                if let email = fleetStore.accounts[host.id]?.email {
                                    Text(email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                if fleetStore.accounts[host.id]?.requiresOpenAIAuthentication == true {
                                    Button("Sign in with ChatGPT") {
                                        beginLogin(host)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(CoFleetTheme.cyan)
                                }
                                ForEach(fleetStore.accountLimits[host.id] ?? []) { limit in
                                    limitRow(limit)
                                }
                            }
                            if host.id != fleetStore.hosts.last?.id { Divider() }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .background(CoFleetTheme.background)
        .sheet(isPresented: $showsPairing) {
            CoFleetOnboardingView(pair: pairAction) { _ in
                showsPairing = false
                Task {
                    await fleetStore.refresh()
                    await fleetStore.refreshAccountState()
                }
            }
        }
        .sheet(item: $loginChallenge) { challenge in
            NavigationStack {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Sign in to Codex on \(loginHostName)")
                        .font(.title2.bold())
                    Text("CoFleet uses Codex's official device-code flow. CoFleet never receives or stores your ChatGPT password or Codex tokens.")
                        .foregroundStyle(.secondary)
                    if let code = challenge.userCode {
                        GroupBox("One-time code") {
                            Text(code)
                                .font(.system(.title2, design: .monospaced, weight: .bold))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Button("Open ChatGPT Sign-In") {
                        openURL(challenge.verificationURL)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(CoFleetTheme.cyan)
                    Spacer()
                }
                .padding(22)
                .frame(minWidth: 360, minHeight: 260)
                .navigationTitle("Codex Sign-In")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("I've signed in") {
                            loginChallenge = nil
                            Task { await fleetStore.refreshAccountState() }
                        }
                    }
                }
            }
        }
        .sheet(item: $deviceHost) { host in
            CoFleetDeviceManagementView(fleetStore: fleetStore, host: host)
        }
        .alert(
            "Couldn’t start sign-in",
            isPresented: Binding(
                get: { loginErrorMessage != nil },
                set: { if !$0 { loginErrorMessage = nil } }
            )
        ) {
            Button("OK") { loginErrorMessage = nil }
        } message: {
            Text(loginErrorMessage ?? "Try again, or run codex login interactively on that host and refresh.")
        }
    }

    private func metric(_ title: String, value: String, symbol: String) -> some View {
        HStack {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(CoFleetTheme.cyan)
            VStack(alignment: .leading) {
                Text(value).font(.title2.bold())
                Text(title).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .coFleetPanel()
    }

    private func limitRow(_ limit: CoFleetRateLimitInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(limit.displayName ?? limit.limitID.capitalized)
                .font(.caption.bold())
            if let primary = limit.primary {
                limitWindow("Primary", primary)
            }
            if let secondary = limit.secondary {
                limitWindow("Secondary", secondary)
            }
        }
    }

    private func limitWindow(_ label: String, _ window: CoFleetRateLimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label)
                Spacer()
                Text("\(window.usedPercent)% used")
                if let reset = window.resetsAt {
                    Text("· resets \(reset, style: .relative)")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            ProgressView(value: Double(window.usedPercent), total: 100)
                .tint(window.usedPercent >= 90 ? CoFleetTheme.danger : CoFleetTheme.cyan)
        }
    }

    private func beginLogin(_ host: CoFleetHostInfo) {
        Task {
            do {
                let challenge = try await fleetStore.startChatGPTLogin(hostID: host.id)
                loginHostName = host.displayName
                loginChallenge = challenge
            } catch {
                loginErrorMessage = error.localizedDescription
            }
        }
    }
}

private struct CoFleetDeviceManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var fleetStore: FleetStore
    let host: CoFleetHostInfo

    @State private var confirmsRemoval = false

    private var devices: [CoFleetPairedDevice] {
        fleetStore.pairedDevices[host.id] ?? []
    }

    private var currentDeviceID: String? {
        fleetStore.currentPairedDeviceIDs[host.id]
    }

    private var isBusy: Bool {
        fleetStore.isManagingDevices(hostID: host.id)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if devices.isEmpty, isBusy {
                        ProgressView("Loading this device…")
                    } else if let currentDeviceID,
                       let current = devices.first(where: { $0.id == currentDeviceID }) {
                        deviceRow(current, isCurrent: true)
                        HStack {
                            Button("Rotate Token") {
                                Task { await fleetStore.rotateCurrentDevice(hostID: host.id) }
                            }
                            .disabled(isBusy || current.isRevoked)

                            Button("Remove This Device", role: .destructive) {
                                confirmsRemoval = true
                            }
                            .disabled(isBusy || current.isRevoked)
                        }
                    } else if currentDeviceID == nil {
                        Label(
                            "This pairing predates device management. Pair the host again to rotate or remove this device safely.",
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.secondary)
                    } else {
                        Text("The current device is no longer present on this host.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("This Device")
                } footer: {
                    Text("Rotation immediately invalidates the previous token. CoFleet saves the replacement in Keychain before reporting success.")
                }

                Section("All Devices") {
                    if devices.isEmpty, isBusy {
                        ProgressView("Loading paired devices…")
                    } else if devices.isEmpty {
                        Text("No paired devices were returned by this host.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(devices) { device in
                            deviceRow(device, isCurrent: device.id == currentDeviceID)
                        }
                    }
                }
            }
            .navigationTitle("Devices on \(host.displayName)")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await fleetStore.refreshPairedDevices(hostID: host.id) }
                    } label: {
                        Label("Refresh Devices", systemImage: "arrow.clockwise")
                    }
                    .disabled(isBusy)
                }
            }
            .task {
                await fleetStore.refreshPairedDevices(hostID: host.id)
            }
            .confirmationDialog(
                "Remove this device from \(host.displayName)?",
                isPresented: $confirmsRemoval,
                titleVisibility: .visible
            ) {
                Button("Remove This Device", role: .destructive) {
                    Task {
                        await fleetStore.revokeCurrentDevice(hostID: host.id)
                        if fleetStore.deviceErrorMessage == nil {
                            dismiss()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("CoFleet will delete this host from the app. Projects and files on the host are not deleted.")
            }
            .alert(
                "Device Management Failed",
                isPresented: Binding(
                    get: { fleetStore.deviceErrorMessage != nil },
                    set: { if !$0 { fleetStore.clearDeviceError() } }
                )
            ) {
                Button("OK") {
                    fleetStore.clearDeviceError()
                    if !fleetStore.hosts.contains(where: { $0.id == host.id }) {
                        dismiss()
                    }
                }
            } message: {
                Text(fleetStore.deviceErrorMessage ?? "Try again while the host is online.")
            }
        }
#if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
#else
        .frame(minHeight: 420)
#endif
    }

    @ViewBuilder
    private func deviceRow(_ device: CoFleetPairedDevice, isCurrent: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.isRevoked ? "iphone.slash" : "iphone")
                .foregroundStyle(device.isRevoked ? Color.secondary : CoFleetTheme.cyan)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name).font(.headline)
                    if isCurrent {
                        Text("THIS DEVICE")
                            .font(.caption2.bold())
                            .foregroundStyle(CoFleetTheme.cyan)
                    }
                    if device.isRevoked {
                        Text("REVOKED")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                    }
                }
                if let lastSeenAt = device.lastSeenAt {
                    Text("Last seen \(lastSeenAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Paired \(device.createdAt, style: .relative)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}
#endif
