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

- **Model downloads** (HTTPS, content-addressed, SHA-256-verified)
- **Update checks** against GitHub Releases (carries no user content; can be disabled)

Because there is no backend processing user data, the relevant security surface is the app itself —
e.g. permission handling (Accessibility / Input Monitoring / optional Screen Recording), text
injection, the local API server, and update verification. Reports about any of these are welcome.
