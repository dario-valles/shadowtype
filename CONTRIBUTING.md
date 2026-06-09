# Contributing to Shadowtype

Thanks for your interest in Shadowtype. Contributions — bug fixes, features, docs, and tests — are
welcome. This is a free, open-source, fully-local macOS app; the goal is a clean, friendly project.

## Prerequisites

- macOS 14+ on Apple Silicon
- Swift 6 toolchain (Xcode 16+ or the standalone toolchain)
- `llama.cpp` + `ggml` via Homebrew: `brew install llama.cpp`

## Build & test

```sh
swift build           # build the app
swift test            # run the unit test suite
```

Model-gated tests auto-skip when no GGUF is cached, so the suite is green on a clean checkout. To
exercise the model-backed paths, fetch a model first via the app's onboarding or Settings → Models. For a runnable
`.app` bundle (needed to exercise TCC-gated behavior live):

```sh
./scripts/make-app.sh && open dist/Shadowtype.app
```

You can also open the package directly in Xcode with `open Package.swift` (no `.xcodeproj`).

## Code style

Match the existing code. The codebase is native Swift 6 / AppKit with single-responsibility files
under `Sources/Shadowtype/`. Keep new files in the same style as their neighbors, prefer small
pure/testable units, and add hermetic tests (temp files / injected dependencies — no real Keychain,
network, TCC, or GGUF) alongside any new logic. Don't add comments or docstrings to code you didn't
change.

## Opening a pull request

1. **Fork** the repo and create a topic **branch** off `main`.
2. Make your change. **Keep the diff focused** — one logical change per PR.
3. **Run `swift test`** and make sure it passes.
4. Open a PR against `main`. Describe *what* changed and *why*, and how you tested it. The PR
   template will prompt you for this.

## Releases are maintainer-only

**Do not add release CI or release automation in a PR.** Cutting a release requires Apple Developer
ID **notarization**, which depends on the maintainer's Apple Developer ID credentials —
contributors don't have these and can't notarize a build. Releasing is done locally by the
maintainer via `bin/menu` (see [RELEASING.md](RELEASING.md)). PRs that add `.github/workflows` for
releasing, or otherwise try to publish builds, will be declined.

## Never commit secrets

Signing and notarization credentials live in the **macOS keychain**, not in the repo. Never commit
Apple ID app-specific passwords, notarytool profiles, signing identities, private keys, or any
other secret. Build-generated artifacts (the bundled `.app`, downloaded `.gguf` models, generated
icons/OG images) are gitignored — keep it that way.

## Reporting security issues

See [SECURITY.md](SECURITY.md). Please don't open public issues for vulnerabilities.
