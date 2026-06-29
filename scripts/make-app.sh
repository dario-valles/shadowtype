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

# Copy the executable into the bundle. Note: the binary keeps the rpaths baked in by
# Package.swift (/opt/homebrew/opt/llama.cpp/lib and /opt/homebrew/lib), so libllama /
# libggml resolve at runtime as long as the Homebrew formulae stay installed. For a
# distributable bundle these dylibs would need to be copied into Contents/Frameworks and
# the rpath rewritten with install_name_tool — out of scope for a local dev bundle (M0-M2).
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/$APP_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$APP_NAME"

# M2: MCP bridge — copy the stdio JSON-RPC ↔ HTTP shim into Resources/. MCP hosts (Claude
# Code, Cursor) spawn this fresh per session via the path advertised in the Settings panel.
# It is a tiny ~30 KB binary, no llama.cpp linkage, so it doesn't need a Frameworks rpath dance.
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

  # RELEASE bundles must be RELOCATABLE: the dev build links libllama/libggml/libggml-base/libomp by
  # ABSOLUTE /opt/homebrew paths (see otool -L), so a notarized .app launched on a Mac WITHOUT Homebrew
  # crashes in dyld. Copy the whole non-system dylib load-closure into Contents/Frameworks and rewrite
  # every load command to @rpath, then sign inside-out. (The disable-library-validation entitlement
  # only permits loading mismatched-team dylibs; it does not relocate them — this step does.)
  EXE="$APP_DIR/Contents/MacOS/$APP_NAME"
  FW="$APP_DIR/Contents/Frameworks"
  mkdir -p "$FW"
  echo "==> bundling dylibs into Contents/Frameworks (relocatable, no Homebrew dependency)"

  # Search dirs for @rpath-referenced libs whose absolute home we don't already know.
  LIB_DIRS=(/opt/homebrew/opt/ggml/lib /opt/homebrew/opt/llama.cpp/lib /opt/homebrew/opt/libomp/lib /opt/homebrew/lib)
  # Fixed-point copy: seed from the executable, then follow each copied lib's own non-system deps.
  nonsys_deps() { otool -L "$1" | awk 'NR>1{print $1}' | grep -E '^/opt/homebrew|^@rpath' || true; }
  queue=(); copied=" "
  while IFS= read -r d; do queue+=("$d"); done < <(nonsys_deps "$EXE")
  while (( ${#queue[@]} )); do
    dep="${queue[0]}"; queue=("${queue[@]:1}")
    [[ -n "$dep" ]] || continue
    base="$(basename "$dep")"
    [[ "$copied" == *" $base "* ]] && continue
    src=""
    if [[ "$dep" == /opt/homebrew/* && -f "$dep" ]]; then
      src="$dep"
    else
      for d in "${LIB_DIRS[@]}"; do [[ -f "$d/$base" ]] && { src="$d/$base"; break; }; done
    fi
    if [[ -z "$src" ]]; then echo "error: can't locate dylib '$base' to bundle." >&2; exit 1; fi
    cp -L "$src" "$FW/$base"; chmod u+w "$FW/$base"
    copied+="$base "
    while IFS= read -r d2; do queue+=("$d2"); done < <(nonsys_deps "$FW/$base")
  done

  # ggml ≥0.13 loads its COMPUTE BACKENDS (Metal / CPU variants / BLAS) as separate plugins at
  # RUNTIME — they are NOT in the otool load-closure above, so the loop never copied them. libggml
  # finds them via a path baked in at BUILD time (the dev's Homebrew Cellar libexec); on any machine
  # without that exact path it logs "no backends are loaded" and the model load fails. Copy the whole
  # libexec/*.so into Frameworks so the app is self-contained; InferenceEngine loads them at launch via
  # ggml_backend_load_all_from_path(Frameworks). MUST be the SAME ggml version as the bundled libggml-base — mixing a
  # 0.13 core with newer backend plugins produces silent numerical garbage (repeating-token salad).
  GGML_LIBEXEC="$(brew --prefix ggml 2>/dev/null)/libexec"
  if [[ -d "$GGML_LIBEXEC" ]]; then
    shopt -s nullglob
    for so in "$GGML_LIBEXEC"/*.so; do cp -L "$so" "$FW/$(basename "$so")"; chmod u+w "$FW/$(basename "$so")"; done
    shopt -u nullglob
  else
    echo "error: ggml libexec not found at '$GGML_LIBEXEC' — backend plugins would be missing." >&2; exit 1
  fi

  # Repoint the executable's absolute deps to @rpath/<base> and add the Frameworks run-path.
  while IFS= read -r dep; do
    [[ "$dep" == /opt/homebrew/* ]] && install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$EXE"
  done < <(otool -L "$EXE" | awk 'NR>1{print $1}' | grep -E '^/opt/homebrew' || true)
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE" 2>/dev/null || true
  # Strip the dev-box rpaths SwiftPM baked in (/opt/homebrew/* from Package.swift, /Applications/Xcode.app/*
  # swift toolchain). They don't just fail to exist on a clean Mac — they're searched BEFORE
  # @executable_path/../Frameworks, so a user who happens to have a DIFFERENT Homebrew ggml installed
  # would have dyld load THAT over our bundled libs → version mismatch → garbage output (the same class of
  # bug as a stale Cellar symlink). After this the only non-system search paths are the bundle + @loader_path.
  while IFS= read -r rp; do
    install_name_tool -delete_rpath "$rp" "$EXE" 2>/dev/null || true
  done < <(otool -l "$EXE" | awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}' | grep -E '^/opt/homebrew|^/Applications/Xcode' || true)

  # Set each bundled lib's id to @rpath/<base>, repoint its absolute deps, and let it find siblings.
  # Also retarget LC_BUILD_VERSION → macOS 14.0: Homebrew builds ggml/llama.cpp/libomp with
  # minos = the BUILD host's OS (e.g. 26.0 on Tahoe), but the app binary targets 14.0. dyld refuses
  # to load a dylib whose minos is newer than the running OS, so without this the bundle launch-crashes
  # on every macOS < the build host (silently fine only when tester and builder share an OS). vtool
  # rewrites only the version field — safe here because ggml/llama use Metal/Accelerate/pthreads, all
  # available since macOS 11. (The proper fix is building llama.cpp with CMAKE_OSX_DEPLOYMENT_TARGET=14.0;
  # this keeps the Homebrew-bottle path shippable.) Runs before the inside-out codesign so the re-sign
  # seals the patched header. Order matters: vtool also invalidates the signature.
  # Includes the runtime backend plugins (*.so) copied above, which carry the same minos + absolute
  # dep problems as the linked dylibs and so need the same id/dep/minos rewrite before signing.
  shopt -s nullglob
  for f in "$FW"/*.dylib "$FW"/*.so; do
    b="$(basename "$f")"
    install_name_tool -id "@rpath/$b" "$f"
    while IFS= read -r dep; do
      [[ "$dep" == /opt/homebrew/* ]] && install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f"
    done < <(otool -L "$f" | awk 'NR>1{print $1}' | grep -E '^/opt/homebrew' || true)
    install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
    xcrun vtool -set-build-version macos 14.0 14.0 -replace -output "$f" "$f"
  done
  shopt -u nullglob

  echo "==> codesign (RELEASE) with Developer ID + hardened runtime: $SIGN_ID"
  # Sign INSIDE-OUT: each bundled dylib first (install_name_tool invalidated their signatures), then the
  # app (which signs the main executable with entitlements). No --deep — we sign the nested code ourselves.
  shopt -s nullglob
  for f in "$FW"/*.dylib "$FW"/*.so; do
    codesign -s "$SIGN_ID" --force --timestamp --options runtime "$f"
  done
  shopt -u nullglob
  # Bundled MCP helper in Resources/ is a Mach-O but NOT nested code that the app's
  # signature seals as executable — without an explicit sign it keeps its fake cctools
  # signature and notarization rejects it (no Developer ID, no timestamp, no hardened runtime).
  MCP_BUNDLED="$APP_DIR/Contents/Resources/shadowtype-mcp"
  if [[ -f "$MCP_BUNDLED" ]]; then
    # Same dead-rpath strip as the main executable (the MCP helper only has the stale Xcode
    # toolchain rpath; its Swift runtime resolves from the OS /usr/lib/swift). Before signing.
    while IFS= read -r rp; do
      install_name_tool -delete_rpath "$rp" "$MCP_BUNDLED" 2>/dev/null || true
    done < <(otool -l "$MCP_BUNDLED" | awk '/LC_RPATH/{f=1} f&&/ path /{print $2; f=0}' | grep -E '^/opt/homebrew|^/Applications/Xcode' || true)
    codesign -s "$SIGN_ID" --force --timestamp --options runtime "$MCP_BUNDLED"
  fi
  codesign -s "$SIGN_ID" --force --timestamp \
    --options runtime --entitlements "$ENTITLEMENTS" "$APP_DIR"
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
