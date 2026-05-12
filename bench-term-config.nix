# Shared shell snippets that set up per-terminal config files pinning
# the same font + size so each terminal's cell grid is roughly
# comparable. Sourced by bench-input-latency, bench-stream, and
# bench-memory.
#
# Font family is hardcoded to "monospace" — fontconfig resolves that
# consistently for scrgo/foot/alacritty/kitty, and wezterm falls back
# to its own default (font_size still applies).
{ fontSize ? 11 }:
{
  setup = ''
    TERM_CFG_HOME="$(mktemp -d -t bench-cfg.XXXXXX)"

    mkdir -p "$TERM_CFG_HOME/foot"
    cat > "$TERM_CFG_HOME/foot/foot.ini" <<'CFG'
    [main]
    font=monospace:size=${toString fontSize}
    CFG

    mkdir -p "$TERM_CFG_HOME/alacritty"
    cat > "$TERM_CFG_HOME/alacritty/alacritty.toml" <<'CFG'
    [font]
    size = ${toString fontSize}.0

    [font.normal]
    family = "monospace"
    CFG

    mkdir -p "$TERM_CFG_HOME/kitty"
    cat > "$TERM_CFG_HOME/kitty/kitty.conf" <<'CFG'
    font_family monospace
    font_size ${toString fontSize}
    CFG

    mkdir -p "$TERM_CFG_HOME/wezterm"
    cat > "$TERM_CFG_HOME/wezterm/wezterm.lua" <<'CFG'
    return {
      font_size = ${toString fontSize}.0,
    }
    CFG

    mkdir -p "$TERM_CFG_HOME/scrgo"
    cat > "$TERM_CFG_HOME/scrgo/config.json" <<'CFG'
    { "font_size": ${toString fontSize}.0 }
    CFG

    export XDG_CONFIG_HOME="$TERM_CFG_HOME"
  '';

  cleanup = ''
    rm -rf "$TERM_CFG_HOME"
  '';
}
