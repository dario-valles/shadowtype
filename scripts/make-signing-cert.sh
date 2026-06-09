#!/usr/bin/env bash
# make-signing-cert.sh — create a STABLE self-signed code-signing identity ("Shadowtype Dev")
# in the login keychain, once. Why: ad-hoc signing (`codesign -s -`) gives the app a designated
# requirement based on its cdhash, which changes every rebuild — so macOS treats each build as a
# new app, drops the Accessibility / Input Monitoring grant, and re-prompts on every launch.
# Signing with a fixed self-signed cert makes the requirement identifier+certificate based, so a
# TCC grant persists across rebuilds. This is local-dev only (NOT Developer ID / notarization).
#
# Idempotent: re-running detects the existing identity and exits.
set -euo pipefail

IDENTITY="Shadowtype Dev"
LK="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "identity '$IDENTITY' already present — nothing to do."
  exit 0
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> generating self-signed code-signing cert '$IDENTITY'"
openssl req -x509 -newkey rsa:2048 -keyout "$tmp/gw.key" -out "$tmp/gw.crt" -days 3650 -nodes \
  -subj "/CN=$IDENTITY" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "keyUsage=critical,digitalSignature" 2>/dev/null

# Legacy PBE + SHA1 MAC so macOS Security can import the PKCS#12 (modern OpenSSL defaults fail).
openssl pkcs12 -export -inkey "$tmp/gw.key" -in "$tmp/gw.crt" -out "$tmp/gw.p12" \
  -passout pass:ghost -macalg sha1 -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES 2>/dev/null

echo "==> importing into login keychain"
security import "$tmp/gw.p12" -k "$LK" -P "ghost" -A

echo "==> trusting cert for code signing (login keychain, no sudo)"
security add-trusted-cert -r trustRoot -p codeSign -k "$LK" "$tmp/gw.crt"

echo "==> done. Valid codesigning identities:"
security find-identity -v -p codesigning | grep -i ghost || { echo "FAILED to create a valid identity" >&2; exit 1; }
