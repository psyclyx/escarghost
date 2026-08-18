# Changelog

## 0.1.0

First tagged release. A Wayland-native terminal emulator rendering with snail
(GPU + CPU backends) and ghostty-vt for terminal state.

### Added

- TrueType bytecode hinting for the primary monospace face, off by default.
  Set `tt_hint` in config or toggle it at runtime from the command palette.
  Fallback faces always render unhinted; it's a no-op on non-TrueType primaries
  and self-disables if a face can't be hinted, so it never breaks rendering.
- Command palette (`Ctrl+Shift+P`) to twiddle runtime settings — font size,
  custom glyphs, hinting, renderer swap, and other debug actions — each row
  showing its current value.
- Color-bitmap (emoji) glyphs via libspng PNG-strike decode.
- Automatic per-glyph fontconfig fallback for codepoints the configured chain
  doesn't cover, loaded at render time.
- Terminal-drawn Powerline separators and box-drawing/block elements
  (`custom_glyphs`), sized to the cell for seam-free lines.

### Changed

- GPU present uses a freshest-complete policy: draw as fast as buffers allow,
  show the newest all-glyphs-resident frame, with a staleness deadline that
  caps pop-in. Async atlas upload is decoupled from present via explicit sync.
- Glyph prep is pipelined across extract and apply threads; the CPU raster
  path memoizes glyph coverage tiles.
- Renderer debug actions (kill / swap CPU-GPU / clear atlas) moved from
  `Ctrl+Shift+F1`–`F4` keybindings into the command palette.

### Fixed

- The glyph under a block cursor is now redrawn in the cell's background color
  (inverted, like Ghostty) instead of washing out under a same-colored block.
