# Releasing (maintainer only)

Releases are **maintainer-only**: building a distributable Shadowtype requires Apple Developer ID
signing and notarization, which depend on the maintainer's Apple Developer credentials. Contributors
can't notarize, so there is **no release CI** — releases are cut locally via `bin/menu`.

This guide describes the flow at a high level. The release scripts (`bin/menu`,
`scripts/release.sh`, `scripts/make-app.sh`) are the source of truth for exact steps.

## Prerequisites (one-time)

- **Apple Developer ID** — a "Developer ID Application" code-signing certificate installed in the
  login keychain. `bin/menu`'s preflight checks for it.
- **notarytool credentials** — a stored keychain profile created with
  `xcrun notarytool store-credentials` (Apple ID + app-specific password + Team ID). The
  Setup ▸ "Store notarytool credentials" item in `bin/menu` launches this.
- **`gh` CLI authenticated** — `gh auth login`, so the release can create the GitHub Release and
  upload assets.

There are **no release signing keys**: update authenticity rests on GitHub TLS + Apple
notarization. The updater verifies each download by SHA-256, `codesign --verify --deep --strict`,
and a signing-identity continuity check (the new build must carry the same Team/identifier as the
running app, which also protects TCC grants).

## Cutting a release

Run the menu and pick a release type:

```sh
./bin/menu
```

The flow:

1. **Preflight** — verifies the Developer ID identity, the `gh` CLI auth, and the notary
   configuration before doing anything.
2. **Version + build** — proposes the next version bump and auto-increments the monotonic **build**
   number (the updater's ordering key; it must always increase). You confirm release notes and
   whether the update is mandatory.
3. **Build, sign, notarize** — builds a Developer-ID + hardened-runtime `.app`, relocates the
   bundled dylibs so it runs without Homebrew, packages a `.zip` (the auto-updater feed) and a
   `.dmg` (drag-to-Applications first install), then submits to Apple notarytool and staples the
   ticket.
4. **Publish to GitHub Releases** — creates a GitHub Release tagged `v<version>` with the `.zip`,
   `.dmg`, and an updater manifest (`latest.json`) as assets. The in-app updater reads the manifest
   to discover and download newer builds.
5. **Homebrew cask** — bumps the cask in the Homebrew tap (`dario-valles/homebrew-shadowtype`) to
   point at the new release assets and checksums.

After a successful release, the menu bumps and (optionally) commits the build counter.

## Beta releases

A **beta** is published as a GitHub **prerelease** on a separate beta channel. It uses the same
build → sign → notarize → publish flow; the in-app updater treats the beta channel independently so
beta testers get prereleases without affecting stable users. The menu can also promote a beta to
stable without rebuilding.

## Secrets

Never commit secrets. Code-signing identities and notary credentials live in the macOS keychain and
are never in the repo. The app ships no embedded signing keys — there is nothing secret to commit.
