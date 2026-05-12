{ writeShellApplication
, coreutils
, sway
, foot
, alacritty
, kitty
, wezterm
, scrgo
}:

let
  termCfg = import ./bench-term-config.nix { };
in
writeShellApplication {
  name = "bench-stream";

  runtimeInputs = [
    coreutils
    sway
    foot
    alacritty
    kitty
    wezterm
    scrgo
  ];

  text = ''
    unset LD_LIBRARY_PATH

    RUNS="''${BENCH_RUNS:-3}"
    DEADLINE_MS="''${BENCH_DEADLINE_MS:-30000}"

    ${termCfg.setup}

    # Build the payload: ~7 MB of mixed-length numbered lines. Varied
    # widths so the terminal exercises wrapping/scrolling code paths.
    PAYLOAD="$(mktemp -t bench-stream.XXXXXX.txt)"
    {
      seq 1 800000
      seq -f "line=%07.0f payload=lorem ipsum dolor sit amet consectetur" 1 60000
    } > "$PAYLOAD"

    SWAY_LOG="$(mktemp -t sway-bench-stream.XXXXXX.log)"
    CFG="$(mktemp -t sway-bench-stream.XXXXXX.cfg)"
    cat >"$CFG" <<'EOF'
    default_border none
    gaps inner 0
    gaps outer 0
    EOF

    export WLR_BACKENDS=wayland
    export WLR_WL_OUTPUTS=1
    export WLR_LIBINPUT_NO_DEVICES=1
    export WLR_RENDERER_ALLOW_SOFTWARE=1

    sway --config "$CFG" --unsupported-gpu --debug >"$SWAY_LOG" 2>&1 &
    SWAY_PID=$!
    cleanup() {
      kill "$SWAY_PID" 2>/dev/null || true
      wait "$SWAY_PID" 2>/dev/null || true
      rm -f "$PAYLOAD" "$CFG"
      ${termCfg.cleanup}
    }
    trap cleanup EXIT

    for _ in $(seq 1 100); do
      WD=$(grep -oE "Running compositor on wayland display '[^']+'" "$SWAY_LOG" \
           | sed -E "s/.*'([^']+)'/\1/" | head -n1 || true)
      if [ -n "$WD" ] && [ -S "''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$WD" ]; then
        export WAYLAND_DISPLAY="$WD"
        break
      fi
      sleep 0.05
    done

    if [ -z "''${WAYLAND_DISPLAY:-}" ]; then
      echo "sway socket never appeared (see $SWAY_LOG)" >&2
      tail -n 20 "$SWAY_LOG" >&2
      exit 1
    fi

    unset DISPLAY

    SCRGO_BIN="$(command -v scrgo)"
    BENCH_BIN="$(dirname "$SCRGO_BIN")/scrgo-bench-stream"

    export BENCH_CAT="${coreutils}/bin/cat"
    export BENCH_PAYLOAD="$PAYLOAD"
    export SCRGO_BIN
    export FOOT_BIN="${foot}/bin/foot"
    export ALACRITTY_BIN="${alacritty}/bin/alacritty"
    export KITTY_BIN="${kitty}/bin/kitty"
    export WEZTERM_BIN="${wezterm}/bin/wezterm"

    echo "=== stream-under-load bench (sway nested, $WAYLAND_DISPLAY) ==="
    echo "payload: $PAYLOAD ($(stat -c %s "$PAYLOAD") bytes)"
    echo "sway log: $SWAY_LOG"
    "$BENCH_BIN" "--runs=$RUNS" "--deadline-ms=$DEADLINE_MS"
  '';
}
