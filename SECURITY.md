# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security vulnerabilities.

Instead, report privately via GitHub's
[private security advisory](https://github.com/dario-valles/shadowtype/security/advisories/new),
or email the maintainer. We'll acknowledge your report and work with you on a fix and coordinated
disclosure.

## Scope

Shadowtype is a **local-only macOS app**. Completion inference runs entirely on-device; there are no
servers that handle user data, no account, and no telemetry. The only outbound network traffic is:

- **Model downloads** from Hugging Face over HTTPS
- **Update checks** against GitHub Releases (carries no user content; can be disabled)

Because there is no backend processing user data, the relevant security surface is the app itself —
e.g. permission handling (Accessibility / Input Monitoring / optional Screen Recording), text
injection, the local API server, and update verification. Reports about any of these are welcome.

## Model integrity

Model downloads are staged and checked before being promoted into the model library. The curated
catalog distinguishes two integrity levels:

- **Release-pinned SHA-256:** the app embeds an independently release-audited digest and rejects any
  download that does not match it.
- **UNVERIFIED — no release-pinned SHA-256:** when Hugging Face supplies an LFS SHA-256 in the download
  response, the app checks it to detect transfer corruption. That value comes from the same upstream
  source as the file, so it does not protect against an upstream replacement. If no digest is supplied,
  the app can only validate that the file has GGUF magic; this is a format sanity check, not
  cryptographic verification.

The shipping default model is release-pinned. Other catalog entries remain explicitly unverified
until their exact GGUF files are independently audited and their SHA-256 values are pinned in a
release. User-specified Hugging Face imports likewise have no release-pinned trust anchor.
