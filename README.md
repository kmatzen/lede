# Lede

A macOS menu-bar app that pulls notifications from Gmail, GitHub, Slack, and
Outlook, triages them with Claude, and surfaces the lede — the lead items you
should see first — in a pinned floating panel.

## Features

- **Pinned panel** floating above other windows (click the menu-bar bell to toggle).
- **Intelligent triage**: Haiku 4.5 scores each item 0–10; Sonnet 4.6 writes a
  2-sentence briefing over the top items.
- **Token-efficient**: content-hash caching (unchanged items cost 0 tokens),
  prompt caching on system prompts, and cheap-model-first routing.
- **Claude subscription OAuth** (Pro/Max), with API-key fallback.

## Build & run

macOS 14+, Xcode 15+ (or a recent `swift` toolchain):

```sh
swift run
```

First run writes state to `~/Library/Application Support/Lede/`. Click the bell
in the menu bar → gear icon → configure at least one source + Claude.

## Configuration

### Claude (pick one)

- **Subscription (Claude Pro/Max)**: Settings → Claude → "Sign in with Claude".
  Browser opens, you approve, the app catches the loopback callback and stores
  tokens in your Keychain.
- **API key**: Settings → Claude → paste `sk-ant-…`.

### GitHub

Either:
- **OAuth device flow** (recommended): create an OAuth App at
  [github.com/settings/developers](https://github.com/settings/developers),
  enable "Device Flow", paste the Client ID into Settings.
- **PAT**: classic or fine-grained with `notifications` scope — works as
  fallback if you'd rather not register an app.

### Gmail

1. [console.cloud.google.com](https://console.cloud.google.com) → create a
   project, enable **Gmail API**.
2. OAuth consent screen → External (or Internal for Workspace).
3. Credentials → Create OAuth client ID → **Desktop app**.
4. Paste the Client ID into Settings → Sources → Gmail → Connect.

Only `gmail.readonly` is requested.

### Slack

1. [api.slack.com/apps](https://api.slack.com/apps) → Create New App → From scratch.
2. OAuth & Permissions → add a redirect URL starting with `http://localhost`.
3. Add User Token Scopes: `channels:history, groups:history, im:history,
   mpim:history, channels:read, groups:read, im:read, mpim:read, users:read`.
4. Install to workspace, copy Client ID + Client Secret into Settings.

### Outlook

1. [portal.azure.com](https://portal.azure.com) → App registrations → New.
2. Supported accounts: Personal (and/or Work).
3. Platform: "Mobile and desktop applications", redirect URI `http://localhost`.
4. API permissions → Microsoft Graph → Delegated: `Mail.Read` +
   `offline_access`.
5. Paste the Application (client) ID into Settings and pick the right tenant.

## Architecture

```
CoreEngine (@MainActor)
 ├── NotificationSource  (GitHub, Gmail, Slack, Outlook)
 ├── TriagePipeline      (content-hash cache → Haiku triage → Sonnet synthesis)
 │    └── AnthropicClient (x-api-key OR OAuth bearer)
 └── Storage (actor)     (JSON cache; secrets in Keychain)
```

All secrets live in the macOS Keychain under service `com.claudenotif.app`
(legacy name kept to preserve sign-in state; will migrate to `com.lede.app`).

## Status

- ✅ Claude subscription OAuth + API key
- ✅ GitHub (OAuth device flow + PAT fallback)
- ✅ Gmail (user-supplied Desktop OAuth client)
- ✅ Slack (user-supplied app)
- ✅ Outlook / Microsoft Graph (user-supplied Azure app)
- ⏳ Timer-based background refresh
- ⏳ Signed `.app` bundle + LaunchAtLogin
- ⏳ Migrate Keychain service to `com.lede.app`
