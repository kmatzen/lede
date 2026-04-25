# Lede

> Watch your inboxes. Surface what matters.

A macOS menu-bar app that pulls notifications from Gmail, GitHub, Slack, and
Outlook (plus Google + Outlook calendars), triages them with Claude, and pins
the few items that actually need your attention to a floating panel.

**Site:** [kmatzen.com/lede](https://kmatzen.com/lede/) · **Download:** [latest release](https://github.com/kmatzen/lede/releases/latest) · **Privacy:** [PRIVACY.md](PRIVACY.md)

## Install

Download `Lede-X.Y.Z.dmg` from the [latest GitHub release](https://github.com/kmatzen/lede/releases/latest), drag `Lede.app` to `/Applications`, and double-click to launch. The build is signed with a Developer ID and notarized by Apple, so Gatekeeper won't complain.

The first launch opens a 3-step welcome panel: connect Claude, connect a source, and you're done. After that the bell sits in your menu bar and refreshes every five minutes.

## What's in the box

- **Five sources**: GitHub notifications, Gmail (headers + previews via the `gmail.metadata` scope), Slack mentions / DMs / unread channels, Outlook unread mail, and upcoming events from Google and Outlook calendars.
- **Two-stage triage**: Haiku 4.5 scores every item 0–10; Sonnet 4.6 writes a 2-sentence briefing over the top items. Items you've already seen don't get re-scored.
- **Priority accordion** with Critical / High / Medium / Low tiers, native notifications for the highest-scoring items, click-to-open, dismiss-to-hide, snooze, and quiet hours.
- **Cost-aware**: per-model token tally and a "$X used this month" line in About so you know what you're spending. Typical usage runs well under $1/month.
- **Privacy-first**: tokens in your Keychain, summaries cached on your Mac, no analytics, no servers we run. The full picture is in [PRIVACY.md](PRIVACY.md).
- **Auto-update** via Sparkle.

## Build from source

macOS 14+, Xcode 15+ or a recent `swift` toolchain:

```sh
make run
```

That builds, signs with a stable identity, bundles into `.build/debug/Lede.app`, and launches it. State lives in `~/Library/Application Support/Lede/`.

For a release build that mirrors the shipping process:

```sh
make notarize VERSION=0.1.2   # build + sign + Apple notary + staple
make dmg VERSION=0.1.2        # wrap in a .dmg + notarize that too
make sparkle-sign VERSION=0.1.2  # sign for Sparkle's appcast
```

Tests:

```sh
swift test
```

## Configuration

After install, click the bell → gear icon. The Settings panes walk you through each connection. A few notes:

- **Claude**: paste an Anthropic API key from [claude.com/settings](https://claude.com/settings). The optional subscription OAuth path is gated behind `~/Library/Application Support/Lede/config.json` containing `{"enableSubscriptionOAuth": true}` — off in shipped builds because it's outside Anthropic's TOS for third-party apps.
- **Google** (Gmail + Calendar): one-click Connect Google. The app's OAuth client is embedded; you'll see a one-time consent screen.
- **Microsoft** (Outlook + Calendar): one-click Connect Microsoft, same pattern.
- **GitHub**: OAuth device flow, no token to paste. PAT fallback under "Use a personal access token instead."
- **Slack**: requires a one-time app registration in your workspace because Slack doesn't allow generic third-party reading apps. The Settings pane shows a step-by-step with a "Copy manifest" button.

## Architecture

```
CoreEngine (@MainActor)
 ├── NotificationSource     (GitHub, Gmail, GoogleCalendar, Slack, Outlook, OutlookCalendar)
 ├── TriagePipeline          (content-hash cache → Haiku triage → Sonnet synthesis)
 │    └── AnthropicClient    (x-api-key OR OAuth bearer; 429 retry; prompt caching)
 ├── Notifier                (UNUserNotifications, click-to-open URL)
 ├── UpdateController        (Sparkle 2.x)
 └── Storage (actor)         (JSON state; secrets in Keychain)
```

All secrets live in the macOS Keychain under service `com.lede.app`. Triage cache, dismissed/notified sets, source health, and monthly usage live as JSON in the app's Application Support folder. The activity log (`lede.log`) is auto-truncated to 1MB.

## Project layout

```
Sources/Lede/         — the app (~5K LOC of Swift)
Tests/LedeTests/      — unit tests
Resources/            — Info.plist, AppIcon.icns, entitlements, Slack manifest
docs/                 — the website at kmatzen.com/lede
scripts/              — dev cert + icon generation
SHIPPING.md           — distribution checklist (notarization, Sparkle, App Store)
PRIVACY.md            — privacy policy (also rendered on the website)
```

## License

[MIT](LICENSE) © 2026 Kevin Blackburn-Matzen.
