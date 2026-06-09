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
#   7. write latest.json (the update manifest) per the release/update contract
#   8. publish tag v<VERSION> to GitHub Releases (zip + dmg + latest.json) via the `gh` CLI;
#      a beta channel release is a GitHub --prerelease, stable is a normal release
#   9. (optional) bump the Homebrew cask in the tap to point at the new build
#
# The app compares CFBundleVersion (BUILD) numerically, so BUILD MUST increase every release.
# The updater fetches the GitHub release, reads the `latest.json` asset, and if its build is newer
# downloads the zip, verifies sha256, and swaps the bundle in place. No Worker, no Ed25519 manifest.
#
# Required env:
#   VERSION, BUILD                  release version/build (must match what ships; BUILD must be newer)
#   NOTARY_PROFILE                  `xcrun notarytool store-credentials` keychain profile name
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
APP_DIR="$REPO_ROOT/dist/$APP_NAME.app"
CHANNEL="${CHANNEL:-stable}"
NOTES="${NOTES:-Bug fixes and improvements.}"
MIN_BUILD="${MIN_BUILD:-0}"
GITHUB_REPO="${GITHUB_REPO:-dario-valles/shadowtype}"

require() { if [[ -z "${!1:-}" ]]; then echo "error: \$$1 is required (see header)." >&2; exit 1; fi; }
require VERSION; require BUILD; require NOTARY_PROFILE

command -v gh >/dev/null || { echo "error: gh CLI not found — install with: brew install gh" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "error: gh not authenticated — run: gh auth login" >&2; exit 1; }

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

echo "==> [1/9] build + bundle Developer ID app (VERSION=$VERSION BUILD=$BUILD)"
RELEASE=1 VERSION="$VERSION" BUILD="$BUILD" "$REPO_ROOT/scripts/make-app.sh"

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
# Build the whole manifest with json.dumps (every field escaped, build/minBuild as ints) so a stray
# quote/backslash in VERSION/URL/NOTES can never produce invalid JSON that breaks the in-app updater.
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
}, indent=2))' >"$MANIFEST_FILE"
cat "$MANIFEST_FILE" | sed 's/^/    /'

echo "==> [8/9] publish GitHub Release $TAG → $GITHUB_REPO"
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
