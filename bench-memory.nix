{ writeShellApplication
, coreutils
, time
, sway
, foot
, alacritty
, kitty
, wezterm
, scrgo
}:

writeShellApplication {
  name = "bench-memory";

  runtimeInputs = [
    coreutils
    time
    sway
    foot
    alacritty
    kitty
    wezterm
    scrgo
  ];

  text = ''
    unset LD_LIBRARY_PATH

    RUNS="''${BENCH_RUNS:-5}"

    # Payload: ~7 MB of mixed-length lines. Each terminal cats this
    # into its scrollback, sleeps briefly so MaxRSS captures the
    # post-consumption working set (not just spawn cost), then exits.
    PAYLOAD="$(mktemp -t bench-memory.XXXXXX.txt)"
    {
      seq 1 800000
      seq -f "line=%07.0f payload=lorem ipsum dolor sit amet consectetur" 1 60000
    } > "$PAYLOAD"

    SWAY_LOG="$(mktemp -t sway-bench-mem.XXXXXX.log)"
    CFG="$(mktemp -t sway-bench-mem.XXXXXX.cfg)"
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

    SCRIPT="cat $PAYLOAD; sleep 0.3"

    # Per-terminal max-rss-via-time. /usr/bin/time format "%M" =
    # maximum resident set size in KiB.
    run_term() {
      label="$1"
      shift
      samples=""
      for _ in $(seq 1 "$RUNS"); do
        rss=$(command time -f "%M" "$@" 2>&1 >/dev/null | tail -n1 || echo 0)
        # tail-1 may pick up unrelated terminal warnings; only keep
        # if it's a pure integer.
        case "$rss" in
          '''|*[!0-9]*) ;;
          *) samples="$samples $rss" ;;
        esac
      done
      # shellcheck disable=SC2086
      n=$(echo $samples | wc -w)
      if [ "$n" -eq 0 ]; then
        printf "%-10s  no samples\n" "$label"
        return
      fi
      # shellcheck disable=SC2086
      median=$(echo $samples | tr ' ' '\n' | sort -n | awk -v n="$n" 'NR==int((n+1)/2)')
      # shellcheck disable=SC2086
      max=$(echo $samples | tr ' ' '\n' | sort -n | tail -n1)
      # shellcheck disable=SC2086
      min=$(echo $samples | tr ' ' '\n' | sort -n | head -n1)
      printf "%-10s  n=%d  median=%-7s  min=%-7s  max=%-7s  (KiB)\n" \
        "$label" "$n" "$median" "$min" "$max"
    }

    echo "=== memory bench (max RSS after ~7 MB scrollback, $RUNS runs each) ==="
    echo "payload: $PAYLOAD ($(stat -c %s "$PAYLOAD") bytes)"
    echo "sway log: $SWAY_LOG"
    echo ""

    run_term "scrgo"     scrgo     -e sh -c "$SCRIPT"
    run_term "foot"      foot         sh -c "$SCRIPT"
    run_term "alacritty" alacritty -e sh -c "$SCRIPT"
    run_term "kitty"     kitty     -e sh -c "$SCRIPT"
    run_term "wezterm"   wezterm   start --always-new-process --class bench-wezterm -- sh -c "$SCRIPT"
  '';
}
