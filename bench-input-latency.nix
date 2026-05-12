{ writeShellApplication
, coreutils
, sway
, foot
, alacritty
, kitty
, wezterm
, scrgo
}:

writeShellApplication {
  name = "bench-input-latency";

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

    SAMPLES="''${BENCH_SAMPLES:-30}"
    SWAY_LOG="$(mktemp -t sway-bench.XXXXXX.log)"
    CFG="$(mktemp -t sway-bench.XXXXXX.cfg)"

    # Nest inside the host wayland session — same model as
    # bench-startup.nix and integration-test.nix. Dmabuf round-trips
    # through the host compositor so each terminal's GPU path works
    # the way it would on a real desktop.
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
      rm -f "$CFG"
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
    BENCH_BIN="$(dirname "$SCRGO_BIN")/scrgo-bench-input-latency"

    export BENCH_CAT="${coreutils}/bin/cat"
    export SCRGO_BIN
    export FOOT_BIN="${foot}/bin/foot"
    export ALACRITTY_BIN="${alacritty}/bin/alacritty"
    export KITTY_BIN="${kitty}/bin/kitty"
    export WEZTERM_BIN="${wezterm}/bin/wezterm"

    echo "=== input-latency comparison (sway nested, $WAYLAND_DISPLAY) ==="
    echo "sway log: $SWAY_LOG"
    "$BENCH_BIN" "--samples=$SAMPLES"
  '';
}
