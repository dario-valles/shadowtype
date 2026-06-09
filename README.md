# Shadowtype

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
![Platform: macOS 14+](https://img.shields.io/badge/platform-macOS%2014%2B-blue)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-required-black)

**System-wide, fully on-device ghost-text autocomplete for macOS.** Shadowtype predicts
your next words inline — as faint ghost text at the caret — in *every* Mac text field, powered
entirely by a local LLM running on Apple Silicon via Metal. Nothing leaves your machine. Press
**Tab** to accept a word (or the whole line); keep typing to dismiss. It behaves like
spell-check: invisible until useful, never in the way.

---

## Features

- **System-wide inline completions** — works in Mail, Notes, Slack, Safari, Word, terminals,
  Electron/WebKit editors, and the long tail of Mac text fields. Not locked to one app or browser.
- **Runs fully on-device** — completion inference is 100% local via [llama.cpp](https://github.com/ggml-org/llama.cpp)
  + Metal. Your keystrokes and prompts never become training data and never leave the Mac.
- **No telemetry, no account** — no analytics backend, no sign-in, no usage tracking. The app
  works offline; a one-click "Verify offline" confirms completion runs with Wi-Fi off.
- **Tab-to-accept ghost text** — word-by-word or whole-line acceptance with sub-frame overlay
  latency; continuing to type silently dismisses.
- **Rewrite & selection actions** — select text and trigger on-device rewrites (e.g. make
  formal, shorten) without leaving the app you're in.
- **Local OpenAI-compatible API + MCP bridge** — Shadowtype exposes a local HTTP API and ships an
  MCP bridge so editors and agents (Claude Code, Cursor, any MCP host) can use the on-device model.
- **Multi-model catalog** — a curated set of GGUF models with RAM-fit gating, plus bring-your-own
  GGUF import. Models are downloaded on demand and SHA-256-verified; none are bundled.
- **Context-aware** — optional local screen OCR, clipboard context, and learned typing style feed
  the model. Per-app / per-domain enable/disable. Password and secure fields are never read.

---

## Requirements

- macOS 14 (Sonoma) or newer
- Apple Silicon (M1 or later)
- For building from source: the Swift 6 toolchain (Xcode 16+ or the standalone toolchain), and
  `llama.cpp` + `ggml` installed via Homebrew:

  ```sh
  brew install llama.cpp
  ```

  Headers/libs are consumed through `pkg-config llama` plus an explicit `-I/opt/homebrew/include`
  for the separate `ggml` formula (see `Package.swift`).

---

## Install

**Download the app:**

- Grab the latest `.dmg` from [GitHub Releases](https://github.com/dario-valles/shadowtype/releases)
  and drag Shadowtype into Applications, **or**
- Install via Homebrew cask from the tap:

  ```sh
  brew install --cask dario-valles/homebrew-shadowtype/shadowtype
  ```

On first launch, Shadowtype guides you through the macOS permissions it needs (Accessibility +
Input Monitoring; Screen Recording is optional, only for the screen-context feature) and downloads
the default model.

---

## Build from source

```sh
swift build -c release          # → .build/release/Shadowtype
swift test                      # unit tests (model-gated tests auto-skip without a GGUF)
./scripts/make-app.sh           # assemble dist/Shadowtype.app (bundled, signed)
```

`swift build` produces a bare executable; `make-app.sh` wraps it in a real `.app` bundle with an
`Info.plist` and a code signature so TCC (Accessibility / Input Monitoring) grants persist across
rebuilds. Launch with `open dist/Shadowtype.app`, or run the binary directly to see logs:

```sh
dist/Shadowtype.app/Contents/MacOS/Shadowtype
```

---

## How updates work

The app auto-updates from **GitHub Releases**. It periodically checks for a newer build, and when
one is available it downloads and swaps the bundle in place. You can disable the auto-check.
Cutting releases is **maintainer-only** (notarization requires the maintainer's Apple Developer
ID) — see [RELEASING.md](RELEASING.md).

---

## Architecture

Shadowtype is a native Swift / AppKit menu-bar app (`LSUIElement`, no Dock icon). The hot path is:

```
keystroke (listen-only CGEventTap) → AX read of caret + prefix → llama.cpp + Metal inference
  → ghost overlay (NSPanel + CATextLayer) at the caret → Tab-to-accept injection
```

Everything is wired in `AppDelegate.swift`; the rest are single-responsibility units under
`Sources/Shadowtype/`.

---

## Alternatives

Shadowtype sits in the same space as **Cotypist**, **Cotabby**, and **Apple Intelligence**'s
inline writing tools. Its distinguishing stance is being fully local, free, and open source, with
no telemetry and no account.

---

## Contributing

Contributions are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Bug reports and feature
requests go through [GitHub Issues](https://github.com/dario-valles/shadowtype/issues).

## License

[MIT](LICENSE) © 2026 Darío Vallés.

Shadowtype bundles MIT/Apache-2.0 libraries (llama.cpp, ggml, libomp) in release builds and
downloads third-party models at runtime — see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
