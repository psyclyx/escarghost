# scrgo

A Wayland-native terminal emulator.

scrgo renders text with [snail](https://github.com/psyclyx/snail) (a vector
glyph rasterizer with a GPU and CPU backend) and drives terminal state with
[ghostty-vt](https://github.com/ghostty-org/ghostty) (the VT parser and grid
model extracted from Ghostty). It talks to the compositor directly over the
Wayland protocol — there is no GTK/Qt/SDL layer.

Status: early (`0.0.1`). Usable as a daily driver on a single window, but
there are no tabs, splits, or ligature/IME polish, and the config surface is
intentionally small.

## Requirements

Runtime:

- A Wayland compositor.
- A Vulkan driver (Mesa or vendor ICD) for the GPU renderer. Without one,
  scrgo falls back to the CPU renderer.
- fontconfig (font resolution), libpulseaudio (audible bell).

Build:

- Zig 0.16.0.
- `libghostty-vt` headers + static archive.
- wayland, wayland-protocols, wayland-scanner, libxkbcommon, fontconfig,
  harfbuzz, libpulseaudio, and Mesa/GL/DRM/GBM development packages.

The exact pinned set lives in `nix/packages/scrgo.nix` and `nix/shell.nix`.

## Building

### Nix (self-contained)

```sh
nix-build -A default        # → ./result/bin/scrgo
```

### Zig (development)

The dev shell provides the toolchain and exports the paths the build reads
(`GHOSTTY_VT_INCLUDE`, `GHOSTTY_VT_LIB`, `WAYLAND_PROTOCOLS_DIR`,
`WAYLAND_SCANNER`):

```sh
nix-shell -A shell          # or `direnv allow` — see .envrc
zig build                   # → ./zig-out/bin/scrgo
zig build run               # build and launch
```

`zig build` fetches snail from the URL pinned in `build.zig.zon`. To build
against a local snail checkout, pass `--fork=/path/to/snail`.

## Running

```sh
scrgo                        # launch $SHELL
scrgo -- htop                # run a command instead of the shell
scrgo -c ./my-config.json    # use a specific config file
scrgo --renderer cpu         # force the CPU renderer
```

```
Usage: scrgo [OPTIONS] [-- COMMAND [ARGS...]]

Options:
  -h, --help              Show this help and exit
  -V, --version           Show version and exit
  -c, --config PATH       Config file (default: $XDG_CONFIG_HOME/scrgo/config.json)
      --renderer BACKEND   Renderer backend: auto | cpu | gpu (default: auto)
      --generate-completion SHELL   Print a completion script (bash|zsh|fish)
  -v, -vv, -vvv           Increase log verbosity (cumulative)
```

Everything after `--` is executed instead of `$SHELL`: the first token is the
program, the rest are its arguments.

## Configuration

scrgo reads JSON from `$XDG_CONFIG_HOME/scrgo/config.json` (falling back to
`~/.config/scrgo/config.json`), or from the path given to `-c`. A missing file
is not an error unless `-c` names it explicitly. All keys are optional.

```jsonc
{
  // Primary font: a fontconfig family name or an absolute path to a font
  // file. Empty resolves fontconfig's "monospace".
  "font": "DejaVu Sans Mono",
  // Fallback fonts (fontconfig patterns), tried in order for missing glyphs.
  "fallback_fonts": ["Symbols Nerd Font Mono", "Noto Color Emoji"],
  "font_size": 11.0,            // points (converted to px at 96 DPI)

  "cols": 80,                   // initial window size, in cells
  "rows": 24,
  "max_scrollback": 10000,      // lines
  "shell": "/bin/zsh",          // default: $SHELL

  // Colors are "#rrggbb" hex strings.
  "foreground": "#c5c8c6",
  "background": "#1d1f21",
  "cursor_color": "#c5c8c6",    // omit to use the default
  "generate_256_from_base16": true,  // fill the 256-color cube from base16
  "colors": {                   // base16 palette (base00..base0F)
    "base00": "#1d1f21",
    "base05": "#c5c8c6",
    "base08": "#cc6666"
    // ...
  },

  "bell": {
    "mode": "visual",           // none | visual | audible | both
    "visual_duration_ms": 150,
    "audible_debounce_ms": 200  // min gap between tones under \a spam
  },

  // Touch input
  "touch_momentum": true,       // kinetic fling on touch/drag release
  "touch_long_press_ms": 400,
  "touch_drift_px": 8,

  // GPU renderer restart backoff (on driver loss)
  "gpu_restart_initial_delay_ms": 250,
  "gpu_restart_max_delay_ms": 5000,
  "gpu_restart_jitter_percent": 20
}
```

## Keybindings

| Key | Action |
| --- | --- |
| `Ctrl+Shift+C` | Copy selection to clipboard |
| `Ctrl+Shift+V` | Paste from clipboard |
| Middle click | Paste primary selection |
| `Ctrl+Shift++` / `-` / `0` | Zoom in / out / reset |
| `Shift+PageUp` / `PageDown` | Scroll by a page |
| `Ctrl+Shift+PageUp` / `PageDown` / `Home` / `End` / `Up` / `Down` | Scroll |

Selection copies to the primary selection automatically; typing scrolls to the
bottom.

Debug bindings (for development): `Ctrl+Shift+F1` kills the active renderer,
`F2` swaps CPU/GPU, `F3` clears the glyph atlas, `F4` cycles the hinting mode.

## Renderer backends

scrgo runs the terminal event loop on the main thread and offloads rendering to
worker threads:

- **GPU** — a Vulkan backend that renders into dmabufs shared with the
  compositor. Preferred; the longest-lived pole at startup, so its thread is
  spawned first.
- **CPU** — a software rasterizer into wl_shm buffers. Paints the first frames
  and serves as the fallback whenever the GPU path is unavailable.

`auto` (the default) starts on the CPU renderer and switches to the GPU
renderer once its context, dmabuf import, and first frame are ready. If the GPU
path fails at runtime it drops back to CPU and retries with backoff. Force a
backend with `--renderer` or `SCRGO_RENDERER`.

## Environment variables

| Variable | Effect |
| --- | --- |
| `SCRGO_RENDERER` | `auto` \| `cpu` \| `gpu` (same as `--renderer`) |
| `SCRGO_FLAGS` | Comma-separated runtime flags (e.g. atlas reset each frame) |
| `SCRGO_LOG`, `SCRGO_LOG_COLOR` | Log scope selection / colored output |
| `SCRGO_TRACE=commits` | Per-commit timing trace + memory poller |
| `SCRGO_WARN_SLOW_MS` | Warn when a frame exceeds this budget |
| `SCRGO_TOUCH_SIMULATE` | Emulate touch from pointer input |

Additional `SCRGO_*` variables tune the renderer internals; grep the source for
the full set.

## Development

```sh
zig build test              # all headless tests
zig build test-cli          # per-suite: cli, bell, headless, input
zig build integration-test  # build the headless integration-test binary
nix-build -A bench && ./result/bin/bench --help   # comparison benchmarks
```

Shell completions are generated from the CLI option table at build time
(`zig build`, or the standalone `gen-completions` step).
</content>
</invoke>
