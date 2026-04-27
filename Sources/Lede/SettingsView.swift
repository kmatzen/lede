import SwiftUI
import AppKit

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
                Text("Lede uses Claude to read your messages and tell you which ones matter. Set up access here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)

                if AppConfig.shared.enableSubscriptionOAuth {
                    section("Sign in with Claude") {
                        Text("Use your existing Claude Pro or Max subscription — no extra cost beyond what you already pay.")
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

                section(AppConfig.shared.enableSubscriptionOAuth ? "Or use an API key" : "Connect Claude") {
                    Text(AppConfig.shared.enableSubscriptionOAuth
                         ? "Pay-as-you-go alternative. Either option works; the subscription wins if both are set."
                         : "Paste an Anthropic API key from claude.com/settings. Lede uses it to score and summarize your messages — typically less than $1/month at normal inbox volume.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("Paste your API key here", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save") { Task { await saveAndValidate() } }
                            .buttonStyle(.borderedProminent)
                            .disabled(busy || apiKey.isEmpty)
                        if busy { ProgressView().controlSize(.small) }
                        Spacer()
                        if !apiKey.isEmpty {
                            Button("Remove") {
                                apiKey = ""
                                Keychain.delete(Keychain.Key.anthropicAPIKey)
                                apiKeyStatus = ""
                            }
                        }
                    }
                    if !apiKeyStatus.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: apiKeyOK ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            Text(apiKeyStatus).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.caption)
                        .foregroundStyle(apiKeyOK ? .green : .orange)
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
            apiKeyStatus = "Working — saved."
        } catch {
            apiKeyOK = false
            apiKeyStatus = "Couldn't connect to Claude with that key. Double-check it and try again."
        }
    }
}

// MARK: - Sources

private struct SourcesPane: View {
    @ObservedObject var engine: CoreEngine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Connect any combination — Lede only watches what you give it access to. You can add more than one account per provider.")
                    .font(.callout).foregroundStyle(.secondary)
                GitHubAccountsPane(engine: engine)
                Divider()
                GoogleAccountsPane(engine: engine)
                Divider()
                SlackAccountsPane(engine: engine)
                Divider()
                MicrosoftAccountsPane(engine: engine)
            }.padding(8)
        }
    }
}

/// Per-source enable/disable toggle. Applies across every account that
/// produces items of this source — useful for "I'm in a meeting, stop showing
/// me Slack" without nuking any OAuth tokens.
struct SourcePauseToggle: View {
    let source: Source
    @State private var enabled: Bool

    init(source: Source) {
        self.source = source
        self._enabled = State(initialValue: source.isEnabledByUser)
    }

    var body: some View {
        Toggle("Watch \(source.displayName)", isOn: $enabled)
            .toggleStyle(.checkbox)
            .font(.caption)
            .onChange(of: enabled) { _, newValue in
                source.isEnabledByUser = newValue
            }
    }
}

/// One row representing a single connected account: label + per-source health
/// + Disconnect button. Shared by every provider pane.
private struct AccountRow: View {
    @ObservedObject var engine: CoreEngine
    let account: Account
    @State private var disconnecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "person.crop.circle.fill").foregroundStyle(.secondary)
                Text(account.label).fontWeight(.medium)
                Spacer()
                if disconnecting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Disconnect") {
                        disconnecting = true
                        Task {
                            await engine.disconnectAccount(account)
                            disconnecting = false
                        }
                    }
                    .controlSize(.small)
                }
            }
            ForEach(account.provider.sources, id: \.rawValue) { source in
                let key = Storage.stateKey(account: account, source: source)
                if let state = engine.sourceStates[key] {
                    SourceHealthLine(label: source.displayName, state: state)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// One-line health summary for a connected (account, source). Shows when the
/// last fetch happened and how many items came back, or any error.
struct SourceHealthLine: View {
    let label: String
    let state: SourceState

    var body: some View {
        HStack(spacing: 4) {
            if let err = state.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("\(label): \(err)").lineLimit(1).truncationMode(.middle)
            } else if let when = state.lastFetchedAt {
                Image(systemName: "clock").foregroundStyle(.tertiary)
                Text("\(label) — \(when, style: .relative) ago · \(state.lastItemCount) item\(state.lastItemCount == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
    }
}

// MARK: - GitHub

private struct GitHubAccountsPane: View {
    @ObservedObject var engine: CoreEngine
    @State private var pat: String = ""
    @State private var busy = false
    @State private var status = ""
    @State private var userCode = ""
    @State private var task: Task<Void, Never>? = nil

    private var connectedAccounts: [Account] {
        engine.accounts.filter { $0.provider == .github }
    }

    var body: some View {
        section("GitHub") {
            if connectedAccounts.isEmpty {
                Text("See your GitHub notifications (PR reviews, mentions, assigned issues) ranked by what needs your attention first.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(connectedAccounts) { account in
                    AccountRow(engine: engine, account: account)
                }
                SourcePauseToggle(source: .github)
            }

            HStack {
                Button(connectedAccounts.isEmpty ? "Connect GitHub" : "Add another GitHub account") {
                    task = Task { await connectDevice() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                if busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { task?.cancel() }
                }
            }
            if !userCode.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("GitHub opened in your browser. Enter this code there to approve:")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(userCode)
                        .font(.system(.title3, design: .monospaced, weight: .bold))
                        .textSelection(.enabled)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                }
                .padding(.top, 4)
            }
            DisclosureGroup("Use a personal access token instead") {
                Text("If you'd rather not approve a sign-in, paste a GitHub personal access token with the `notifications` scope. Lede will detect which account it belongs to.")
                    .font(.caption2).foregroundStyle(.secondary)
                SecureField("ghp_… or github_pat_…", text: $pat)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Save token") { Task { await savePAT() } }
                        .disabled(pat.isEmpty || busy)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            .font(.caption)
            .padding(.top, 4)

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
            let identity = try await GitHubOAuth.identity(token: token)
            GitHubOAuth.persistOAuth(token: token, accountID: identity.id)
            await Storage.shared.upsertAccount(Account(
                provider: .github, id: identity.id, label: identity.label, connectedAt: Date()
            ))
            await engine.reloadAccounts()
            userCode = ""
            Task { await engine.refresh(force: true) }
        } catch is CancellationError {
            status = "Cancelled."
            userCode = ""
        } catch {
            status = error.localizedDescription
            userCode = ""
        }
    }

    private func savePAT() async {
        busy = true
        status = ""
        defer { busy = false }
        let token = pat.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        do {
            let identity = try await GitHubOAuth.identity(token: token)
            GitHubOAuth.persistPAT(token: token, accountID: identity.id)
            await Storage.shared.upsertAccount(Account(
                provider: .github, id: identity.id, label: identity.label, connectedAt: Date()
            ))
            await engine.reloadAccounts()
            pat = ""
            Task { await engine.refresh(force: true) }
        } catch {
            status = "Couldn't validate token: \(error.localizedDescription)"
        }
    }
}

// MARK: - Google

private struct GoogleAccountsPane: View {
    @ObservedObject var engine: CoreEngine
    @State private var busy = false
    @State private var status = ""
    @State private var task: Task<Void, Never>? = nil

    private var connectedAccounts: [Account] {
        engine.accounts.filter { $0.provider == .google }
    }

    var body: some View {
        section("Google (Gmail + Calendar)") {
            if connectedAccounts.isEmpty {
                Text("See important Gmail messages (sender, subject, preview — never the full body) and upcoming calendar events.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(connectedAccounts) { account in
                    AccountRow(engine: engine, account: account)
                }
                SourcePauseToggle(source: .gmail)
                SourcePauseToggle(source: .calendar)
            }

            HStack {
                Button(connectedAccounts.isEmpty ? "Connect Google" : "Add another Google account") {
                    task = Task { await connect() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                if busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { task?.cancel() }
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
            let identity = try await GoogleOAuth.identity(accessToken: tokens.access_token)
            GoogleOAuth.persist(tokens, accountID: identity.id)
            await Storage.shared.upsertAccount(Account(
                provider: .google, id: identity.id, label: identity.label, connectedAt: Date()
            ))
            await engine.reloadAccounts()
            Task { await engine.refresh(force: true) }
        } catch is CancellationError {
            status = "Cancelled."
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: - Slack

private struct SlackAccountsPane: View {
    @ObservedObject var engine: CoreEngine
    @State private var clientID: String = ""
    @State private var clientSecret: String = ""
    @State private var busy = false
    @State private var status = ""
    @State private var showingAddSheet = false
    @State private var task: Task<Void, Never>? = nil

    private var connectedAccounts: [Account] {
        engine.accounts.filter { $0.provider == .slack }
    }

    var body: some View {
        section("Slack") {
            if connectedAccounts.isEmpty {
                Text("See unread channel messages, DMs, and mentions across your workspace, ranked by what's worth your attention.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(connectedAccounts) { account in
                    AccountRow(engine: engine, account: account)
                }
                SourcePauseToggle(source: .slack)
            }

            Text("Slack doesn't allow generic third-party reading apps, so each workspace needs a one-time setup in Slack itself. Lede provides the configuration; you copy and paste it.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            DisclosureGroup("Setup steps (one time per workspace, ~3 min)") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Go to api.slack.com/apps, click **Create New App**, choose **From a manifest**, pick the workspace.")
                    HStack {
                        Text("2. Paste this app configuration:")
                        Spacer()
                        Button("Copy manifest") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(slackManifestYAML, forType: .string)
                        }
                        .controlSize(.small)
                    }
                    Text("3. Click Create, then on the next page click **Install to Workspace** and approve.")
                    Text("4. On that app's settings page, find **Client ID** and **Client Secret** under **Basic Information** and paste them below.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
            .font(.caption)

            TextField("Client ID", text: $clientID)
                .textFieldStyle(.roundedBorder)
            SecureField("Client Secret", text: $clientSecret)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button(connectedAccounts.isEmpty ? "Connect Slack" : "Add Slack workspace") {
                    task = Task { await connect() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(clientID.isEmpty || clientSecret.isEmpty || busy)
                if busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { task?.cancel() }
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
            let result = try await SlackOAuth.connect(clientID: clientID, clientSecret: clientSecret)
            SlackOAuth.persist(result, clientID: clientID, clientSecret: clientSecret)
            await Storage.shared.upsertAccount(Account(
                provider: .slack, id: result.teamID, label: result.teamName, connectedAt: Date()
            ))
            await engine.reloadAccounts()
            clientID = ""
            clientSecret = ""
            Task { await engine.refresh(force: true) }
        } catch is CancellationError {
            status = "Cancelled."
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: - Microsoft

private struct MicrosoftAccountsPane: View {
    @ObservedObject var engine: CoreEngine
    @State private var busy = false
    @State private var status = ""
    @State private var task: Task<Void, Never>? = nil

    private var connectedAccounts: [Account] {
        engine.accounts.filter { $0.provider == .microsoft }
    }

    var body: some View {
        section("Microsoft (Outlook + Calendar)") {
            if connectedAccounts.isEmpty {
                Text("See unread Outlook messages and upcoming calendar events. Lede only reads — never sends or modifies.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(connectedAccounts) { account in
                    AccountRow(engine: engine, account: account)
                }
                SourcePauseToggle(source: .outlook)
                SourcePauseToggle(source: .calendar)
            }

            HStack {
                Button(connectedAccounts.isEmpty ? "Connect Microsoft" : "Add another Microsoft account") {
                    task = Task { await connect() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                if busy {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { task?.cancel() }
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
            let identity = try await MicrosoftOAuth.identity(accessToken: tokens.access_token)
            MicrosoftOAuth.persist(tokens, accountID: identity.id)
            await Storage.shared.upsertAccount(Account(
                provider: .microsoft, id: identity.id, label: identity.label, connectedAt: Date()
            ))
            await engine.reloadAccounts()
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Lede 0.1").font(.title2).bold()
                    Text("Watch your inboxes, surface what matters.")
                        .foregroundStyle(.secondary)
                }

                section("Behavior") {
                    Toggle("Open Lede when I log in", isOn: $launchAtLogin)
                        .onChange(of: launchAtLogin) { _, newValue in
                            LaunchAtLogin.setEnabled(newValue)
                            launchAtLogin = LaunchAtLogin.isEnabled
                        }

                    HStack {
                        Text("Check for new messages every")
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

                    Toggle("Stay quiet during certain hours", isOn: $quietEnabled)
                    if quietEnabled {
                        HStack(spacing: 4) {
                            Text("From").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $quietStart) {
                                ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) }
                            }.labelsHidden().frame(width: 80)
                            Text("until").font(.caption).foregroundStyle(.secondary)
                            Picker("", selection: $quietEnd) {
                                ForEach(0..<24) { Text(String(format: "%02d:00", $0)).tag($0) }
                            }.labelsHidden().frame(width: 80)
                            Spacer()
                        }
                    }
                }

                Divider()

                section("Cost this month") {
                    Text(estimatedCost(engine.usage))
                        .font(.title3).bold()
                    Text("Lede asks Claude to score and summarize your messages, which uses a small amount of API credit. Items you've already seen don't get re-scored.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                section("Dismissed items") {
                    HStack {
                        Text("You've dismissed \(dismissedCount) item\(dismissedCount == 1 ? "" : "s") that won't show again.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Show dismissed again") {
                            Task {
                                await engine.clearDismissals()
                                await engine.refresh(force: true)
                                dismissedCount = 0
                            }
                        }
                        .disabled(dismissedCount == 0)
                    }
                }

                Divider()

                DisclosureGroup("Troubleshooting") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("If Lede isn't behaving as expected, the activity log can help you (or someone helping you) figure out why.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Open activity log") { NSWorkspace.shared.open(Log.fileURL) }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
                            }
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            usageDetailRow("Input tokens", formatTokens(engine.usage.inputTokens))
                            usageDetailRow("Output tokens", formatTokens(engine.usage.outputTokens))
                            usageDetailRow("Cache reads", formatTokens(engine.usage.cacheReads))
                            usageDetailRow("Cache writes", formatTokens(engine.usage.cacheWrites))
                        }
                        .padding(.top, 4)
                    }
                    .padding(.top, 4)
                }
                .font(.callout)

                Spacer(minLength: 0)
            }
            .padding(8)
        }
        .task { dismissedCount = await engine.dismissCount() }
    }

    @ViewBuilder
    private func usageDetailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.caption)
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

/// Per-million-token prices from anthropic.com/pricing as of April 2026.
/// Unknown models fall through to Haiku rates (the cheaper guess).
private struct ModelRates {
    let input: Double
    let output: Double
    let cacheRead: Double
    let cacheWrite: Double

    func cost(_ u: ModelUsage) -> Double {
        Double(u.inputTokens) * input
            + Double(u.outputTokens) * output
            + Double(u.cacheReads) * cacheRead
            + Double(u.cacheWrites) * cacheWrite
    }
}

private func ratesFor(model: String) -> ModelRates {
    if model.contains("sonnet") {
        return ModelRates(input: 3.00 / 1e6, output: 15.00 / 1e6,
                          cacheRead: 0.30 / 1e6, cacheWrite: 3.75 / 1e6)
    }
    if model.contains("opus") {
        return ModelRates(input: 15.00 / 1e6, output: 75.00 / 1e6,
                          cacheRead: 1.50 / 1e6, cacheWrite: 18.75 / 1e6)
    }
    // Haiku — and the safe fallback.
    return ModelRates(input: 1.00 / 1e6, output: 5.00 / 1e6,
                      cacheRead: 0.10 / 1e6, cacheWrite: 1.25 / 1e6)
}

private func estimatedCost(_ u: UsageTotals) -> String {
    var dollars: Double = 0
    for (model, usage) in u.byModel {
        dollars += ratesFor(model: model).cost(usage)
    }
    let legacy = ModelUsage(
        inputTokens: u.inputTokens, outputTokens: u.outputTokens,
        cacheReads: u.cacheReads, cacheWrites: u.cacheWrites
    )
    dollars += ratesFor(model: "haiku").cost(legacy)

    if dollars < 0.01 {
        return "Less than $0.01 used this month."
    }
    return String(format: "About $%.2f used this month.", dollars)
}

/// Slack app manifest — pasted by the user during setup. Embedded so we can
/// surface it as a Copy button without depending on the repo file.
private let slackManifestYAML = """
display_information:
  name: Lede
  description: Triage Slack messages via the Lede menu-bar app.
  background_color: "#1d2533"
oauth_config:
  redirect_urls:
    - http://localhost:53682/oauth/slack
  scopes:
    user:
      - channels:history
      - channels:read
      - groups:history
      - groups:read
      - im:history
      - im:read
      - mpim:history
      - mpim:read
      - users:read
settings:
  org_deploy_enabled: false
  socket_mode_enabled: false
  token_rotation_enabled: false
"""

private func formatTokens(_ n: Int) -> String {
    if n >= 1_000_000 {
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }
    if n >= 1_000 {
        return String(format: "%.0fK", Double(n) / 1_000)
    }
    return "\(n)"
}
