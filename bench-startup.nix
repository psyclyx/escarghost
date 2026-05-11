{ writeShellApplication
, coreutils
, hyperfine
, weston
, foot
, alacritty
, kitty
, wezterm
, scrgo
}:

let
  trueBin = "${coreutils}/bin/true";
in

writeShellApplication {
  name = "bench-startup";

  runtimeInputs = [
    hyperfine
    weston
    foot
    alacritty
    kitty
    wezterm
    scrgo
  ];

  text = ''
    RUNS=20
    WARMUP=10
    NESTED_SOCKET="wayland-bench-$$"
    WESTON_LOG="$(mktemp -t weston-bench.XXXXXX.log)"

    weston \
      --backend=wayland \
      --socket="$NESTED_SOCKET" \
      --width=1920 --height=1080 \
      --no-config \
      --idle-time=0 \
      >"$WESTON_LOG" 2>&1 &
    WESTON_PID=$!

    cleanup() {
      if kill -0 "$WESTON_PID" 2>/dev/null; then
        kill "$WESTON_PID" 2>/dev/null || true
        wait "$WESTON_PID" 2>/dev/null || true
      fi
    }
    trap cleanup EXIT

    SOCKET_PATH="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$NESTED_SOCKET"
    for _ in $(seq 1 50); do
      [ -S "$SOCKET_PATH" ] && break
      sleep 0.1
    done
    if [ ! -S "$SOCKET_PATH" ]; then
      echo "weston socket never appeared at $SOCKET_PATH (see $WESTON_LOG)" >&2
      exit 1
    fi

    export WAYLAND_DISPLAY="$NESTED_SOCKET"
    unset DISPLAY

    echo "=== Terminal Startup Benchmark (nested weston) ==="
    echo "Runs: $RUNS  Warmup: $WARMUP"
    echo "nested WAYLAND_DISPLAY: $NESTED_SOCKET"
    echo "weston log: $WESTON_LOG"
    echo ""

    hyperfine \
      --runs "$RUNS" \
      --warmup "$WARMUP" \
      --ignore-failure \
      --shell=none \
      --command-name scrgo     "scrgo -e ${trueBin}" \
      --command-name foot      "foot ${trueBin}" \
      --command-name alacritty "alacritty -e ${trueBin}" \
      --command-name kitty     "kitty -e ${trueBin}" \
      --command-name wezterm   "wezterm start -- ${trueBin}"
  '';
}
