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
- **Update-manifest signing key** — the PKCS#8 Ed25519 private-key PEM must live outside the repo at
  `~/.shadowtype-keys/shadowtype-update-manifest-ed25519.pem`. Keep the directory mode `0700` and
  the file mode `0600`, and point the release process at it before opening the menu:

  ```sh
  export ST_UPDATE_SIGNING_KEY="$HOME/.shadowtype-keys/shadowtype-update-manifest-ed25519.pem"
  ./bin/menu
  ```

  Back up this PEM in offline encrypted storage. **Losing it means no future update can reach
  existing installs that trust its embedded public key.** Shipping a replacement public key cannot
  repair those installs because they will reject the replacement manifest before downloading it.
- **Pinned native libraries built** — run `./scripts/build-llama.sh`. It fetches the recorded
  llama.cpp revision and installs an arm64, macOS 14-compatible static prefix under
  `vendor/llama/`; `--force` performs a clean rebuild.

The release script derives the signing key's public value and refuses to continue unless it exactly
matches the Ed25519 public key embedded in `UpdateManager`. The new updater verifies the manifest
signature before decoding any manifest fields, then verifies the downloaded archive against the
signed SHA-256. It also applies Gatekeeper assessment, `codesign --verify --deep --strict`, and a
signing-identity continuity check (the new build must carry the same Team/identifier as the running
app, which also protects TCC grants). Manifest signing and Apple's notarized code identity are
independent trust anchors.

## Cutting a release

Run the menu and pick a release type:

```sh
./bin/menu
```

The flow:

1. **Preflight** — the menu verifies the Developer ID identity, the `gh` CLI auth, and the notary
   configuration. `release.sh` additionally refuses to build if `ST_UPDATE_SIGNING_KEY` is missing,
   has unsafe permissions, or does not match the public key embedded in the app.
2. **Version + build** — proposes the next version bump and auto-increments the monotonic **build**
   number (the updater's ordering key; it must always increase). You confirm release notes and
   whether the update is mandatory.
3. **Build, sign, notarize** — builds a Developer-ID + hardened-runtime `.app` against the pinned
   static llama.cpp/ggml prefix, verifies that the executable targets macOS 14.0 and has only
   system dynamic dependencies, packages a `.zip` (the auto-updater feed) and a `.dmg`
   (drag-to-Applications first install), then submits to Apple notarytool and staples the ticket.
4. **Publish to GitHub Releases** — creates a GitHub Release tagged `v<version>` with the `.zip`,
   `.dmg`, and an Ed25519-signed updater manifest (`latest.json`) as assets. The signed payload
   carries the version, build, channel, archive URL and SHA-256, minimum build, and notes.

   `latest.json` is deliberately dual-format for build 74 (`0.2.5`) compatibility: the legacy
   manifest fields appear at the top level alongside `payload` and `signature`. Build 74 decodes
   the flat fields and ignores the envelope fields; signed-manifest clients ignore the unsigned
   flat fields and trust only the verified payload. The release script derives both views from the
   same payload and asserts that they match. The flat fields may be removed only when no supported
   install predates the signed-manifest build.
5. **Homebrew cask** — bumps the cask in the Homebrew tap (`dario-valles/homebrew-shadowtype`) to
   point at the new release assets and checksums.

After a successful release, the menu bumps and (optionally) commits the build counter.

## Beta releases

A **beta** is published as a GitHub **prerelease** on a separate beta channel. It uses the same
build → sign → notarize → publish flow; the in-app updater treats the beta channel independently so
beta testers get prereleases without affecting stable users.

Do not use the menu's current "promote beta to stable" action. A beta manifest's signed payload says
`"channel":"beta"`; flipping only GitHub's prerelease flag leaves that signature-valid value
unchanged, so stable clients reject it. Cut a stable release whose signed payload says
`"channel":"stable"`.

## Secrets

Never commit secrets. Code-signing identities and notary credentials live in the macOS keychain and
are never in the repo. The Ed25519 private key lives only at
`~/.shadowtype-keys/shadowtype-update-manifest-ed25519.pem` and in its offline encrypted backup; it
must never be copied into the repo. The app embeds only the matching public verification key, which
is not secret.
