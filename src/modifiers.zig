//! Keyboard modifier state — a std-only leaf so `keybindings.zig` can match
//! chords without importing the heavy `wayland` module. `wayland.zig` re-exports
//! this as `wayland.Mods`, so `KeyEvent.mods` and a `Chord`'s mods are the same
//! type.

pub const Mods = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super_: bool = false,
};
