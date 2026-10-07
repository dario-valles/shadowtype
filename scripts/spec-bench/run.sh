#!/usr/bin/env bash
# Opt-in benchmark: plain decode vs llama.cpp speculative decoding (draft model / MTP) on
# Shadowtype-shaped requests. See the header of spec-bench.cpp for the findings and usage.
#   scripts/spec-bench/run.sh -m target.gguf [-md draft.gguf] --spec-type draft-mtp ...
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LLAMA_TAG="$(sed -n 's/^LLAMA_TAG="\(.*\)"$/\1/p' "$REPO_ROOT/scripts/build-llama.sh")"
SRC="$REPO_ROOT/.build/spec-bench-llama-src"
BUILD="$REPO_ROOT/.build/spec-bench-build"

if [[ ! -d "$SRC/.git" ]]; then
  echo "==> cloning llama.cpp $LLAMA_TAG (with common/)" >&2
  git clone --quiet --depth 1 --branch "$LLAMA_TAG" https://github.com/ggml-org/llama.cpp "$SRC"
fi
if [[ "$(git -C "$SRC" describe --tags --exact-match 2>/dev/null)" != "$LLAMA_TAG" ]]; then
  echo "error: $SRC is not at the pinned $LLAMA_TAG; delete it to re-clone" >&2
  exit 1
fi

cmake -S "$REPO_ROOT/scripts/spec-bench" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release -DLLAMA_SRC="$SRC" >/dev/null
cmake --build "$BUILD" -j "$(sysctl -n hw.ncpu)" --target llama-spec-bench >/dev/null

: "${BENCH_TEXT:=$BUILD/bench-text.txt}"
if [[ "$BENCH_TEXT" == "$BUILD/bench-text.txt" ]]; then
  # ~4.1k Gemma tokens of prose the models have not memorised: enough for 5 windows of 1500.
  cat "$REPO_ROOT"/{README,CONTRIBUTING,RELEASING,SECURITY}.md > "$BENCH_TEXT"
fi
export BENCH_TEXT
"$BUILD/llama-spec-bench" -ngl 99 -ngld 99 -c 4096 -b 2048 -fa on "$@" 2>&1 | grep -E '^RESULT|diverge'
