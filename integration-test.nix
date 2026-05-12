{ writeShellApplication
, coreutils
, sway
, scrgo
}:

writeShellApplication {
  name = "integration-test";

  runtimeInputs = [
    coreutils
    sway
    scrgo
  ];

  text = ''
    # Match the bench wrapper: drop the dev LD_LIBRARY_PATH so the
    # harness reflects what the installed scrgo loads.
    unset LD_LIBRARY_PATH

    SWAY_LOG="$(mktemp -t sway-it.XXXXXX.log)"
    CFG="$(mktemp -t sway-it.XXXXXX.cfg)"

    cat >"$CFG" <<'EOF'
    # Minimal config. The nested wayland backend creates an output named
    # WL-1 (or WAYLAND-1). Either way we just want scrgo focused, not
    # fullscreen — fullscreen lets sway take the direct-scan-out path
    # which can bypass the renderer and confuse screencopy.
    default_border none
    gaps inner 0
    gaps outer 0
    for_window [app_id="scrgo"] focus
    EOF

    # Nest sway inside the host wayland session, like bench-startup does
    # with weston. dmabufs round-trip through the host compositor, so
    # scrgo's GPU renderer actually works (the headless backend, by
    # contrast, has to import dmabufs in-process which NVIDIA refuses).
    export WLR_BACKENDS=wayland
    export WLR_WL_OUTPUTS=1
    export WLR_LIBINPUT_NO_DEVICES=1
    export WLR_RENDERER_ALLOW_SOFTWARE=1

    # NVIDIA: sway refuses by default. We're a self-contained test so
    # we don't care about sway's policy here.
    sway --config "$CFG" --unsupported-gpu --debug >"$SWAY_LOG" 2>&1 &
    SWAY_PID=$!

    cleanup() {
      if kill -0 "$SWAY_PID" 2>/dev/null; then
        kill "$SWAY_PID" 2>/dev/null || true
        wait "$SWAY_PID" 2>/dev/null || true
      fi
      rm -f "$CFG"
    }
    trap cleanup EXIT

    # Wait for sway's wayland socket. wlroots picks the first free
    # wayland-<n> name and logs it. Pull it out so we connect to *that*
    # display, not the user's session.
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
    TEST_BIN="$(dirname "$SCRGO_BIN")/scrgo-integration-test"
    if [ ! -x "$TEST_BIN" ]; then
      echo "scrgo-integration-test not found next to scrgo at $TEST_BIN" >&2
      exit 1
    fi

    echo "=== scrgo integration test (sway headless, $WAYLAND_DISPLAY) ==="
    echo "sway log: $SWAY_LOG"
    # scrgo uses execv which requires absolute paths, and NixOS has no
    # /bin/cat. Pass the resolved binary through to the harness.
    export SCRGO_IT_CAT="${coreutils}/bin/cat"
    "$TEST_BIN" "$SCRGO_BIN"
  '';
}
