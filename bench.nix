# Unified terminal-comparison bench. One driver, one nested compositor
# instance, one set of shared per-terminal configs. Drives the
# scrgo-bench-suite binary built by build.zig.
#
# Usage:
#   nix-build -A bench && ./result/bin/bench [--scenarios=...] [--terminals=...]
#
# See `bench --help` for the full flag list. The wrapper supplies
# WAYLAND_DISPLAY, the bench payload, and the per-terminal binary paths
# via env vars; the driver handles compositor coordination, settling,
# per-scenario instrumentation, and reporting.
{ writeShellApplication
, coreutils
, util-linux
, procps
, fontconfig # fc-match for the bench-term-config setup
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
  name = "bench";

  runtimeInputs = [
    coreutils
    util-linux # setsid
    procps # pkill
    fontconfig # fc-match
    sway
    foot
    alacritty
    kitty
    wezterm
    scrgo
  ];

  text = ''
    # shell.nix sets LD_LIBRARY_PATH for `zig build` dev runs; it points
    # at the unslimmed harfbuzz (and friends) which overrides the nix-
    # built binary's RUNPATH. Drop it so the bench reflects what an end
    # user running the installed binary actually loads.
    unset LD_LIBRARY_PATH

    # Sandbox the bench's cache dir. Without this, scrgo's persistent
    # font-path cache (~/.cache/scrgo/font-path) shadows the bench's
    # fontconfig setup and scrgo ends up rendering with whatever
    # "monospace" resolved to LAST time the user ran scrgo outside the
    # bench — e.g. a condensed proprietary font from home-manager. The
    # other terminals get the bench env's fontconfig "monospace"
    # (DejaVu on stock NixOS), so they look ~30 % wider per cell.
    BENCH_CACHE="$(mktemp -d -t bench-cache.XXXXXX)"
    export XDG_CACHE_HOME="$BENCH_CACHE"

    ${termCfg.setup}

    # Shared payload: ~9 MB of mixed-length numbered lines. The stream
    # and memory scenarios both consume this. ~7 MB of numeric lines
    # plus 60k longer lines so we exercise wrap/scroll paths too.
    PAYLOAD="$(mktemp -t bench-payload.XXXXXX.txt)"
    {
      seq 1 800000
      seq -f "line=%07.0f payload=lorem ipsum dolor sit amet consectetur" 1 60000
    } > "$PAYLOAD"

    SWAY_LOG="$(mktemp -t bench-sway.XXXXXX.log)"
    CFG="$(mktemp -t bench-sway.XXXXXX.cfg)"
    cat >"$CFG" <<'EOF'
    default_border none
    gaps inner 0
    gaps outer 0
    EOF

    export WLR_BACKENDS=wayland
    export WLR_WL_OUTPUTS=1
    export WLR_LIBINPUT_NO_DEVICES=1
    export WLR_RENDERER_ALLOW_SOFTWARE=1

    # setsid so sway + its swaybg helper share a process group we can
    # signal as a unit. Killing the group is what catches swaybg
    # (sway usually doesn't reap it cleanly on SIGTERM).
    setsid sway --config "$CFG" --unsupported-gpu --debug >"$SWAY_LOG" 2>&1 &
    SWAY_PID=$!
    # shellcheck disable=SC2329  # invoked indirectly via trap.
    cleanup() {
      # Negative pid = kill the process group, catches swaybg too.
      kill -TERM -- "-$SWAY_PID" 2>/dev/null || true
      wait "$SWAY_PID" 2>/dev/null || true
      # Belt + suspenders: a process group leader respawning into a
      # new pgid would escape -TERM. pkill -P catches direct
      # descendants by ppid as a fallback.
      pkill -P "$SWAY_PID" 2>/dev/null || true
      rm -f "$PAYLOAD" "$CFG"
      rm -rf "$BENCH_CACHE"
      ${termCfg.cleanup}
    }
    # EXIT covers normal exit + most signals. INT/TERM explicit so a
    # Ctrl-C reliably triggers cleanup before the shell tears down.
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    # Wait for the nested sway socket to appear.
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
    BENCH_BIN="$(dirname "$SCRGO_BIN")/scrgo-bench-suite"

    export BENCH_CAT="${coreutils}/bin/cat"
    export BENCH_ECHO="${coreutils}/bin/echo"
    export BENCH_SH="/bin/sh"
    export BENCH_PAYLOAD="$PAYLOAD"
    export SCRGO_BIN
    export FOOT_BIN="${foot}/bin/foot"
    export ALACRITTY_BIN="${alacritty}/bin/alacritty"
    export KITTY_BIN="${kitty}/bin/kitty"
    export WEZTERM_BIN="${wezterm}/bin/wezterm"

    echo "=== bench (sway nested, $WAYLAND_DISPLAY) ==="
    echo "payload: $PAYLOAD ($(stat -c %s "$PAYLOAD") bytes)"
    echo "sway log: $SWAY_LOG"

    # NOT `exec` — exec replaces this shell and drops the EXIT trap,
    # which means sway leaks if the bench is interrupted or crashes.
    # Run the bench as a child so cleanup() always fires on the way out.
    rc=0
    "$BENCH_BIN" "$@" || rc=$?
    exit "$rc"
  '';
}
