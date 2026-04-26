# Releasing Lede

Lede ships from GitHub Releases as a notarized, EdDSA-signed `.dmg`. Existing
installs auto-update via Sparkle. Cutting a release is one git command.

## Cut a release

```sh
git tag v0.1.4 && git push origin v0.1.4
```

`.github/workflows/release.yml` does the rest:

1. Universal release build (arm64 + x86_64) signed with Developer ID.
2. Submit to Apple's notary, staple the ticket.
3. Wrap in a `.dmg`, notarize + staple that too.
4. EdDSA-sign with the Sparkle key.
5. Create a GitHub Release and attach the `.dmg`.
6. Auto-commit the new `<item>` to `docs/appcast.xml` and bump the version
   strings in `docs/index.html`. GitHub Pages serves the appcast; existing
   installs see the update on their next Sparkle check.

End-to-end: ~10 minutes from `git push` to a downloadable release.

## Required repo secrets

Configure under Settings → Secrets and variables → Actions. The workflow's
header has one-line provenance for each.

| Secret                        | Where it comes from                                                  |
| ----------------------------- | -------------------------------------------------------------------- |
| `APPLE_ID`                    | your Apple Developer account email                                   |
| `APPLE_TEAM_ID`               | developer.apple.com → Membership                                     |
| `APPLE_APP_SPECIFIC_PASSWORD` | appleid.apple.com → Sign-In and Security → App-Specific Passwords    |
| `DEVELOPER_ID_CERT_P12`       | base64 of your Developer ID Application identity exported as `.p12`  |
| `DEVELOPER_ID_CERT_PASSWORD`  | password used to encrypt that `.p12`                                 |
| `SPARKLE_PRIVATE_KEY`         | `security find-generic-password -s 'https://sparkle-project.org' -w` |

## Re-running a tag

The appcast publish step is idempotent (replaces an existing `<item>` for the
same version), but the GitHub Release is not — you'll get a "release already
exists" error. To retry:

```sh
gh release delete vX.Y.Z --yes
git tag -d vX.Y.Z && git push origin :refs/tags/vX.Y.Z
git tag vX.Y.Z && git push origin vX.Y.Z
```

## Manual fallback

If the workflow breaks, replicate it locally:

```sh
make dmg VERSION=X.Y.Z          # build → sign → notarize → DMG → notarize DMG
make sparkle-sign VERSION=X.Y.Z # prints the appcast <enclosure> attributes
```

Then upload the DMG to a new GitHub Release at `vX.Y.Z`, paste the Sparkle
attributes into a fresh `<item>` in `docs/appcast.xml`, and bump the version
strings in `docs/index.html`.

## Why direct-only, not the App Store

The Store path requires a sandboxed second build (Sparkle stripped, the
subscription-OAuth code path compile-flagged out, Keychain access groups
configured) and ongoing maintenance of two binaries. The pickup — users who
categorically refuse to install non-Store apps — is too small to justify the
recurring cost.
