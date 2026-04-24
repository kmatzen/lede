import SwiftUI

struct SettingsView: View {
    @ObservedObject var engine: CoreEngine

    var body: some View {
        TabView {
            ClaudeAuthPane(engine: engine)
                .tabItem { Label("Claude", systemImage: "brain") }
            SourcesPane()
                .tabItem { Label("Sources", systemImage: "bell.badge") }
            AboutPane()
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
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

                section("API key (fallback)") {
                    Text("If you'd rather pay per token, paste an Anthropic API key. Either method works; OAuth wins if both are set.")
                        .font(.caption).foregroundStyle(.secondary)
                    SecureField("sk-ant-…", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save") {
                            if apiKey.isEmpty {
                                Keychain.delete(Keychain.Key.anthropicAPIKey)
                            } else {
                                Keychain.set(apiKey, for: Keychain.Key.anthropicAPIKey)
                            }
                        }
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
}

// MARK: - Sources

private struct SourcesPane: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                GitHubPane()
                Divider()
                GmailPane()
                Divider()
                SlackPane()
                Divider()
                OutlookPane()
            }.padding(8)
        }
    }
}

// MARK: GitHub pane

private struct GitHubPane: View {
    @State private var clientID: String = Keychain.get(Keychain.Key.githubClientID) ?? ""
    @State private var pat: String = Keychain.get(Keychain.Key.githubPAT) ?? ""
    @State private var busy = false
    @State private var status = ""
    @State private var userCode = ""
    @State private var connected = Keychain.get(Keychain.Key.githubAccess) != nil
        || Keychain.get(Keychain.Key.githubPAT) != nil

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
                    }
                }
            } else {
                Text("Connect via OAuth device flow (recommended) or paste a PAT with `notifications` scope.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Device flow needs an OAuth App client ID — create one at github.com/settings/developers with 'Enable Device Flow' turned on.")
                    .font(.caption2).foregroundStyle(.tertiary)
                TextField("OAuth App Client ID (Iv1.… or Ov23li…)", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Connect via OAuth") { Task { await connectDevice() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(clientID.isEmpty || busy)
                    if busy { ProgressView().controlSize(.small) }
                }
                if !userCode.isEmpty {
                    HStack {
                        Text("Enter this code:")
                        Text(userCode).font(.system(.body, design: .monospaced, weight: .bold))
                            .textSelection(.enabled)
                    }
                }
                Divider().padding(.vertical, 4)
                Text("Or PAT fallback:").font(.caption).foregroundStyle(.secondary)
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
        Keychain.set(clientID, for: Keychain.Key.githubClientID)
        busy = true
        status = ""
        defer { busy = false }
        do {
            let code = try await GitHubOAuth.requestDeviceCode(clientID: clientID)
            userCode = code.user_code
            GitHubOAuth.openVerificationPage(code)
            let token = try await GitHubOAuth.pollForToken(clientID: clientID, deviceCode: code)
            GitHubOAuth.persist(token)
            userCode = ""
            connected = true
        } catch {
            status = error.localizedDescription
            userCode = ""
        }
    }
}

// MARK: Gmail pane

private struct GmailPane: View {
    @State private var clientID: String = Keychain.get(Keychain.Key.gmailClientID) ?? ""
    @State private var busy = false
    @State private var status = ""
    @State private var connected = Keychain.get(Keychain.Key.gmailRefresh) != nil

    var body: some View {
        section("Gmail") {
            if connected {
                HStack {
                    Label("Connected", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Disconnect") {
                        GoogleOAuth.signOut()
                        connected = false
                    }
                }
            } else {
                Text("Create a 'Desktop app' OAuth client in Google Cloud Console, enable the Gmail API, then paste the Client ID here.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("xxxxxxxx.apps.googleusercontent.com", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Connect Gmail") { Task { await connect() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(clientID.isEmpty || busy)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connect() async {
        Keychain.set(clientID, for: Keychain.Key.gmailClientID)
        busy = true
        status = ""
        defer { busy = false }
        do {
            let tokens = try await GoogleOAuth.connect(clientID: clientID)
            GoogleOAuth.persist(tokens)
            connected = true
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: Slack pane

private struct SlackPane: View {
    @State private var clientID: String = Keychain.get(Keychain.Key.slackClientID) ?? ""
    @State private var clientSecret: String = Keychain.get(Keychain.Key.slackClientSecret) ?? ""
    @State private var busy = false
    @State private var status = ""
    @State private var connected = Keychain.get(Keychain.Key.slackAccess) != nil

    var body: some View {
        section("Slack") {
            if connected {
                HStack {
                    Label("Connected", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Disconnect") {
                        SlackOAuth.signOut()
                        connected = false
                    }
                }
            } else {
                Text("Create a Slack app at api.slack.com/apps, add a loopback redirect URL starting with http://localhost, then paste Client ID and Secret.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Client ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Client Secret", text: $clientSecret)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Connect Slack") { Task { await connect() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(clientID.isEmpty || clientSecret.isEmpty || busy)
                    if busy { ProgressView().controlSize(.small) }
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
            let token = try await SlackOAuth.connect(clientID: clientID, clientSecret: clientSecret)
            Keychain.set(token, for: Keychain.Key.slackAccess)
            connected = true
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: Outlook pane

private struct OutlookPane: View {
    @State private var clientID: String = Keychain.get(Keychain.Key.outlookClientID) ?? ""
    @State private var tenant: String = Keychain.get(Keychain.Key.outlookTenant) ?? "common"
    @State private var busy = false
    @State private var status = ""
    @State private var connected = Keychain.get(Keychain.Key.outlookRefresh) != nil

    var body: some View {
        section("Outlook") {
            if connected {
                HStack {
                    Label("Connected", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    Spacer()
                    Button("Disconnect") {
                        MicrosoftOAuth.signOut()
                        connected = false
                    }
                }
            } else {
                Text("Register a Desktop app in Azure Portal with Mail.Read + offline_access delegated permissions, then paste its Application (client) ID.")
                    .font(.caption).foregroundStyle(.secondary)
                TextField("Application (client) ID", text: $clientID)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("Tenant:").font(.caption)
                    Picker("", selection: $tenant) {
                        Text("Personal + Work (common)").tag("common")
                        Text("Personal only (consumers)").tag("consumers")
                        Text("Work only (organizations)").tag("organizations")
                    }.labelsHidden()
                }
                HStack {
                    Button("Connect Outlook") { Task { await connect() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(clientID.isEmpty || busy)
                    if busy { ProgressView().controlSize(.small) }
                }
            }
            if !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connect() async {
        Keychain.set(clientID, for: Keychain.Key.outlookClientID)
        Keychain.set(tenant, for: Keychain.Key.outlookTenant)
        busy = true
        status = ""
        defer { busy = false }
        do {
            let tokens = try await MicrosoftOAuth.connect(clientID: clientID, tenant: tenant)
            MicrosoftOAuth.persist(tokens)
            connected = true
        } catch {
            status = error.localizedDescription
        }
    }
}

// MARK: - About

private struct AboutPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Lede 0.1").font(.title2).bold()
            Text("A pinned menu-bar digest that surfaces the most important items from your inboxes.")
                .foregroundStyle(.secondary)
            Text("Token efficiency")
                .font(.headline).padding(.top, 8)
            VStack(alignment: .leading, spacing: 4) {
                Text("• Content-hash cache: unchanged items cost 0 tokens").font(.caption)
                Text("• Haiku for triage, Sonnet only for top-N synthesis").font(.caption)
                Text("• Prompt caching on system prompts (~90% discount on re-use)").font(.caption)
                Text("• Gmail pre-filtered server-side (unread, no promotions)").font(.caption)
            }.foregroundStyle(.secondary)
            Spacer()
        }.padding(8)
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
