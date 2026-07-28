#!/usr/bin/env bash
# release.sh — cut a notarized Shadowtype release and publish it to GitHub Releases for the in-app updater.
#
# Pipeline:
#   1. build + bundle a Developer-ID + hardened-runtime app   (RELEASE=1 make-app.sh)
#   2. build a DMG (drag-to-Applications) from the signed app
#   3. notarize the DMG (xcrun notarytool --wait) — notarizes the .app inside it too
#   4. staple the ticket to BOTH the DMG and the .app (the ticket must travel inside the archive)
#   5. zip the STAPLED .app (ditto --keepParent, the format the updater unzips)
#   6. SHA-256 the final zip
#   7. write + Ed25519-sign latest.json per the release/update contract
#   8. publish tag v<VERSION> to GitHub Releases (zip + dmg + latest.json) via the `gh` CLI;
#      a beta channel release is a GitHub --prerelease, stable is a normal release
#   9. (optional) bump the Homebrew cask in the tap to point at the new build
#
# The app compares CFBundleVersion (BUILD) numerically, so BUILD MUST increase every release.
# The updater fetches the GitHub release, reads the `latest.json` asset, and if its build is newer
# verifies the Ed25519 manifest before decoding it, downloads the zip, verifies sha256, and swaps.
#
# Required env:
#   VERSION, BUILD                  release version/build (must match what ships; BUILD must be newer)
#   NOTARY_PROFILE                  `xcrun notarytool store-credentials` keychain profile name
#   ST_UPDATE_SIGNING_KEY           out-of-repo PKCS#8 Ed25519 private-key PEM
# Optional env:
#   CHANNEL=stable|beta             default stable (beta => GitHub --prerelease)
#   NOTES                           release notes string (default: "Bug fixes and improvements.")
#   MIN_BUILD                       builds below this are forced to update (default: 0)
#   ST_SIGN_IDENTITY                Developer ID identity override (passed through to make-app.sh)
#   GITHUB_REPO                     publish target (default: dario-valles/shadowtype)
#   TAP_REPO, TAP_DIR               Homebrew tap repo + local clone; if set, the cask is bumped
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Shadowtype"
EXPECTED_TEAM_ID="A9ZQD8SP48"
EXPECTED_BUNDLE_ID="com.shadowtype.app"
EXPECTED_GITHUB_REPO="dario-valles/shadowtype"
EXPECTED_UPDATE_PUBLIC_KEY="7qJ/CyY2wJRRpD6QUtHaBz8Pajg35mZzctBogY3JTVo="
EXPECTED_DESIGNATED_REQUIREMENT='designated => identifier "com.shadowtype.app" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = A9ZQD8SP48'
EXPECTED_REQUIREMENT='identifier "com.shadowtype.app" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = A9ZQD8SP48'
APP_DIR="$REPO_ROOT/dist/$APP_NAME.app"
CHANNEL="${CHANNEL:-stable}"
NOTES="${NOTES:-Bug fixes and improvements.}"
MIN_BUILD="${MIN_BUILD:-0}"
GITHUB_REPO="${GITHUB_REPO:-dario-valles/shadowtype}"

require() { if [[ -z "${!1:-}" ]]; then echo "error: \$$1 is required (see header)." >&2; exit 1; fi; }
require VERSION; require BUILD; require NOTARY_PROFILE; require ST_UPDATE_SIGNING_KEY

[[ "$BUILD" =~ ^[1-9][0-9]*$ ]] || {
  echo "error: BUILD must be a positive base-10 integer." >&2; exit 1
}
(( BUILD <= 2147483647 )) || {
  echo "error: BUILD exceeds the updater's supported range." >&2; exit 1
}
[[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z.-]{0,63}$ && "$VERSION" != *..* ]] || {
  echo "error: VERSION contains characters the updater will reject." >&2; exit 1
}
if [[ ! "$MIN_BUILD" =~ ^(0|[1-9][0-9]*)$ ]] || (( MIN_BUILD > BUILD )); then
  echo "error: MIN_BUILD must be an integer in 0...BUILD." >&2; exit 1
fi
[[ "$CHANNEL" == "stable" || "$CHANNEL" == "beta" ]] || {
  echo "error: CHANNEL must be stable or beta." >&2; exit 1
}
[[ "$GITHUB_REPO" == "$EXPECTED_GITHUB_REPO" ]] || {
  echo "error: GITHUB_REPO must remain pinned to $EXPECTED_GITHUB_REPO." >&2; exit 1
}
[[ -f "$ST_UPDATE_SIGNING_KEY" ]] || {
  echo "error: update signing key not found: $ST_UPDATE_SIGNING_KEY" >&2; exit 1
}
key_mode="$(/usr/bin/stat -f '%Lp' "$ST_UPDATE_SIGNING_KEY")"
[[ "$key_mode" =~ ^[0-7]00$ ]] || {
  echo "error: ST_UPDATE_SIGNING_KEY must not be readable by group/others (chmod 600)." >&2
  exit 1
}

# One-time key setup (never commit or sync the private key):
#   umask 077
#   openssl genpkey -algorithm ED25519 -out /secure/offline/shadowtype-update-ed25519.pem
#   openssl pkey -in /secure/offline/shadowtype-update-ed25519.pem -pubout -outform DER |
#     tail -c 32 | openssl base64 -A
# Back up the PEM in offline encrypted storage. The derived public value must equal
# EXPECTED_UPDATE_PUBLIC_KEY above and UpdateManager.releaseManifestPublicKey.
derived_update_public_key="$(
  openssl pkey -in "$ST_UPDATE_SIGNING_KEY" -pubout -outform DER |
    tail -c 32 | openssl base64 -A
)"
[[ "$derived_update_public_key" == "$EXPECTED_UPDATE_PUBLIC_KEY" ]] || {
  echo "error: ST_UPDATE_SIGNING_KEY does not match the public key embedded in Shadowtype." >&2
  exit 1
}

command -v gh >/dev/null || { echo "error: gh CLI not found — install with: brew install gh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh not authenticated — run: gh auth login" >&2; exit 1; }

# GitHub release assets are the persisted publication ledger across machines/channels. Fail closed if
# it cannot be read, and reject reusing or decreasing any previously published build.
if ! published_assets="$(gh api --paginate "repos/$GITHUB_REPO/releases?per_page=100" \
  --jq '.[] | select(.draft == false) | .assets[].name')"; then
  echo "error: could not read the published build high-water from GitHub." >&2
  exit 1
fi
published_high_water="$(
  printf '%s\n' "$published_assets" |
    sed -nE 's/^Shadowtype-.*-([0-9]+)\.zip$/\1/p' |
    sort -n | tail -1
)"
published_high_water="${published_high_water:-0}"
(( BUILD > published_high_water )) || {
  echo "error: BUILD=$BUILD must be greater than published high-water $published_high_water." >&2
  exit 1
}

# Two artifacts per release, both wrapping the SAME notarized+stapled .app:
#   • ZIP → the auto-updater feed (in-place extract + bundle swap; dmg can't be extracted
#     programmatically). Versioned + immutable: cutting a new build at the same marketing VERSION can't
#     overwrite a prior updater artifact, and latest.json points the updater at this exact URL.
#   • DMG → the website first-install (drag-to-Applications; the expected Mac UX). STABLE-NAMED so the
#     site can link a permanent direct download — /releases/latest/download/Shadowtype.dmg always
#     resolves to the newest STABLE release's DMG.
ZIP_ARTIFACT="$APP_NAME-$VERSION-$BUILD.zip"
DMG_ARTIFACT="$APP_NAME.dmg"
ZIP="$REPO_ROOT/dist/$ZIP_ARTIFACT"
DMG="$REPO_ROOT/dist/$DMG_ARTIFACT"
MANIFEST_FILE="$REPO_ROOT/dist/latest.json"
TAG="v$VERSION"
SIGN_ID="${ST_SIGN_IDENTITY:-Developer ID Application}"

assert_release_identity() {
  local plist_id identifier team requirement plist_build
  plist_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")"
  plist_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist")"
  identifier="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1 | sed -n 's/^Identifier=//p' | head -1)"
  team="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1 | sed -n 's/^TeamIdentifier=//p' | head -1)"
  requirement="$(codesign -dr - "$APP_DIR" 2>&1 | grep '^designated =>')"
  [[ "$plist_id" == "$EXPECTED_BUNDLE_ID" && "$identifier" == "$EXPECTED_BUNDLE_ID" ]] || {
    echo "error: bundle/code identifier is not '$EXPECTED_BUNDLE_ID'." >&2; return 1
  }
  [[ "$team" == "$EXPECTED_TEAM_ID" ]] || {
    echo "error: TeamIdentifier '$team' is not '$EXPECTED_TEAM_ID'." >&2; return 1
  }
  [[ "$plist_build" == "$BUILD" ]] || {
    echo "error: staged CFBundleVersion '$plist_build' does not equal BUILD=$BUILD." >&2; return 1
  }
  [[ "$requirement" == "$EXPECTED_DESIGNATED_REQUIREMENT" ]] || {
    echo "error: designated requirement differs from the committed release identity." >&2; return 1
  }
  codesign --verify --deep --strict -R="$EXPECTED_REQUIREMENT" "$APP_DIR"
}

echo "==> [1/9] build + bundle Developer ID app (VERSION=$VERSION BUILD=$BUILD)"
RELEASE=1 VERSION="$VERSION" BUILD="$BUILD" "$REPO_ROOT/scripts/make-app.sh"
assert_release_identity

echo "==> [2/9] build DMG (drag-to-Applications) from the signed app"
DMGSTAGE="$(mktemp -d)"
cp -R "$APP_DIR" "$DMGSTAGE/"
ln -s /Applications "$DMGSTAGE/Applications"     # drag-target in the mounted volume
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMGSTAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm -rf "$DMGSTAGE"
codesign -s "$SIGN_ID" --timestamp "$DMG"

echo "==> [3/9] notarize the DMG (xcrun notarytool --wait) — notarizes the .app inside too"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> [4/9] staple the ticket to BOTH the DMG and the .app"
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP_DIR"   # app is notarized via the DMG submission; its cdhash now has a ticket
assert_release_identity

echo "==> [5/9] zip the stapled app (the auto-updater feed)"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP"

echo "==> [6/9] sha256 of the zip (updater feed) + the dmg (Homebrew cask)"
SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
DMG_SHA256="$(shasum -a 256 "$DMG" | awk '{print $1}')"
echo "    $SHA256  $ZIP_ARTIFACT"
echo "    $DMG_SHA256  $DMG_ARTIFACT"

URL="https://github.com/$GITHUB_REPO/releases/download/$TAG/$ZIP_ARTIFACT"

echo "==> [7/9] write latest.json (update manifest)"
# Canonical compact UTF-8 payload bytes are signed directly. The top-level flat fields are copied
# from those exact signed values solely so the shipped 0.2.5 build 74 (which decodes a flat
# UpdateManifest and ignores unknown keys) can reach the first signed-manifest release. They may be
# dropped only once no supported install predates the signed-manifest build. New clients authenticate
# and decode only payload; the top-level compatibility fields are never part of their trust path.
MANIFEST_PAYLOAD="$(mktemp)"
MANIFEST_SIGNATURE="$(mktemp)"
trap 'rm -f "$MANIFEST_PAYLOAD" "$MANIFEST_SIGNATURE"' EXIT
VERSION="$VERSION" BUILD="$BUILD" CHANNEL="$CHANNEL" URL="$URL" SHA256="$SHA256" \
  MIN_BUILD="$MIN_BUILD" NOTES="$NOTES" python3 -c '
import json, os
print(json.dumps({
    "version":  os.environ["VERSION"],
    "build":    int(os.environ["BUILD"]),
    "minBuild": int(os.environ["MIN_BUILD"]),
    "sha256":   os.environ["SHA256"],
    "url":      os.environ["URL"],
    "channel":  os.environ["CHANNEL"],
    "notes":    os.environ["NOTES"],
}, sort_keys=True, separators=(",", ":"), ensure_ascii=False), end="")' >"$MANIFEST_PAYLOAD"
openssl pkeyutl -sign -rawin -inkey "$ST_UPDATE_SIGNING_KEY" \
  -in "$MANIFEST_PAYLOAD" -out "$MANIFEST_SIGNATURE"
PAYLOAD_B64="$(openssl base64 -A -in "$MANIFEST_PAYLOAD")" \
SIGNATURE_B64="$(openssl base64 -A -in "$MANIFEST_SIGNATURE")" \
  python3 -c '
import base64, json, os
payload_b64 = os.environ["PAYLOAD_B64"]
signed_fields = json.loads(base64.b64decode(payload_b64, validate=True))
manifest = dict(signed_fields)
manifest.update({
    "payload": payload_b64,
    "signature": os.environ["SIGNATURE_B64"],
})
print(json.dumps(manifest, indent=2, sort_keys=True, ensure_ascii=False))' >"$MANIFEST_FILE"

# Fail closed before publication if the build-74 compatibility view ever diverges from the signed
# payload. This assertion intentionally decodes the bytes embedded in the finished latest.json.
MANIFEST_FILE="$MANIFEST_FILE" python3 -c '
import base64, json, os
legacy_keys = ("version", "build", "channel", "url", "sha256", "minBuild", "notes")
with open(os.environ["MANIFEST_FILE"], encoding="utf-8") as source:
    manifest = json.load(source)
signed_fields = json.loads(base64.b64decode(manifest["payload"], validate=True))
flat_fields = {key: manifest[key] for key in legacy_keys}
if set(signed_fields) != set(legacy_keys) or flat_fields != signed_fields:
    raise SystemExit("error: flat latest.json fields differ from the signed payload")'
sed 's/^/    /' "$MANIFEST_FILE"

echo "==> [8/9] publish GitHub Release $TAG → $GITHUB_REPO"
assert_release_identity
TITLE="$APP_NAME $VERSION (build $BUILD)"
BODY="$NOTES

sha256: $SHA256"
PRE_FLAG=(); [[ "$CHANNEL" == "beta" ]] && PRE_FLAG=(--prerelease)
if gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
  # Tag already exists (e.g. a new build at the same VERSION): clobber the assets + refresh metadata.
  gh release upload "$TAG" "$ZIP" "$DMG" "$MANIFEST_FILE" --repo "$GITHUB_REPO" --clobber
  gh release edit   "$TAG" --repo "$GITHUB_REPO" --title "$TITLE" --notes "$BODY" "${PRE_FLAG[@]+"${PRE_FLAG[@]}"}"
  echo "    updated existing release $TAG"
else
  gh release create "$TAG" "$ZIP" "$DMG" "$MANIFEST_FILE" --repo "$GITHUB_REPO" \
    --title "$TITLE" --notes "$BODY" "${PRE_FLAG[@]+"${PRE_FLAG[@]}"}"
  echo "    created release $TAG"
fi

echo "==> [9/9] Homebrew cask"
if [[ -n "${TAP_REPO:-}" && -n "${TAP_DIR:-}" ]]; then
  CASK="$TAP_DIR/Casks/shadowtype.rb"
  if [[ ! -d "$TAP_DIR/.git" ]]; then
    echo "    cloning tap → $TAP_DIR"
    gh repo clone "$TAP_REPO" "$TAP_DIR" >/dev/null 2>&1 || { echo "    WARNING: tap clone failed: $TAP_REPO" >&2; CASK=""; }
  fi
  if [[ -n "$CASK" ]]; then
    git -C "$TAP_DIR" pull --quiet --ff-only 2>/dev/null || true
    if [[ -f "$CASK" ]]; then
      # The cask serves the DMG (the human download) from the GitHub Release.
      sed -i '' -E "s/^([[:space:]]*version )\"[^\"]*\"/\1\"$VERSION\"/" "$CASK"
      sed -i '' -E "s/^([[:space:]]*sha256 )\"[^\"]*\"/\1\"$DMG_SHA256\"/"    "$CASK"
      if git -C "$TAP_DIR" diff --quiet -- Casks/shadowtype.rb; then
        echo "    cask already at $VERSION — no change"
      else
        git -C "$TAP_DIR" add Casks/shadowtype.rb
        git -C "$TAP_DIR" commit --quiet -m "shadowtype $VERSION (build $BUILD)" \
          -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
        git -C "$TAP_DIR" push --quiet && echo "    cask bumped to $VERSION + pushed" \
          || echo "    WARNING: cask push failed: $TAP_REPO" >&2
      fi
    else
      echo "    WARNING: cask not found: $CASK" >&2
    fi
  fi
else
  echo "    TAP_REPO/TAP_DIR not set — skipping Homebrew cask bump"
fi

echo "==> done."
echo "    release   : https://github.com/$GITHUB_REPO/releases/tag/$TAG  (channel: $CHANNEL)"
echo "    updater    : the in-app updater reads latest.json from this release and self-updates."
echo "    Verify the manifest build ($BUILD) is newer than the running build, then test a self-update + a fresh DMG install."
