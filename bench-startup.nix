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
  # Renders one short line through the PTY then exits immediately. scrgo's
  # drain phase guarantees the line is committed to the compositor before
  # the process exits; other terminals are assumed to do the same. With a
  # no-op like `true` you measure spawn + teardown only — with echo READY
  # the number reflects spawn-through-first-frame.
  echoBin = "${coreutils}/bin/echo";
  # Pin everyone to monospace:size=11 so we're not measuring font-init
  # cost at five different sizes. Foot's default is size=8 (~10.7 px-em),
  # alacritty/kitty/wezterm/scrgo all default to 11+ pt — without a
  # shared config they spawn with visibly different cell sizes.
  termCfg = import ./bench-term-config.nix { };
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
    # shell.nix sets LD_LIBRARY_PATH for `zig build` dev runs; it points
    # at the unslimmed harfbuzz (and friends) which overrides the
    # nix-built binary's RUNPATH. Drop it so the bench reflects what an
    # end user running the installed binary actually loads.
    unset LD_LIBRARY_PATH

    RUNS=20
    WARMUP=10
    NESTED_SOCKET="wayland-bench-$$"
    WESTON_LOG="$(mktemp -t weston-bench.XXXXXX.log)"

    ${termCfg.setup}

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
      ${termCfg.cleanup}
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
      --command-name scrgo     "scrgo -e ${echoBin} READY" \
      --command-name foot      "foot ${echoBin} READY" \
      --command-name alacritty "alacritty -e ${echoBin} READY" \
      --command-name kitty     "kitty -e ${echoBin} READY" \
      --command-name wezterm   "wezterm start -- ${echoBin} READY"
  '';
}
