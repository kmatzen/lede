import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: CoreEngine

    var body: some View {
        TabView {
            ClaudeAuthPane(engine: engine)
                .tabItem { Label("Claude", systemImage: "brain") }
            SourcesPane(engine: engine)
                .tabItem { Label("Sources", systemImage: "bell.badge") }
            AboutPane(engine: engine)
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .padding(16)
        .frame(width: 520, height: 560)
    }
}

// MARK: - Claude auth

private struct ClaudeAuthPane: View {
    @ObservedObject var engine: CoreEngine
    @State private var apiKey: String = Keychain.get(Keychain.Key.anthropicAPIKey) ?? ""
    @State private var oauthStatus: String = ""
    @State private var busy = false
    @State private var hasOAuthState: Bool = Keychain.get(Keychain.Key.anthropicOAuthAccess) != nil
    @State private var apiKeyStatus: String = ""
    @State private var apiKeyOK: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if AppConfig.shared.enableSubscriptionOAuth {
                    section("Subscription (Claude Pro/Max)") {
                        Text("Sign in with your Claude account. A browser window will open; after you approve, the app catches the callback automatically.")
                            .font(.caption).foregroundStyle(.secondary)

                        if hasOAuthState {
                            HStack {
                                Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                                Text("Signed in.")
                                Spacer()
                                Button("Sign out") {
                                    ClaudeOAuth.signOut()
                                    hasOAuthState = false
                                    oauthStatus = ""
                                }
                            }
                        } else {
                            HStack {
                                Button("Sign in with Claude") {
                                    Task { await signIn() }
                                }
                                .buttonStyle(.borderedProminent)
                                .disabled(busy)
                                if busy { ProgressView().controlSize(.small) }
                            }
                        }

                        if !oauthStatus.isEmpty {
                            Text(oauthStatus).font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Divider()
                }

                section("API key") {
                    Text(AppConfig.shared.enableSubscriptionOAuth
                         ? "If you'd rather pay per token, paste an Anthropic API key. Either method works; OAuth wins if both are set."
                         : "Paste an Anthropic API key from console.anthropic.com. Triage costs roughly $0.01/day at typical inbox volume.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("sk-ant-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save & validate") { Task { await saveAndValidate() } }
                            .disabled(busy)
                        if busy { ProgressView().controlSize(.small) }
                        Button("Clear") {
                            apiKey = ""
                            Keychain.delete(Keychain.Key.anthropicAPIKey)
                            apiKeyStatus = ""
                        }
                    }
                    if !apiKeyStatus.isEmpty {
                        Text(apiKeyStatus)
                            .font(.caption)
                            .foregroundStyle(apiKeyOK ? .green : .orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(8)
        }
    }

    private func signIn() async {
        busy = true
        oauthStatus = "Waiting for browser approval…"
        defer { busy = false }
        do {
            let tokens = try await ClaudeOAuth.signIn()
            ClaudeOAuth.persist(tokens)
            hasOAuthState = true
            oauthStatus = ""
        } catch {
            oauthStatus = error.localizedDescription
        }
    }

    private func saveAndValidate() async {
        busy = true
        defer { busy = false }
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            apiKeyOK = false
            apiKeyStatus = "Empty key — nothing to save."
            return
        }
        // Round-trip a 1-token call to surface 401/403 immediately.
        let client = AnthropicClient(auth: .apiKey(trimmed))
        do {
            _ = try await client.complete(
                model: AnthropicClient.modelTriage,
                systemCached: "You are a test prompt.",
                user: "ping",
                maxTokens: 1,
                temperature: 0
            )
            Keychain.set(trimmed, for: Keychain.Key.anthropicAPIKey)
            apiKeyOK = true
            apiKeyStatus = "Validated and saved."
        } catch {
            apiKeyOK = false
            apiKeyStatus = error.localizedDescription
        }
    }
}

// MARK: - Sources

private struct SourcesPane: View {
    @ObservedObject var engine: CoreEngine
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GitHubPane(engine: engine)
                Divider()
                GmailPane(engine: engine)
                Divider()
                SlackPane(engine: engine)
                Divider()
                OutlookPane(engine: engine)
            }.padding(8)
        }
    }
}

/// Toggle gating whether a configured source actually contributes to refreshes.
/// Useful for "I'm in a meeting, stop showing me Slack" without nuking the OAuth token.
struct SourcePauseToggle: View {
    let source: Source
    @State private var enabled: Bool

    init(source: Source) {
        self.source = source
        self._enabled = State(initialValue: source.isEnabledByUser)
    }

    var body: some View {
        Toggle("Include in refreshes", isOn: $enabled)
            .toggleStyle(.checkbox)
            .font(.caption)
            .onChange(of: enabled) { _, newValue in
                source.isEnabledByUser = newValue
            }
    }
}

/// One-line health summary for a connected source. Shown below the
/// "Connected" badge so the user can tell at a glance whether the latest
/// fetch succeeded and how many items came back.
struct SourceHealthLine: View {
    let state: SourceState?

    var body: some View {
        if let s = state {
            HStack(spacing: 4) {
                if let err = s.lastError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).lineLimit(1).truncationMode(.middle)
                } else if let when = s.lastFetchedAt {
                    Image(systemName: "clock").foregroundStyle(.tertiary)
                    Text("Last fetch \(when, style: .relative) ago · \(s.lastItemCount) item\(s.lastItemCount == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.caption2)
        }
    }
}

// MARK: GitHub pane

private struct GitHubPane: View {
    let engine: CoreEngine
    @State private var pat: String = Keychain.get(Keychain.Key.githubPAT) ?? ""
    @State private var busy = false
    @State private var status = ""
    @State private var userCode = ""
    @State private var connected = Keychain.get(Keychain.Key.githubAccess) != nil
        || Keychain.get(Keychain.Key.githubPAT) != nil
    @State private var task: Task<Void, Never>? = nil

    var body: some View {
        section("GitHub") {
            if connected {
                HStack {
                    Label("Connected", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Disconnect") {
                        GitHubOAuth.signOut()
                        Keychain.delete(Keychain.Key.githubPAT)
                        connected = false
                        Task { await engine.clearSourceState(.github) }
                    }
                }
                SourceHealthLine(state: engine.sourceStates[.github])
                SourcePauseToggle(source: .github)
            } else {
                Text("Connect via OAuth — a code appears below; click to open GitHub with it pre-filled.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Connect with GitHub") { task = Task { await connectDevice() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                    if busy {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { task?.cancel() }
                    }
                }
                if !userCode.isEmpty {
                    HStack {
                        Text("Code:")
                        Text(userCode).font(.system(.body, design: .monospaced, weight: .bold))
                            .textSelection(.enabled)
                        Text("— waiting for approval…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider().padding(.vertical, 4)
                Text("Or paste a PAT with `notifications` scope:")
                    .font(.caption).foregroundStyle(.secondary)
                SecureField("ghp_… or github_pat_…", text: $pat)
                    .textFieldStyle(.roundedBorder)
                Button("Save PAT") {
                    if pat.isEmpty {
                        Keychain.delete(Keychain.Key.githubPAT)
                    } else {
                        Keychain.set(pat, for: Keychain.Key.githubPAT)
                        connected = true
                    }
                }
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connectDevice() async {
        busy = true
        status = ""
        defer { busy = false }
        do {
            let code = try await GitHubOAuth.requestDeviceCode()
            userCode = code.user_code
            GitHubOAuth.openVerificationPage(code)
            let token = try await GitHubOAuth.pollForToken(deviceCode: code)
            GitHubOAuth.persist(token)
            userCode = ""
            connected = true
            Task { await engine.refresh(force: true) }
        } catch is CancellationError {
            status = "Cancelled."
            userCode = ""
        } catch {
            status = error.localizedDescription
            userCode = ""
        }
    }
}

// MARK: Gmail pane

private struct GmailPane: View {
    let engine: CoreEngine
    @State private var busy = false
    @State private var status = ""
    @State private var connected = Keychain.get(Keychain.Key.gmailRefresh) != nil
    @State private var task: Task<Void, Never>? = nil

    var body: some View {
        section("Google (Gmail + Calendar)") {
            if connected {
                HStack {
                    Label("Connected", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Disconnect") {
                        GoogleOAuth.signOut()
                        connected = false
                        Task {
                            await engine.clearSourceState(.gmail)
                            await engine.clearSourceState(.calendar)
                        }
                    }
                }
                SourceHealthLine(state: engine.sourceStates[.gmail])
                SourceHealthLine(state: engine.sourceStates[.calendar])
                SourcePauseToggle(source: .gmail)
                SourcePauseToggle(source: .calendar)
            } else {
                Text("Reads Gmail headers + snippets (never bodies) and upcoming calendar events.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Connect Google") { task = Task { await connect() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                    if busy {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { task?.cancel() }
                    }
                }
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connect() async {
        busy = true
        status = ""
        defer { busy = false }
        do {
            let tokens = try await GoogleOAuth.connect()
            GoogleOAuth.persist(tokens)
            connected = true
            Task { await engine.refresh(force: true) }
        } catch is CancellationError {
            status = "Cancelled."
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: Slack pane

private struct SlackPane: View {
    let engine: CoreEngine
    @State private var clientID: String = Keychain.get(Keychain.Key.slackClientID) ?? ""
    @State private var clientSecret: String = Keychain.get(Keychain.Key.slackClientSecret) ?? ""
    @State private var busy = false
    @State private var status = ""
    @State private var connected = Keychain.get(Keychain.Key.slackAccess) != nil
    @State private var task: Task<Void, Never>? = nil

    var body: some View {
        section("Slack") {
            if connected {
                HStack {
                    Label("Connected", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Disconnect") {
                        SlackOAuth.signOut()
                        connected = false
                        Task { await engine.clearSourceState(.slack) }
                    }
                }
                SourceHealthLine(state: engine.sourceStates[.slack])
                SourcePauseToggle(source: .slack)
            } else {
                Text("Create a Slack app at api.slack.com/apps — pick 'From a manifest' and paste Resources/slack-app-manifest.yml from the repo. Install to your workspace, then paste Client ID + Secret below.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Client ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Client Secret", text: $clientSecret)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Connect Slack") { task = Task { await connect() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(clientID.isEmpty || clientSecret.isEmpty || busy)
                    if busy {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { task?.cancel() }
                    }
                }
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connect() async {
        Keychain.set(clientID, for: Keychain.Key.slackClientID)
        Keychain.set(clientSecret, for: Keychain.Key.slackClientSecret)
        busy = true
        status = ""
        defer { busy = false }
        do {
            let creds = try await SlackOAuth.connect(clientID: clientID, clientSecret: clientSecret)
            SlackOAuth.persist(creds)
            connected = true
            Task { await engine.refresh(force: true) }
        } catch is CancellationError {
            status = "Cancelled."
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: Outlook pane

private struct OutlookPane: View {
    let engine: CoreEngine
    @State private var busy = false
    @State private var status = ""
    @State private var connected = Keychain.get(Keychain.Key.outlookRefresh) != nil
    @State private var task: Task<Void, Never>? = nil

    var body: some View {
        section("Microsoft (Outlook + Calendar)") {
            if connected {
                HStack {
                    Label("Connected", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Disconnect") {
                        MicrosoftOAuth.signOut()
                        connected = false
                        Task {
                            await engine.clearSourceState(.outlook)
                            await engine.clearSourceState(.calendar)
                        }
                    }
                }
                SourceHealthLine(state: engine.sourceStates[.outlook])
                SourceHealthLine(state: engine.sourceStates[.calendar])
                SourcePauseToggle(source: .outlook)
            } else {
                Text("Reads Outlook unread mail and upcoming calendar events.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Connect Microsoft") { task = Task { await connect() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                    if busy {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { task?.cancel() }
                    }
                }
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connect() async {
        busy = true
        status = ""
        defer { busy = false }
        do {
            let tokens = try await MicrosoftOAuth.connect()
            MicrosoftOAuth.persist(tokens)
            connected = true
            Task { await engine.refresh(force: true) }
        } catch is CancellationError {
            status = "Cancelled."
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    let engine: CoreEngine
    @State private var dismissedCount: Int = 0
    @State private var launchAtLogin: Bool = LaunchAtLogin.isEnabled
    @AppStorage("lede.refreshIntervalSeconds") private var refreshSeconds: Double = 300
    @AppStorage("lede.quietEnabled") private var quietEnabled: Bool = false
    @AppStorage("lede.quietStartHour") private var quietStart: Int = 22
    @AppStorage("lede.quietEndHour") private var quietEnd: Int = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lede 0.1").font(.title2).bold()
            Text("A pinned menu-bar digest that surfaces the most important items from your inboxes.")
                .foregroundStyle(.secondary)

            Toggle("Launch at login", isOn: $launchAtLogin)
                .padding(.top, 6)
                .onChange(of: launchAtLogin) { _, newValue in
                    LaunchAtLogin.setEnabled(newValue)
                    // Reflect what actually took (in case register failed).
                    launchAtLogin = LaunchAtLogin.isEnabled
                }

            HStack {
                Text("Refresh every")
                Picker("", selection: $refreshSeconds) {
                    Text("1 min").tag(60.0)
                    Text("5 min").tag(300.0)
                    Text("15 min").tag(900.0)
                    Text("30 min").tag(1800.0)
                    Text("Off").tag(0.0)
                }.labelsHidden().frame(width: 100)
            }
            .onChange(of: refreshSeconds) { _, newValue in
                if newValue > 0 {
                    engine.startBackgroundRefresh(interval: newValue)
                } else {
                    engine.stopBackgroundRefresh()
                }
            }

            Toggle("Quiet hours (auto-snooze notifications)", isOn: $quietEnabled)
            if quietEnabled {
                HStack {
                    Text("From").font(.caption)
                    Picker("", selection: $quietStart) {
                        ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) }
                    }.labelsHidden().frame(width: 80)
                    Text("until").font(.caption)
                    Picker("", selection: $quietEnd) {
                        ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) }
                    }.labelsHidden().frame(width: 80)
                }
            }

            Text("Anthropic usage this month")
                .font(.headline).padding(.top, 8)
            VStack(alignment: .leading, spacing: 4) {
                let u = engine.usage
                Text("Input: \(formatTokens(u.inputTokens))   Output: \(formatTokens(u.outputTokens))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Cache reads: \(formatTokens(u.cacheReads))   Cache writes: \(formatTokens(u.cacheWrites))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(estimatedCost(u))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Text("Token efficiency")
                .font(.headline).padding(.top, 8)
            VStack(alignment: .leading, spacing: 4) {
                Text("• Content-hash cache: unchanged items cost 0 tokens").font(.caption)
                Text("• Haiku for triage, Sonnet only for top-N synthesis").font(.caption)
                Text("• Prompt caching on system prompts (~90% discount on re-use)").font(.caption)
                Text("• Gmail scope `gmail.metadata` — headers + snippets only").font(.caption)
            }.foregroundStyle(.secondary)

            Text("Dismissed items").font(.headline).padding(.top, 8)
            HStack {
                Text("\(dismissedCount) item(s) dismissed and filtered out.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset dismissals") {
                    Task {
                        await engine.clearDismissals()
                        await engine.refresh(force: true)
                        dismissedCount = 0
                    }
                }
                .disabled(dismissedCount == 0)
            }

            Text("Debug").font(.headline).padding(.top, 8)
            HStack {
                Text("Pipeline writes to a log file (dedupe, fetch counts, filter decisions).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open log") {
                    NSWorkspace.shared.open(Log.fileURL)
                }
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
                }
            }
            Spacer()
        }
        .padding(8)
        .task { dismissedCount = await engine.dismissCount() }
    }
}

// MARK: - helpers

@ViewBuilder
private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        Text(title).font(.headline)
        content()
    }
}

/// Rough $ estimate using Haiku 4.5 pricing (where most calls go).
/// Sonnet synthesis is ~5x more expensive but contributes a small share.
/// Numbers from anthropic.com/pricing as of April 2026.
private func estimatedCost(_ u: UsageTotals) -> String {
    let inPrice = 1.00 / 1_000_000.0       // Haiku 4.5 input ($/token)
    let outPrice = 5.00 / 1_000_000.0      // Haiku 4.5 output
    let cacheReadPrice = 0.10 / 1_000_000.0
    let cacheWritePrice = 1.25 / 1_000_000.0
    let dollars = Double(u.inputTokens) * inPrice
        + Double(u.outputTokens) * outPrice
        + Double(u.cacheReads) * cacheReadPrice
        + Double(u.cacheWrites) * cacheWritePrice
    if dollars < 0.01 {
        return "Estimated cost: <$0.01 (Haiku rates)"
    }
    return String(format: "Estimated cost: $%.2f (Haiku rates, Sonnet synthesis adds ~10%%)", dollars)
}

/// "1.2M" / "456K" / "789" — compact token counts for the About usage line.
private func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 {
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }
    if n >= 1_000 {
        return String(format: "%.0fK", Double(n) / 1_000)
    }
    return "\(n)"
}
