//! Keybindings: chord → action mapping, built from a compile-time default table
//! merged with the user's config. `Action` is the single set of things a key
//! chord (or the command palette) can trigger; `input.zig` owns the dispatch
//! (`runAction`). Chords are parsed with xkbcommon so any key name it knows
//! (`c`, `plus`, `Up`, `Page_Up`, `F5`, …) works; letter case is normalised so a
//! shifted `c` (which arrives as keysym `C`) still matches a `ctrl+shift+c`
//! binding.

const std = @import("std");
const modifiers = @import("modifiers.zig");
const log = @import("log.zig");

const Mods = modifiers.Mods;

const xkb = @cImport(@cInclude("xkbcommon/xkbcommon.h"));
const xkb_syms = @cImport(@cInclude("xkbcommon/xkbcommon-keysyms.h"));

/// Everything a keybinding or a palette command can trigger (defined in the
/// std-only leaf `actions.zig` so the pure-leaf palette can share it). The
/// palette shows a curated subset (see `palette.commands`); the extras
/// (open_palette, per-line/-page scroll) are keybinding-only but still bindable.
pub const Action = @import("actions.zig").Action;

/// A modifier set plus a (case-normalised) keysym.
pub const Chord = struct {
    mods: Mods,
    keysym: u32,
};

pub const Binding = struct {
    chord: Chord,
    action: Action,
};

const cs = Mods{ .ctrl = true, .shift = true };
const sh = Mods{ .shift = true };

/// The built-in bindings, reproducing scrgo's historical hardcoded set. Keysyms
/// are the lowercase/base form so `lookup` (which lowercases the event keysym)
/// matches regardless of Shift.
pub const default_bindings = [_]Binding{
    .{ .chord = .{ .mods = cs, .keysym = xkb_syms.XKB_KEY_p }, .action = .open_palette },
    .{ .chord = .{ .mods = cs, .keysym = xkb_syms.XKB_KEY_plus }, .action = .font_increase },
    .{ .chord = .{ .mods = cs, .keysym = xkb_syms.XKB_KEY_equal }, .action = .font_increase },
    .{ .chord = .{ .mods = cs, .keysym = xkb_syms.XKB_KEY_minus }, .action = .font_decrease },
    .{ .chord = .{ .mods = cs, .keysym = xkb_syms.XKB_KEY_underscore }, .action = .font_decrease },
    .{ .chord = .{ .mods = cs, .keysym = xkb_syms.XKB_KEY_0 }, .action = .font_reset },
    .{ .chord = .{ .mods = cs, .keysym = xkb_syms.XKB_KEY_parenright }, .action = .font_reset },
    .{ .chord = .{ .mods = cs, .keysym = xkb_syms.XKB_KEY_Up }, .action = .scroll_line_up },
    .{ .chord = .{ .mods = cs, .keysym = xkb_syms.XKB_KEY_Down }, .action = .scroll_line_down },
    .{ .chord = .{ .mods = cs, .keysym = xkb_syms.XKB_KEY_Page_Up }, .action = .scroll_page_up },
    .{ .chord = .{ .mods = cs, .keysym = xkb_syms.XKB_KEY_Page_Down }, .action = .scroll_page_down },
    .{ .chord = .{ .mods = cs, .keysym = xkb_syms.XKB_KEY_Home }, .action = .scroll_top },
    .{ .chord = .{ .mods = cs, .keysym = xkb_syms.XKB_KEY_End }, .action = .scroll_bottom },
    .{ .chord = .{ .mods = cs, .keysym = xkb_syms.XKB_KEY_c }, .action = .copy_selection },
    .{ .chord = .{ .mods = cs, .keysym = xkb_syms.XKB_KEY_v }, .action = .paste },
    .{ .chord = .{ .mods = sh, .keysym = xkb_syms.XKB_KEY_Page_Up }, .action = .scroll_page_up },
    .{ .chord = .{ .mods = sh, .keysym = xkb_syms.XKB_KEY_Page_Down }, .action = .scroll_page_down },
};

/// Parse a chord like `"ctrl+shift+c"`: `+`-separated modifier tokens plus one
/// key name. Returns null on a malformed chord or an unknown key name (the
/// caller warns and skips). The keysym is lowercased so it matches a shifted
/// event keysym.
pub fn parseChord(str: []const u8) ?Chord {
    var mods = Mods{};
    var keysym: ?u32 = null;
    var it = std.mem.splitScalar(u8, str, '+');
    while (it.next()) |raw| {
        const tok = std.mem.trim(u8, raw, " \t");
        if (tok.len == 0) continue;
        if (eqAny(tok, &.{ "ctrl", "control" })) {
            mods.ctrl = true;
        } else if (eqAny(tok, &.{"shift"})) {
            mods.shift = true;
        } else if (eqAny(tok, &.{"alt"})) {
            mods.alt = true;
        } else if (eqAny(tok, &.{ "super", "logo", "meta" })) {
            mods.super_ = true;
        } else {
            if (keysym != null) return null; // more than one key name
            var buf: [64]u8 = undefined;
            const name = std.fmt.bufPrintZ(&buf, "{s}", .{tok}) catch return null; // too long
            const ks = xkb.xkb_keysym_from_name(name.ptr, xkb.XKB_KEYSYM_CASE_INSENSITIVE);
            if (ks == xkb.XKB_KEY_NoSymbol) return null;
            keysym = xkb.xkb_keysym_to_lower(ks);
        }
    }
    return .{ .mods = mods, .keysym = keysym orelse return null };
}

fn eqAny(tok: []const u8, names: []const []const u8) bool {
    for (names) |n| if (std.ascii.eqlIgnoreCase(tok, n)) return true;
    return false;
}

/// Resolved chord→action table for a session. Built once at startup; queried per
/// key event.
pub const Keymap = struct {
    allocator: std.mem.Allocator,
    bindings: []Binding,

    /// Merge `specs` (user config) over `defaults`: a spec whose chord already
    /// exists overrides its action; `action == "none"` unbinds that chord; a new
    /// chord is appended. Bad chords / unknown actions are logged and skipped so
    /// one typo never breaks startup.
    /// `specs` is any slice whose elements have `chord`/`action` string fields
    /// (e.g. `config.KeyBinding`) — kept generic so this module stays free of the
    /// config/wayland deps and can be unit-tested on its own.
    pub fn build(
        allocator: std.mem.Allocator,
        defaults: []const Binding,
        specs: anytype,
    ) !Keymap {
        var list: std.ArrayListUnmanaged(Binding) = .empty;
        errdefer list.deinit(allocator);
        try list.appendSlice(allocator, defaults);

        for (specs) |spec| {
            const chord = parseChord(spec.chord) orelse {
                log.warn(.input, "keybinding: unrecognized chord", .{ .chord = spec.chord });
                continue;
            };
            if (std.ascii.eqlIgnoreCase(spec.action, "none")) {
                var i: usize = 0;
                while (i < list.items.len) {
                    if (std.meta.eql(list.items[i].chord, chord)) {
                        _ = list.swapRemove(i);
                    } else i += 1;
                }
                continue;
            }
            const action = std.meta.stringToEnum(Action, spec.action) orelse {
                log.warn(.input, "keybinding: unknown action", .{ .action = spec.action });
                continue;
            };
            var replaced = false;
            for (list.items) |*b| {
                if (std.meta.eql(b.chord, chord)) {
                    b.action = action;
                    replaced = true;
                    break;
                }
            }
            if (!replaced) try list.append(allocator, .{ .chord = chord, .action = action });
        }

        return .{ .allocator = allocator, .bindings = try list.toOwnedSlice(allocator) };
    }

    pub fn deinit(self: *Keymap) void {
        self.allocator.free(self.bindings);
        self.* = undefined;
    }

    /// The action bound to `(mods, keysym)`, or null. The event keysym is
    /// lowercased so Shift-produced uppercase letters match their base binding.
    pub fn lookup(self: *const Keymap, mods: Mods, keysym: u32) ?Action {
        const lowered = xkb.xkb_keysym_to_lower(keysym);
        for (self.bindings) |b| {
            if (std.meta.eql(b.chord.mods, mods) and b.chord.keysym == lowered) return b.action;
        }
        return null;
    }
};

const testing = std.testing;

test "parseChord: modifiers + case-insensitive key name" {
    const c = parseChord("ctrl+shift+c").?;
    try testing.expect(c.mods.ctrl and c.mods.shift and !c.mods.alt and !c.mods.super_);
    try testing.expectEqual(@as(u32, xkb.xkb_keysym_to_lower(xkb_syms.XKB_KEY_c)), c.keysym);

    // Uppercase name resolves to the same lowered keysym.
    try testing.expectEqual(c.keysym, parseChord("Ctrl+Shift+C").?.keysym);

    // Named keys and super alias.
    try testing.expect(parseChord("super+Return") != null);
    try testing.expect(parseChord("ctrl+Page_Up").?.mods.ctrl);

    // Garbage.
    try testing.expect(parseChord("ctrl+notakey") == null);
    try testing.expect(parseChord("ctrl+shift") == null);
}

test "Keymap: merge overrides, unbinds, and adds; lookup normalizes case" {
    const Spec = struct { chord: []const u8, action: []const u8 };
    const specs = [_]Spec{
        .{ .chord = "ctrl+shift+v", .action = "none" }, // unbind default paste
        .{ .chord = "ctrl+shift+y", .action = "paste" }, // add
        .{ .chord = "ctrl+shift+c", .action = "toggle_tt_hint" }, // override default copy
        .{ .chord = "ctrl+shift+bogus", .action = "paste" }, // bad chord → skipped
        .{ .chord = "ctrl+shift+q", .action = "nonexistent" }, // bad action → skipped
    };
    var km = try Keymap.build(testing.allocator, &default_bindings, &specs);
    defer km.deinit();

    // Default copy chord now maps to toggle_tt_hint (lookup lowercases 'C').
    try testing.expectEqual(Action.toggle_tt_hint, km.lookup(cs, xkb_syms.XKB_KEY_C).?);
    // Paste default unbound.
    try testing.expect(km.lookup(cs, xkb_syms.XKB_KEY_V) == null);
    // New paste chord.
    try testing.expectEqual(Action.paste, km.lookup(cs, xkb_syms.XKB_KEY_Y).?);
    // Untouched default still works.
    try testing.expectEqual(Action.open_palette, km.lookup(cs, xkb_syms.XKB_KEY_P).?);
    // Bad specs didn't bind anything.
    try testing.expect(km.lookup(cs, xkb_syms.XKB_KEY_Q) == null);
}
