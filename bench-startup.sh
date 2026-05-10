#!/usr/bin/env bash
# Benchmark terminal emulator startup times on Wayland.
#
# Usage: nix-shell --run ./bench-startup.sh

set -euo pipefail

SCRGO="$(nix-build --no-out-link)/bin/scrgo"
RUNS=20
WARMUP=3

if ! command -v hyperfine >/dev/null 2>&1; then
  echo "hyperfine not found; run this from the project nix-shell" >&2
  exit 1
fi

declare -a HYPERFINE_ARGS=(
  --runs "$RUNS"
  --warmup "$WARMUP"
  --ignore-failure
  --export-markdown /dev/stdout
  --command-name scrgo   "$SCRGO -e /bin/true"
)

add_bench() {
  local bin="$1"
  local name="$2"
  local cmd="$3"
  if command -v "$bin" >/dev/null 2>&1; then
    HYPERFINE_ARGS+=(--command-name "$name" "$cmd")
  fi
}

add_bench foot foot "foot /bin/true"
add_bench alacritty alacritty "alacritty -e /bin/true"
add_bench kitty kitty "kitty -e /bin/true"
add_bench wezterm wezterm "wezterm start -- /bin/true"
add_bench ghostty ghostty "ghostty -e /bin/true"

echo "=== Terminal Startup Benchmark ==="
echo "Runs: $RUNS  Warmup: $WARMUP"
echo "scrgo: $SCRGO"
echo ""

hyperfine "${HYPERFINE_ARGS[@]}"
