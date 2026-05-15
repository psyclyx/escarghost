# Shared shell snippets that set up per-terminal config files pinning
# every comparable setting that affects the benches: font family + size
# (visual size + raster work), scrollback length (memory footprint and
# stream-bench eviction behavior), cursor blink (background re-renders
# that pollute input-latency capture), and audible/visual bell.
#
# Defaults vary considerably across terminals (foot: 1000 scrollback,
# kitty: 2000, wezterm: 3500, alacritty/scrgo: 10000), which makes a
# raw comparison apples-to-oranges. Pin everyone to one value so the
# benches measure the implementation, not the configured cap.
#
# Font family is hardcoded to "monospace" — fontconfig resolves it
# consistently for scrgo/foot/alacritty/kitty; wezterm falls back to
# its own default (font_size still applies).
{ fontSize ? 11
, scrollbackLines ? 10000
}:
{
  setup = ''
    TERM_CFG_HOME="$(mktemp -d -t bench-cfg.XXXXXX)"

    mkdir -p "$TERM_CFG_HOME/foot"
    cat > "$TERM_CFG_HOME/foot/foot.ini" <<'CFG'
    [main]
    font=monospace:size=${toString fontSize}

    [scrollback]
    lines=${toString scrollbackLines}

    [cursor]
    blink=no

    [bell]
    urgent=no
    notify=no
    CFG

    mkdir -p "$TERM_CFG_HOME/alacritty"
    cat > "$TERM_CFG_HOME/alacritty/alacritty.toml" <<'CFG'
    [font]
    size = ${toString fontSize}.0

    [font.normal]
    family = "monospace"

    [scrolling]
    history = ${toString scrollbackLines}

    [cursor.style]
    blinking = "Off"

    [bell]
    duration = 0
    CFG

    mkdir -p "$TERM_CFG_HOME/kitty"
    cat > "$TERM_CFG_HOME/kitty/kitty.conf" <<'CFG'
    font_family monospace
    font_size ${toString fontSize}
    scrollback_lines ${toString scrollbackLines}
    cursor_blink_interval 0
    enable_audio_bell no
    visual_bell_duration 0
    CFG

    mkdir -p "$TERM_CFG_HOME/wezterm"
    cat > "$TERM_CFG_HOME/wezterm/wezterm.lua" <<'CFG'
    return {
      font_size = ${toString fontSize}.0,
      scrollback_lines = ${toString scrollbackLines},
      cursor_blink_rate = 0,
      audible_bell = "Disabled",
      visual_bell = {
        fade_in_duration_ms = 0,
        fade_out_duration_ms = 0,
        target = "BackgroundColor",
      },
    }
    CFG

    mkdir -p "$TERM_CFG_HOME/scrgo"
    cat > "$TERM_CFG_HOME/scrgo/config.json" <<'CFG'
    {
      "font_size": ${toString fontSize}.0,
      "max_scrollback": ${toString scrollbackLines}
    }
    CFG

    export XDG_CONFIG_HOME="$TERM_CFG_HOME"
  '';

  cleanup = ''
    rm -rf "$TERM_CFG_HOME"
  '';
}
