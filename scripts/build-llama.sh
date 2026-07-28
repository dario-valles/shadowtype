#!/usr/bin/env bash
set -euo pipefail

LLAMA_REPOSITORY="https://github.com/ggml-org/llama.cpp.git"
LLAMA_TAG="b10156"
LLAMA_COMMIT="91f8c9c5fb038c086e13e9cd823c29b33b07ba54"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="$REPO_ROOT/vendor/llama"
SOURCE_DIR="$REPO_ROOT/.build/llama-src"
BUILD_DIR="$REPO_ROOT/.build/llama-build"
STAGE_DIR="$REPO_ROOT/.build/llama-stage"
BUILD_INFO_FILE=".shadowtype-build-info"
PIN_REF="refs/shadowtype/$LLAMA_TAG"
FORCE_REBUILD=0

usage() {
  echo "Usage: $0 [--force]"
  echo "  --force, -f  rebuild even when vendor/llama already matches the pin"
}

while (( $# > 0 )); do
  case "$1" in
    --force|-f) FORCE_REBUILD=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

CMAKE_FLAGS=(
  "-DCMAKE_OSX_DEPLOYMENT_TARGET=14.0"
  "-DCMAKE_OSX_ARCHITECTURES=arm64"
  "-DCMAKE_BUILD_TYPE=Release"
  "-DBUILD_SHARED_LIBS=OFF"
  "-DGGML_BACKEND_DL=OFF"
  "-DGGML_METAL=ON"
  "-DGGML_METAL_EMBED_LIBRARY=ON"
  "-DGGML_BLAS=ON"
  "-DGGML_ACCELERATE=ON"
  "-DGGML_OPENMP=OFF"
  "-DGGML_NATIVE=OFF"
  "-DGGML_CCACHE=OFF"
  "-DLLAMA_BUILD_TESTS=OFF"
  "-DLLAMA_BUILD_EXAMPLES=OFF"
  "-DLLAMA_BUILD_SERVER=OFF"
  "-DLLAMA_BUILD_TOOLS=OFF"
  "-DLLAMA_BUILD_APP=OFF"
  "-DLLAMA_BUILD_COMMON=OFF"
)

EXPECTED_BUILD_INFO="$(
  printf '%s\n' \
    "repository=$LLAMA_REPOSITORY" \
    "tag=$LLAMA_TAG" \
    "commit=$LLAMA_COMMIT" \
    "${CMAKE_FLAGS[@]}"
)"

REQUIRED_HEADERS=(
  llama.h
  ggml.h
  ggml-backend.h
)

REQUIRED_ARCHIVES=(
  libllama.a
  libggml.a
  libggml-cpu.a
  libggml-blas.a
  libggml-metal.a
  libggml-base.a
)

validate_install() {
  local root="$1" header archive architectures unexpected_native

  for header in "${REQUIRED_HEADERS[@]}"; do
    [[ -f "$root/include/$header" ]] || {
      echo "error: missing installed header: $root/include/$header" >&2
      return 1
    }
  done

  for archive in "${REQUIRED_ARCHIVES[@]}"; do
    [[ -f "$root/lib/$archive" ]] || {
      echo "error: missing installed archive: $root/lib/$archive" >&2
      return 1
    }
    architectures="$(lipo -archs "$root/lib/$archive")"
    [[ "$architectures" == "arm64" ]] || {
      echo "error: $archive must contain only arm64; got: $architectures" >&2
      return 1
    }
  done

  unexpected_native="$(
    find "$root" -type f \( -name '*.dylib' -o -name '*.so' \) -print -quit
  )"
  [[ -z "$unexpected_native" ]] || {
    echo "error: static install unexpectedly contains: $unexpected_native" >&2
    return 1
  }
}

install_is_current() {
  [[ -f "$PREFIX/$BUILD_INFO_FILE" ]] || return 1
  [[ "$(cat "$PREFIX/$BUILD_INFO_FILE")" == "$EXPECTED_BUILD_INFO" ]] || return 1
  validate_install "$PREFIX"
}

if (( FORCE_REBUILD == 0 )) && install_is_current; then
  echo "==> llama.cpp $LLAMA_TAG ($LLAMA_COMMIT) already built at $PREFIX"
  exit 0
fi

for tool in git cmake xcrun lipo; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: required build tool not found: $tool" >&2
    exit 1
  }
done

mkdir -p "$REPO_ROOT/.build"
if [[ ! -e "$SOURCE_DIR" ]]; then
  echo "==> cloning llama.cpp"
  git clone --filter=blob:none --no-checkout "$LLAMA_REPOSITORY" "$SOURCE_DIR"
elif [[ ! -d "$SOURCE_DIR/.git" ]]; then
  echo "error: expected a git checkout at $SOURCE_DIR" >&2
  exit 1
fi

echo "==> fetching $LLAMA_TAG"
git -C "$SOURCE_DIR" fetch --force --no-tags origin \
  "refs/tags/$LLAMA_TAG:$PIN_REF"
RESOLVED_COMMIT="$(git -C "$SOURCE_DIR" rev-parse --verify "$PIN_REF^{commit}")"
if [[ "$RESOLVED_COMMIT" != "$LLAMA_COMMIT" ]]; then
  echo "error: $LLAMA_TAG resolved to $RESOLVED_COMMIT, expected $LLAMA_COMMIT" >&2
  exit 1
fi

git -C "$SOURCE_DIR" checkout --detach "$LLAMA_COMMIT"
git -C "$SOURCE_DIR" reset --hard "$LLAMA_COMMIT"
git -C "$SOURCE_DIR" clean -fdx

rm -rf "$BUILD_DIR" "$STAGE_DIR"
mkdir -p "$BUILD_DIR" "$STAGE_DIR"

echo "==> configuring llama.cpp $LLAMA_TAG for macOS 14 arm64"
cmake -S "$SOURCE_DIR" -B "$BUILD_DIR" \
  "-DCMAKE_INSTALL_PREFIX=$STAGE_DIR" \
  "${CMAKE_FLAGS[@]}"

BUILD_JOBS="${BUILD_JOBS:-$(sysctl -n hw.logicalcpu)}"
echo "==> building llama.cpp ($BUILD_JOBS jobs)"
cmake --build "$BUILD_DIR" --config Release --parallel "$BUILD_JOBS"

echo "==> installing llama.cpp to staging prefix"
cmake --install "$BUILD_DIR" --config Release
validate_install "$STAGE_DIR"
printf '%s\n' "$EXPECTED_BUILD_INFO" > "$STAGE_DIR/$BUILD_INFO_FILE"

mkdir -p "$(dirname "$PREFIX")"
rm -rf "$PREFIX"
mv "$STAGE_DIR" "$PREFIX"

echo "==> installed llama.cpp $LLAMA_TAG ($LLAMA_COMMIT) at $PREFIX"
