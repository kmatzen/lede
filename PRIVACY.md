# Privacy

Lede is a personal triage tool. Our default posture is: as little data as possible, kept on your Mac, never shared with us.

## What Lede reads

When you connect a source, Lede reads only what's needed to summarize:

- **GitHub** — your unread notifications via the GitHub REST API. Repository metadata, notification reasons, subject titles. Lede does not read repository contents.
- **Gmail** — message **headers** (`From`, `Subject`, `Date`, labels) and the short server-generated `snippet`. Lede uses the `gmail.metadata` OAuth scope, which means it cannot read message bodies or attachments.
- **Slack** — channel and DM metadata, and the most recent message of any conversation flagged unread by Slack. Read using user-level OAuth scopes (no bot token).
- **Outlook (Microsoft Graph)** — unread inbox messages: subject, from, body preview, received date.
- **Calendars** — upcoming events for the next 24 hours: title, start time, organizer, your RSVP status.

## Where Lede sends data

Two places, and only two:

1. **The provider's API** (GitHub, Google, Slack, Microsoft) over HTTPS — this is unavoidable to fetch the data in the first place.
2. **Anthropic's `/v1/messages` API** — the title, sender, and snippet of each item is sent to Anthropic's Claude model so it can score importance and write a one-line summary. Anthropic's privacy policy applies to this leg: <https://www.anthropic.com/legal/privacy>.

Nothing else leaves your Mac. Lede has no analytics, no telemetry, no crash reporting service, no CDN — it's a single Swift app that talks to four providers and Anthropic.

## Where data is stored

Locally, in `~/Library/Application Support/Lede/`:

- `triage_cache.json` — the LLM's score and one-line summary for items you've seen, keyed by content hash. Capped to 30 days.
- `last_digest.json` — the most recent digest the panel renders.
- `dismissed.json` — content hashes you clicked Dismiss on.
- `notified.json` — content hashes Lede has already shown a notification for, so banners don't repeat.
- `source_state.json` — last fetch time, item count, last error per source.
- `usage.json` — running monthly token usage for cost transparency.
- `lede.log` — recent diagnostics. Truncated to ~1MB.

Auth tokens (Anthropic API key, GitHub token, Google refresh token, Slack token, Microsoft refresh token) live in the macOS Keychain under service `com.lede.app`. Standard macOS access control applies — only Lede can read them.

## What Lede does not do

- No analytics. There is no third-party SDK for tracking, performance, attribution, or anything like it.
- No data sharing. Lede has no server.
- No background reading without your consent. If you Disconnect a source in Settings, the OAuth token is deleted from your Keychain immediately.

## Your data, your call

- **Disconnecting** a source (Settings → Sources → Disconnect) revokes Lede's access to that account and deletes the token from your Keychain.
- **Reset dismissals** (Settings → About) clears the dismissed-item set.
- **Quitting** Lede stops all activity. Removing the app from `/Applications` and deleting `~/Library/Application Support/Lede/` removes everything Lede ever wrote.

## Contact

If you find a bug or have a privacy question, open an issue at <https://github.com/kmatzen/lede>.

Last updated: 2026-04-24.
