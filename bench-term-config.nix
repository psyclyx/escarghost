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
# Font family is pinned to "DejaVu Sans Mono" explicitly. "monospace"
# would route through fontconfig and pick up whatever the host system
# has set as the default mono — e.g. on a box with Berkeley Mono
# installed via home-manager, fc-match monospace returns Berkeley Mono,
# which is significantly narrower than DejaVu. Then scrgo renders at
# ~60 % the cell width of the other terminals (which on closer
# inspection turn out to bundle DejaVu internally rather than calling
# fontconfig). Pinning the family by name makes the comparison fair.
{ fontSize ? 11
, scrollbackLines ? 10000
, fontFamily ? "DejaVu Sans Mono"
}:
{
  setup = ''
    TERM_CFG_HOME="$(mktemp -d -t bench-cfg.XXXXXX)"

    # scrgo's config `font` field is a literal file path; the other
    # terminals' configs all take family names that fontconfig resolves.
    # Use fc-match here so scrgo and the rest end up rendering with the
    # exact same .ttf.
    SCRGO_FONT_PATH="$(fc-match -f "%{file}" "${fontFamily}")"

    mkdir -p "$TERM_CFG_HOME/foot"
    cat > "$TERM_CFG_HOME/foot/foot.ini" <<'CFG'
    [main]
    font=${fontFamily}:size=${toString fontSize}

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
    family = "${fontFamily}"

    [scrolling]
    history = ${toString scrollbackLines}

    [cursor.style]
    blinking = "Off"

    [bell]
    duration = 0
    CFG

    mkdir -p "$TERM_CFG_HOME/kitty"
    cat > "$TERM_CFG_HOME/kitty/kitty.conf" <<'CFG'
    font_family ${fontFamily}
    font_size ${toString fontSize}
    scrollback_lines ${toString scrollbackLines}
    cursor_blink_interval 0
    enable_audio_bell no
    visual_bell_duration 0
    CFG

    mkdir -p "$TERM_CFG_HOME/wezterm"
    cat > "$TERM_CFG_HOME/wezterm/wezterm.lua" <<'CFG'
    local wezterm = require 'wezterm'
    return {
      font = wezterm.font("${fontFamily}"),
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
    cat > "$TERM_CFG_HOME/scrgo/config.json" <<CFG
    {
      "font": "$SCRGO_FONT_PATH",
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
