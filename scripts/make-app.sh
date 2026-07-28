#!/usr/bin/env bash
# make-app.sh — assemble a .app bundle around the SwiftPM-built Shadowtype executable.
#
# Why this exists: `swift build` produces a bare Mach-O executable, not a bundle. TCC
# (Accessibility / Input Monitoring) keys permission grants to a STABLE code identity —
# a bare binary at a build path is re-prompted on every rebuild and can't reliably hold a
# grant. Wrapping it in a real .app + an ad-hoc code signature gives TCC a durable identity
# (the bundle id + designated requirement), so a grant survives rebuilds as long as the
# bundle id and signing identity stay the same.
#
# Usage:
#   ./scripts/make-app.sh                # build release, then bundle
#   SKIP_BUILD=1 ./scripts/make-app.sh   # bundle the already-built binary
#
# Output: <repo>/dist/Shadowtype.app
set -euo pipefail

APP_NAME="Shadowtype"
BUNDLE_ID="com.shadowtype.app"
EXPECTED_TEAM_ID="A9ZQD8SP48"
EXPECTED_DESIGNATED_REQUIREMENT='designated => identifier "com.shadowtype.app" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = A9ZQD8SP48'
EXPECTED_REQUIREMENT='identifier "com.shadowtype.app" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = A9ZQD8SP48'
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"   # `CONFIG=debug` builds a debug bundle
BIN_PATH="$REPO_ROOT/.build/$CONFIG/$APP_NAME"
APP_DIR="$REPO_ROOT/dist/$APP_NAME.app"

# Version is the SINGLE source of truth that the signed update manifest (release.sh) must agree with:
# the auto-updater compares CFBundleVersion (BUILD) numerically. Resolution order (highest wins):
#   explicit env  >  release/state.env (the release-menu counter)  >  hardcoded fallback.
# Capture any explicit env BEFORE sourcing state.env so a passed VERSION=/BUILD= isn't clobbered.
_ENV_VERSION="${VERSION:-}"; _ENV_BUILD="${BUILD:-}"
if [[ -f "$REPO_ROOT/release/state.env" ]]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/release/state.env"
fi
VERSION="${_ENV_VERSION:-${VERSION:-0.1.0}}"   # CFBundleShortVersionString (marketing)
BUILD="${_ENV_BUILD:-${BUILD:-1}}"             # CFBundleVersion (monotonic — the updater's ordering key)

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "==> swift build -c $CONFIG"
  ( cd "$REPO_ROOT" && swift build -c "$CONFIG" )
  # M2: MCP bridge binary. `swift build` without --product only builds the default app target;
  # the MCPBridge executable target needs an explicit --product to actually link a binary.
  echo "==> swift build --product MCPBridge -c $CONFIG"
  ( cd "$REPO_ROOT" && swift build --product MCPBridge -c "$CONFIG" )
fi

if [[ ! -x "$BIN_PATH" ]]; then
  echo "error: built executable not found at $BIN_PATH (run 'swift build -c $CONFIG' first)" >&2
  exit 1
fi

echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
cp "$REPO_ROOT/THIRD-PARTY-NOTICES.md" \
  "$APP_DIR/Contents/Resources/THIRD-PARTY-NOTICES.md"

# llama.cpp and all ggml backends are linked statically, including the embedded Metal
# library. The copied executable must therefore have only Apple system dependencies.
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"
EXE="$APP_DIR/Contents/MacOS/$APP_NAME"

audit_system_dependencies() {
  local binary="$1" otool_output non_system_deps
  otool_output="$(otool -L "$binary")"
  printf '%s\n' "$otool_output"
  non_system_deps="$(
    printf '%s\n' "$otool_output" |
      awk 'NR > 1 && $1 !~ "^/System/Library/" && $1 !~ "^/usr/lib/" { print $1 }'
  )"
  if [[ -n "$non_system_deps" ]]; then
    echo "error: non-system dynamic dependencies in $binary:" >&2
    printf '  %s\n' "$non_system_deps" >&2
    return 1
  fi
}

verify_main_executable() {
  local binary="$1" architectures build_version platform minos
  echo "==> verifying static native dependency closure"
  audit_system_dependencies "$binary"

  architectures="$(lipo -archs "$binary")"
  [[ "$architectures" == "arm64" ]] || {
    echo "error: expected arm64-only executable; got: $architectures" >&2
    return 1
  }

  echo "==> verifying macOS deployment target"
  build_version="$(xcrun vtool -show-build "$binary")"
  printf '%s\n' "$build_version"
  platform="$(printf '%s\n' "$build_version" | awk '$1 == "platform" { print $2; exit }')"
  minos="$(printf '%s\n' "$build_version" | awk '$1 == "minos" { print $2; exit }')"
  [[ "$platform" == "MACOS" && "$minos" == "14.0" ]] || {
    echo "error: expected LC_BUILD_VERSION MACOS minos 14.0; got platform=$platform minos=$minos" >&2
    return 1
  }
}

verify_main_executable "$EXE"

# M2: MCP bridge — copy the stdio JSON-RPC ↔ HTTP shim into Resources/. MCP hosts (Claude
# Code, Cursor) spawn this fresh per session via the path advertised in the Settings panel.
# It is a tiny ~30 KB binary with no llama.cpp linkage.
MCP_BIN="$REPO_ROOT/.build/$CONFIG/MCPBridge"
# SwiftPM may place the binary at the arch-specific subpath instead of the symlinked debug/ dir.
if [[ ! -x "$MCP_BIN" ]]; then
  ALT="$REPO_ROOT/.build/arm64-apple-macosx/$CONFIG/MCPBridge"
  if [[ -x "$ALT" ]]; then MCP_BIN="$ALT"; fi
fi
if [[ -x "$MCP_BIN" ]]; then
  cp "$MCP_BIN" "$APP_DIR/Contents/Resources/shadowtype-mcp"
  chmod +x "$APP_DIR/Contents/Resources/shadowtype-mcp"
  echo "==> bundled MCP bridge: $APP_DIR/Contents/Resources/shadowtype-mcp"
else
  echo "==> WARNING: $MCP_BIN missing — MCP bridge will not be available in this build (run 'swift build --target MCPBridge -c $CONFIG' first)"
fi

# App icon. Resources/AppIcon.icns is the committed source of truth (regenerate from
# web/assets/logo.svg via scripts make-icon if the artwork changes). CFBundleIconFile below
# points Finder/Dock at it.
ICON_SRC="$REPO_ROOT/Resources/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
  cp "$ICON_SRC" "$APP_DIR/Contents/Resources/AppIcon.icns"
else
  echo "==> WARNING: $ICON_SRC missing — bundle will use the generic app icon."
fi

# Info.plist — LSUIElement=true makes it an accessory app (menu-bar only, no Dock icon,
# FR-MB-1 / main.swift sets .accessory). The bundle id is the TCC identity anchor.
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Codesign. Two modes:
#
#   • RELEASE=1 → Developer ID Application + Hardened Runtime + entitlements. This is what notarization
#     (release.sh) requires and what lets a freshly DOWNLOADED build clear Gatekeeper, and what lets the
#     auto-updater swap the bundle in place without re-tripping Gatekeeper. Default identity is the
#     "Developer ID Application" cert in the keychain; override with ST_SIGN_IDENTITY.
#
#   • default (dev) → a STABLE self-signed identity ("Shadowtype Dev") so the designated requirement is
#     identifier+certificate based and a TCC grant (Accessibility / Input Monitoring) PERSISTS across
#     rebuilds. Ad-hoc ("-s -") has no stable identity (its DR is the per-build cdhash), so macOS
#     re-prompts every rebuild. Create the identity once with scripts/make-signing-cert.sh.
ENTITLEMENTS="$REPO_ROOT/Resources/Shadowtype.entitlements"
if [[ "${RELEASE:-0}" == "1" ]]; then
  SIGN_ID="${ST_SIGN_IDENTITY:-Developer ID Application}"
  if ! security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "error: RELEASE=1 needs a '$SIGN_ID' code-signing identity in the keychain (Developer ID)." >&2
    echo "       Install your Developer ID Application cert, or set ST_SIGN_IDENTITY." >&2
    exit 1
  fi

  echo "==> codesign (RELEASE) with Developer ID + hardened runtime: $SIGN_ID"
  # Bundled MCP helper in Resources/ is a Mach-O but NOT nested code that the app's
  # signature seals as executable — without an explicit sign it keeps its fake cctools
  # signature and notarization rejects it (no Developer ID, no timestamp, no hardened runtime).
  MCP_BUNDLED="$APP_DIR/Contents/Resources/shadowtype-mcp"
  if [[ -f "$MCP_BUNDLED" ]]; then
    # Same dead-rpath strip as the main executable (the MCP helper only has the stale Xcode
    # toolchain rpath; its Swift runtime resolves from the OS /usr/lib/swift). Before signing.
    while IFS= read -r rp; do
      install_name_tool -delete_rpath "$rp" "$MCP_BUNDLED" 2>/dev/null || true
    done < <(otool -l "$MCP_BUNDLED" | awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}' | grep -E '^/Applications/Xcode' || true)
    audit_system_dependencies "$MCP_BUNDLED"
    codesign -s "$SIGN_ID" --force --timestamp --options runtime "$MCP_BUNDLED"
  fi
  codesign -s "$SIGN_ID" --force --timestamp \
    --options runtime --entitlements "$ENTITLEMENTS" "$APP_DIR"

  # Positive proof for library validation and TCC continuity: every bundled Mach-O
  # must be sealed by the committed release team before this bundle can leave the script.
  while IFS= read -r -d '' bundled_file; do
    file "$bundled_file" | grep -q 'Mach-O' || continue
    codesign --verify --strict "$bundled_file"
    bundled_team="$(codesign -dv --verbose=4 "$bundled_file" 2>&1 |
      sed -n 's/^TeamIdentifier=//p' | head -1)"
    [[ "$bundled_team" == "$EXPECTED_TEAM_ID" ]] || {
      echo "error: $bundled_file signed by TeamIdentifier '$bundled_team', expected '$EXPECTED_TEAM_ID'." >&2
      exit 1
    }
  done < <(find "$APP_DIR/Contents" -type f -print0)

  actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_DIR/Contents/Info.plist")"
  actual_identifier="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1 |
    sed -n 's/^Identifier=//p' | head -1)"
  actual_team="$(codesign -dv --verbose=4 "$APP_DIR" 2>&1 |
    sed -n 's/^TeamIdentifier=//p' | head -1)"
  actual_requirement="$(codesign -dr - "$APP_DIR" 2>&1 | grep '^designated =>')"
  [[ "$actual_bundle_id" == "$BUNDLE_ID" && "$actual_identifier" == "$BUNDLE_ID" ]] || {
    echo "error: release bundle identifier is not pinned to '$BUNDLE_ID'." >&2; exit 1
  }
  [[ "$actual_team" == "$EXPECTED_TEAM_ID" ]] || {
    echo "error: release TeamIdentifier '$actual_team' is not '$EXPECTED_TEAM_ID'." >&2; exit 1
  }
  [[ "$actual_requirement" == "$EXPECTED_DESIGNATED_REQUIREMENT" ]] || {
    echo "error: release designated requirement differs from the committed requirement." >&2
    echo "       got: $actual_requirement" >&2
    exit 1
  }
  codesign --verify --deep --strict -R="$EXPECTED_REQUIREMENT" "$APP_DIR"
else
  SIGN_ID="${ST_SIGN_IDENTITY:-Shadowtype Dev}"
  if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
    echo "==> codesign with stable identity: $SIGN_ID"
    codesign -s "$SIGN_ID" --force --deep "$APP_DIR"
  else
    echo "==> WARNING: stable identity '$SIGN_ID' not found — falling back to ad-hoc."
    echo "    TCC grants will NOT persist across rebuilds. Run scripts/make-signing-cert.sh once to fix."
    codesign -s - --force --deep "$APP_DIR"
  fi
fi
codesign -dv "$APP_DIR" 2>&1 | sed 's/^/    /' || true

echo "==> done: $APP_DIR"
echo "    Launch: open \"$APP_DIR\"   (or run the binary directly for logs:)"
echo "            \"$APP_DIR/Contents/MacOS/$APP_NAME\""
