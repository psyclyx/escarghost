#!/usr/bin/env bash
# Benchmark terminal emulator startup times on Wayland.
#
# Usage: nix-shell -p foot kitty wezterm hyperfine --run ./bench-startup.sh

set -euo pipefail

MOLLUSK="$(nix-build --no-out-link)/bin/mollusk"
RUNS=20
WARMUP=3

echo "=== Terminal Startup Benchmark ==="
echo "Runs: $RUNS  Warmup: $WARMUP"
echo "mollusk: $MOLLUSK"
echo ""

hyperfine \
  --runs "$RUNS" \
  --warmup "$WARMUP" \
  --ignore-failure \
  --export-markdown /dev/stdout \
  --command-name mollusk   "$MOLLUSK -e /bin/true" \
  --command-name foot      "foot /bin/true" \
  --command-name alacritty "alacritty -e /bin/true" \
  --command-name kitty     "kitty -e /bin/true" \
  --command-name wezterm   "wezterm start -- /bin/true" \
  --command-name ghostty   "ghostty -e /bin/true"
