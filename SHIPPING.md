# Shipping checklist

The code is ready. Here's what only you can do — split into a fast direct-distribution path (a notarized `.dmg` users can download) and a slower Mac App Store path.

## Direct distribution (notarized .dmg) — 1–2 days of clicking

### Apple side

- [ ] Enroll in the [Apple Developer Program](https://developer.apple.com/programs/) ($99/yr). Required for anything that gets past Gatekeeper on other people's Macs.
- [ ] Create a **Developer ID Application** certificate at [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates). Download + double-click to install in your login keychain.
- [ ] Generate an **App-Specific Password** at [appleid.apple.com](https://appleid.apple.com) → Sign-In and Security → App-Specific Passwords. Label it "lede notarization" or similar.
- [ ] Store credentials in a notarytool keychain profile so the Makefile can reach them:
  ```
  xcrun notarytool store-credentials lede-notary \
      --apple-id YOU@example.com \
      --team-id YOUR_TEAM_ID \
      --password APP_SPECIFIC_PASSWORD
  ```

### App identity

- [ ] **App icon.** Need a 1024×1024 PNG. Convert to `.icns` with `iconutil` (or use Preview/Sketch/Figma export). Drop into `Resources/AppIcon.icns` and add to the bundle in the Makefile (one extra `cp` line + `CFBundleIconFile = AppIcon` in Info.plist).
- [ ] **Privacy Policy URL.** A one-page GitHub Pages or Notion page is fine. Must mention what data Lede reads (mail headers, calendar, GitHub notifications, Slack), that it stays on-device + Anthropic API, and that nothing else is collected.
- [ ] **Hosting** for the `.dmg` (GitHub Releases is free + adequate).

### Build + ship

- [ ] `make release-sign` to confirm the universal binary signs cleanly with your Developer ID.
- [ ] `make notarize` — Apple's notary returns in 1–5 minutes; the staple step embeds the ticket so the app launches offline.
- [ ] Wrap the notarized `Lede.app` in a `.dmg` (e.g. with `create-dmg` from Homebrew) and upload.

### Sparkle (auto-update)

Sparkle is wired up but its `SUFeedURL` and `SUPublicEDKey` in `Resources/Info.plist` are placeholders. Until you fill them in, Sparkle silently no-ops.

- [ ] Generate an EdDSA signing keypair: `./scripts/generate_keys` (ships with Sparkle in `~/Library/Developer/Xcode/DerivedData/.../checkouts/Sparkle/bin/`, or download from the [Sparkle releases page](https://github.com/sparkle-project/Sparkle/releases)). Keep the **private** key safe; this is what authorizes update bundles.
- [ ] Put the **public** key into `Info.plist`'s `SUPublicEDKey`.
- [ ] Host an `appcast.xml` somewhere (GitHub Pages works) and put its URL in `SUFeedURL`. The `generate_appcast` tool that ships with Sparkle scaffolds this from a folder of release `.dmg`s.
- [ ] Each release: `make notarize`, sign the `.dmg` with the EdDSA private key (`sign_update lede-1.0.0.dmg path/to/private.key`), append a `<item>` to `appcast.xml`, push.

## Mac App Store path — additional 1–3 weeks

If you decide to do this *as well as* direct, expect to maintain two builds.

### Code work (mine if you want — let me know)

- [ ] **Sandbox the app.** Swap `Resources/Lede.entitlements` to:
  ```
  com.apple.security.app-sandbox            = true
  com.apple.security.network.client         = true
  com.apple.security.network.server         = true   (loopback OAuth)
  keychain-access-groups                    = ["$(TeamIdentifierPrefix)com.lede.app"]
  ```
- [ ] Verify the loopback OAuth listener still binds under sandbox (it should — `network.server` covers it).
- [ ] Verify all Keychain reads/writes work with the access-group set.
- [ ] Subscription OAuth is now gated by a runtime config (`~/Library/Application Support/Lede/config.json` with `"enableSubscriptionOAuth": true`). The App Store binary is the same binary; reviewers see only the API-key flow because no config is shipped. Personal users opt in by dropping the file. **The OAuth code is still in the binary** — if Apple's review goes deep enough to inspect strings/symbols, this still surfaces. If you want zero exposure, replace the runtime check with `#if SUBSCRIPTION_OAUTH` later.
- [ ] Decide whether to keep Slack as user-supplied creds (works on store) or distribute the Slack app publicly via api.slack.com (review process).

### Apple side

- [ ] Add a **Mac App Distribution** certificate.
- [ ] Register `com.lede.app` as a Bundle ID in App Store Connect.
- [ ] Create the App Store Connect listing — name, subtitle, primary category (Productivity), age rating questionnaire.
- [ ] Marketing assets:
  - 1280×800 or 1440×900 screenshots (need at least 1, recommend 4–5)
  - Short description (≤170 chars subtitle, ≤4000 chars description)
  - Keywords (100 chars)
  - Promotional text (170 chars)
- [ ] Privacy nutrition labels (App Privacy) — declare Mail, Calendar, Code (GitHub), Messaging (Slack) usage. Mark all as "linked to user only on your device" since it never leaves the user's Mac (except to Anthropic API).

### Submit

- [ ] Build with App Store certificate + sandbox entitlements.
- [ ] Upload via `xcrun altool` or Transporter.app.
- [ ] Submit for review. Initial reviews currently take ~24 hours.

## Things that aren't blockers but are worth doing before strangers use it

- [ ] Wider testing — connect all four sources, verify nothing spammy gets through triage.
- [ ] First-run experience — currently the panel says "Welcome → Open Settings." Could auto-open Settings on first launch when no creds.
- [ ] Make calendar-event triage smarter — right now Haiku scores a meeting in 5 minutes only as high as a meeting in 5 hours. Could special-case time-sensitivity in the prompt.
- [ ] Migrate Keychain service `com.claudenotif.app` → `com.lede.app` (legacy name lingers from the project rename).
- [ ] Crash log capture (basic: redirect stderr to a rolling file in Application Support).
- [ ] Anthropic API key from the store build's user-facing copy: explain costs roughly ("triage costs ~$0.01/day at typical inbox volume").

## What I'd do tomorrow

1. App icon (single biggest visible polish)
2. `make release-sign` end-to-end on your machine to make sure your Developer ID works
3. Privacy policy page (one paragraph, takes 10 min)
4. Notarize once, distribute via `.dmg` to a couple of friends
5. Use it for a week, fix what's broken
6. *Then* decide if App Store is worth the sandbox + ToS rework

The direct path gets you 90% of the value for 10% of the work.
