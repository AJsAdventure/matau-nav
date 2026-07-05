import SwiftUI

struct SetupView: View {
    @Environment(AppSettings.self)        private var settings
    @Environment(SignalKService.self)     private var signalK
    @Environment(AnchorPiService.self)   private var piService
    @Environment(PredictWindService.self) private var predictWind

    @State private var hostInput:       String = ""
    @State private var portInput:       String = ""
    @State private var useTLSInput:     Bool   = false
    @State private var usernameInput:   String = ""
    @State private var passwordInput:   String = ""
    @State private var showPassword:    Bool   = false
    @State private var pulseAnimation   = false
    @State private var showingDisclaimer = false

    // PredictWind
    @State private var pwEmail:      String = ""
    @State private var pwPassword:   String = ""
    @State private var pwShowPwd:    Bool   = false
    @State private var pwPiURL:      String = ""
    @State private var pwAuthBusy:   Bool   = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 16) {
                        // Order: connection, dark mode, server, pi alarm, vessel, about
                        connectionStatusCard
                        displayCard
                        serverConfigCard
                        piDaemonCard
                        predictWindCard
                        if signalK.state.isConnected {
                            vesselInfoCard
                        }
                        aboutCard
                        footerView
                        Spacer(minLength: 20)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
            }
            .navigationTitle("Setup")
            .navigationBarTitleDisplayMode(.large)
        }
        .onAppear {
            hostInput     = settings.signalKHost
            portInput     = String(settings.signalKPort)
            useTLSInput   = settings.signalKUseTLS
            let creds     = SignalKKeychain.loadCredentials()
            usernameInput = creds?.username ?? ""
            passwordInput = creds?.password ?? ""
            pwPiURL       = settings.predictWindPiURL
            let pwCreds   = PredictWindKeychain.load()
            pwEmail       = pwCreds?.email    ?? ""
            pwPassword    = pwCreds?.password ?? ""
        }
        .sheet(isPresented: $showingDisclaimer) {
            disclaimerSheet
        }
    }

    // MARK: - Connection Status Card

    private var connectionStatusCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(signalK.state.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                    .scaleEffect(pulseAnimation && signalK.state.isConnecting ? 1.3 : 1.0)
                    .animation(
                        signalK.state.isConnecting
                            ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                            : .default,
                        value: pulseAnimation
                    )
                Circle()
                    .fill(signalK.state.color)
                    .frame(width: 10, height: 10)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(signalK.state.label)
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
                if let info = signalK.serverInfo {
                    Text("\(info.vesselName)  ·  SignalK \(info.version)")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                } else {
                    Text("No server connected")
                        .font(.caption)
                        .foregroundStyle(Color.textTertiary)
                }
            }

            Spacer()

            if signalK.state.isConnected {
                Button {
                    signalK.disconnect()
                } label: {
                    Text("Disconnect")
                        .font(.caption).fontWeight(.medium)
                        .foregroundStyle(Color.statusRed)
                        .padding(.horizontal, 16).padding(.vertical, 6)
                        .background(Color.statusRed.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            } else if case .failed = signalK.state {
                Button {
                    applyAndConnect()
                } label: {
                    Text("Reconnect")
                        .font(.caption).fontWeight(.medium)
                        .foregroundStyle(Color.accentCyan)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.accentCyan.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .cardStyle()
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(signalK.state.color.opacity(0.25), lineWidth: 1)
        )
        .onAppear { pulseAnimation = true }
        .onChange(of: signalK.state.isConnecting) { _, isConnecting in
            pulseAnimation = isConnecting
        }
    }

    // MARK: - Server Config Card

    private var serverConfigCard: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Server", systemImage: "server.rack")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)

            HStack(spacing: 10) {
                PresetChip(
                    label: "Local WiFi",
                    icon: "wifi",
                    isActive: hostInput == "matau.local"
                ) {
                    hostInput   = "matau.local"
                    portInput   = "3000"
                    useTLSInput = false
                }
                PresetChip(
                    label: "Tailscale",
                    icon: "shield.fill",
                    isActive: hostInput == "100.100.220.67"
                ) {
                    hostInput   = "100.100.220.67"
                    portInput   = "3000"
                    useTLSInput = false
                }
            }

            InputField(label: "Address", placeholder: "matau.local", text: $hostInput)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            InputField(label: "Port", placeholder: "3000", text: $portInput)
                .keyboardType(.numberPad)

            // TLS toggle — use wss:// when SignalK is behind nginx with a valid cert
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Use TLS (wss://)")
                        .font(.subheadline)
                        .foregroundStyle(Color.textPrimary)
                    Text("Enable when SignalK is behind a reverse proxy with a valid certificate")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
                Toggle("", isOn: $useTLSInput).labelsHidden()
            }

            Divider().background(Color.borderColor)

            // Optional credentials — stored in Keychain, never in UserDefaults
            VStack(alignment: .leading, spacing: 6) {
                Text("Authentication (optional)")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                Text("Leave blank if SignalK runs without auth on the local network.")
                    .font(.caption2)
                    .foregroundStyle(Color.textTertiary)
            }

            InputField(label: "Username", placeholder: "admin", text: $usernameInput)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            // Password field with show/hide toggle
            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                HStack {
                    Group {
                        if showPassword {
                            TextField("••••••••", text: $passwordInput)
                        } else {
                            SecureField("••••••••", text: $passwordInput)
                        }
                    }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                    Button {
                        showPassword.toggle()
                    } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye")
                            .foregroundStyle(Color.textTertiary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Color.bgElevated)
                .foregroundStyle(Color.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.borderColor, lineWidth: 0.5)
                )
            }

            if !usernameInput.isEmpty {
                Button {
                    usernameInput = ""
                    passwordInput = ""
                    SignalKKeychain.clear()
                } label: {
                    Label("Forget credentials", systemImage: "trash")
                        .font(.caption)
                        .foregroundStyle(Color.statusRed)
                }
                .buttonStyle(.plain)
            }

            Button {
                applyAndConnect()
            } label: {
                HStack(spacing: 8) {
                    if signalK.state.isConnecting {
                        ProgressView()
                            .tint(.black)
                            .scaleEffect(0.8)
                    }
                    Text(signalK.state.isConnecting ? "Connecting…" : "Connect")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    (signalK.state.isConnecting || hostInput.isEmpty)
                        ? Color.accentCyan.opacity(0.4)
                        : Color.accentCyan
                )
                .foregroundStyle(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(signalK.state.isConnecting || hostInput.isEmpty)
            .animation(.easeInOut(duration: 0.2), value: signalK.state.isConnecting)
        }
        .cardStyle()
    }

    // MARK: - Vessel Info Card

    private var vesselInfoCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Vessel", systemImage: "sailboat.fill")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)

            if let info = signalK.serverInfo {
                VStack(spacing: 0) {
                    InfoRow(label: "Name", value: info.vesselName)
                    Divider().background(Color.borderColor).padding(.vertical, 10)
                    InfoRow(label: "SignalK Version", value: info.version)
                    Divider().background(Color.borderColor).padding(.vertical, 10)
                    InfoRow(label: "Server", value: "\(signalK.host):\(signalK.port)")
                    Divider().background(Color.borderColor).padding(.vertical, 10)
                    InfoRow(label: "Transport", value: signalK.useTLS ? "WebSocket (wss)" : "WebSocket (ws)")
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Pi Daemon Card

    private var piDaemonCard: some View {
        @Bindable var s = settings
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Pi Alarm Daemon", systemImage: "cpu")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(piDotColor)
                        .frame(width: 7, height: 7)
                    Text(piStatusLabel)
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }

            InputField(label: "Pi URL (local)", placeholder: "http://matau.local:10112", text: $s.anchorPiURL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            InputField(label: "Pi URL (Tailscale)", placeholder: "http://100.100.220.67:10112", text: $s.anchorPiTailscaleURL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if piService.onTailscale {
                HStack(spacing: 6) {
                    Image(systemName: "shield.fill")
                        .font(.caption)
                        .foregroundStyle(Color.statusOrange)
                    Text("Using Tailscale fallback")
                        .font(.caption)
                        .foregroundStyle(Color.statusOrange)
                }
            }

            InputField(label: "ntfy server", placeholder: "https://ntfy.sh", text: $s.anchorNtfyServer)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            InputField(label: "ntfy topic", placeholder: "my-boat-alarm", text: $s.anchorNtfyTopic)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            if let seen = piService.lastSeen {
                Text("Last seen \(seen.formatted(date: .omitted, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(Color.textTertiary)
            }

            Button {
                settings.persist()
            } label: {
                Text("Save Pi Settings")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentCyan.opacity(0.15))
                    .foregroundStyle(Color.accentCyan)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .cardStyle()
    }

    private var piDotColor: Color {
        switch piService.connectionState {
        case .connected:    .statusGreen
        case .disconnected: .statusRed
        case .unknown:      .textTertiary
        }
    }

    private var piStatusLabel: String {
        switch piService.connectionState {
        case .connected:    piService.onTailscale ? "Tailscale" : "Connected"
        case .disconnected: "Unreachable"
        case .unknown:      settings.effectiveAnchorPiURL.isEmpty ? "Not configured" : "Checking…"
        }
    }

    // MARK: - PredictWind Card

    private var predictWindCard: some View {
        @Bindable var s = settings
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("PredictWind", systemImage: "wind")
                    .font(.headline)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(pwStatusColor)
                        .frame(width: 7, height: 7)
                    Text(predictWind.status.label)
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }

            InputField(label: "Pi URL", placeholder: "http://matau.local:10115", text: $pwPiURL)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            InputField(label: "Email", placeholder: "you@example.com", text: $pwEmail)
                .keyboardType(.emailAddress)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            VStack(alignment: .leading, spacing: 6) {
                Text("Password")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                HStack {
                    Group {
                        if pwShowPwd {
                            TextField("••••••••", text: $pwPassword)
                        } else {
                            SecureField("••••••••", text: $pwPassword)
                        }
                    }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    Button { pwShowPwd.toggle() } label: {
                        Image(systemName: pwShowPwd ? "eye.slash" : "eye")
                            .foregroundStyle(Color.textTertiary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .background(Color.bgElevated)
                .foregroundStyle(Color.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.borderColor, lineWidth: 0.5))
            }

            HStack(spacing: 6) {
                Toggle("", isOn: $s.chartShowPredictWindAIS)
                    .labelsHidden()
                    .onChange(of: s.chartShowPredictWindAIS) { _, _ in settings.persist() }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Show PredictWind AIS on chart")
                        .font(.subheadline)
                        .foregroundStyle(Color.textPrimary)
                    Text("Commercial AIS from PredictWind tile API")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }

            Button {
                Task { await savePredictWind() }
            } label: {
                HStack(spacing: 8) {
                    if pwAuthBusy {
                        ProgressView().tint(.black).scaleEffect(0.8)
                    }
                    Text(pwAuthBusy ? "Connecting…" : "Save & Connect")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(pwAuthBusy ? Color.accentCyan.opacity(0.4) : Color.accentCyan.opacity(0.15))
                .foregroundStyle(Color.accentCyan)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(pwAuthBusy)
        }
        .cardStyle()
    }

    private var pwStatusColor: Color {
        switch predictWind.status {
        case .authenticated:  return .statusGreen
        case .failed:         return .statusRed
        case .authenticating: return .statusOrange
        case .idle:           return .textTertiary
        }
    }

    private func savePredictWind() async {
        let url = pwPiURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = pwEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let pwd   = pwPassword

        settings.predictWindPiURL = url
        settings.persist()
        predictWind.configure(piURL: url)

        guard !email.isEmpty, !pwd.isEmpty else { return }
        PredictWindKeychain.save(email: email, password: pwd)

        pwAuthBusy = true
        _ = await predictWind.setCredentials(email: email, password: pwd, piURL: url)
        pwAuthBusy = false
    }

    // MARK: - Display Card

    private var displayCard: some View {
        @Bindable var s = settings
        return VStack(alignment: .leading, spacing: 16) {
            Label("Display", systemImage: "moon.fill")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)

            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Night Mode")
                        .font(.subheadline)
                        .foregroundStyle(Color.textPrimary)
                    Text("Red-tinted display for night vision")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
                Toggle("", isOn: $s.nightMode)
                    .labelsHidden()
                    .tint(Color(red: 0.9, green: 0.1, blue: 0.1))
                    .onChange(of: s.nightMode) { _, _ in settings.persist() }
            }
        }
        .cardStyle()
    }

    // MARK: - About Card

    private var aboutCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("About", systemImage: "info.circle")
                .font(.headline)
                .foregroundStyle(Color.textPrimary)

            VStack(spacing: 0) {
                InfoRow(label: "App Version", value: "1.0")
                Divider().background(Color.borderColor).padding(.vertical, 10)
                InfoRow(label: "Protocol", value: "SignalK v1 · WebSocket")
                Divider().background(Color.borderColor).padding(.vertical, 10)
                InfoRow(label: "Vessel", value: "Matau · Prout 37 Catamaran")
            }
        }
        .cardStyle()
    }

    // MARK: - Footer

    private var footerView: some View {
        VStack(spacing: 8) {
            Text("Made with ♥ by gleser.ai")
                .font(.caption)
                .foregroundStyle(Color.textTertiary)
            Button {
                showingDisclaimer = true
            } label: {
                Text("Navigation Disclaimer")
                    .font(.caption2)
                    .foregroundStyle(Color.textTertiary.opacity(0.65))
                    .underline()
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var disclaimerSheet: some View {
        NavigationStack {
            ZStack {
                Color.bgPrimary.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("For Entertainment Only", systemImage: "exclamationmark.triangle.fill")
                                .font(.headline)
                                .foregroundStyle(Color.statusOrange)
                            Text("This app is a personal fun project built for the sailing catamaran Matau. It is NOT certified, NOT approved, and NOT intended for use in actual navigation or safety-critical decisions.")
                                .font(.subheadline)
                                .foregroundStyle(Color.textPrimary)
                        }
                        .padding(16)
                        .background(Color.statusOrange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.statusOrange.opacity(0.3), lineWidth: 0.5))

                        VStack(alignment: .leading, spacing: 8) {
                            disclaimerPoint("Do not rely on this app for collision avoidance, port entry, or any manoeuvre where error could cause harm.")
                            disclaimerPoint("GPS, depth, and wind data may be delayed, incorrect, or missing entirely.")
                            disclaimerPoint("The autopilot controls send commands to the vessel's autopilot — always have a competent watchkeeper on deck.")
                            disclaimerPoint("Anchor alarm and MOB alerts are supplemental only. Do not replace proper watch-keeping procedures.")
                            disclaimerPoint("Always use official charts, certified navigation instruments, and follow COLREGS.")
                        }
                        .padding(16)
                        .background(Color.bgCard)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.borderColor, lineWidth: 0.5))

                        Text("This software is provided \"as is\" without warranty of any kind. The developer accepts no liability for any loss, damage, injury, or death arising from its use.")
                            .font(.caption)
                            .foregroundStyle(Color.textTertiary)
                            .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 40)
                }
            }
            .navigationTitle("Disclaimer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { showingDisclaimer = false }
                        .foregroundStyle(Color.accentCyan)
                }
            }
        }
        .presentationBackground(Color.bgPrimary)
    }

    @ViewBuilder
    private func disclaimerPoint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .font(.caption)
                .foregroundStyle(Color.statusRed.opacity(0.7))
                .padding(.top, 2)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
        }
    }

    // MARK: - Helpers

    private func applyAndConnect() {
        let host = hostInput.trimmingCharacters(in: .whitespaces)
        let port = Int(portInput) ?? 3000

        settings.signalKHost   = host
        settings.signalKPort   = port
        settings.signalKUseTLS = useTLSInput
        settings.persist()

        // Persist credentials to Keychain (never UserDefaults)
        let user = usernameInput.trimmingCharacters(in: .whitespaces)
        if user.isEmpty {
            SignalKKeychain.clear()
        } else {
            SignalKKeychain.save(username: user, password: passwordInput)
        }

        signalK.host   = host
        signalK.port   = port
        signalK.useTLS = useTLSInput
        Task { await signalK.connect() }
    }
}

// MARK: - Sub-components

private struct PresetChip: View {
    let label: String
    let icon: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button {
            action()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                Text(label)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(isActive ? Color.accentCyan.opacity(0.15) : Color.bgElevated)
            .foregroundStyle(isActive ? Color.accentCyan : Color.textSecondary)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    isActive ? Color.accentCyan.opacity(0.5) : Color.borderColor,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }
}

private struct InputField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
            TextField(placeholder, text: $text)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Color.bgElevated)
                .foregroundStyle(Color.textPrimary)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.borderColor, lineWidth: 0.5)
                )
        }
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(Color.textPrimary)
        }
    }
}
