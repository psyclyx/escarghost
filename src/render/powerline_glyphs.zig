//! Terminal-drawn Powerline separator glyphs (U+E0B0–E0BF).
//!
//! The filled separators (triangles + diagonal slants) are baked once as
//! unit-space `path_fill` records into the atlas — exactly like the unit-rect
//! primitive in `atlas_ref.zig` — then instanced per cell with a
//! position/size transform and the cell's foreground color. Drawing them
//! ourselves makes them fill the cell exactly and tile seam-free, which font
//! glyphs (with their own antialiased edges and side bearings) do not.
//!
//! We build the geometry in a unit [0,1]×[0,1] box; the renderer scales it to
//! the cell via a `{ xx = cell_w, yy = cell_h }` transform. Non-uniform
//! scaling is fine for these because they are pure fills — there is no line
//! thickness to distort. The outline (thin) variants and the rounded
//! half-circles are left to the font for now (they need device-consistent
//! stroke width / arc geometry); they simply fall through to shaping.

const std = @import("std");
const snail = @import("snail");

pub const first: u32 = 0xE0B0;
pub const last: u32 = 0xE0BF;
pub const count: usize = last - first + 1;

/// Codepoints we draw ourselves. Everything else in E0B0–E0BF (outline
/// triangles E0B1/B3, half-circles E0B4–B7 and their outlines) falls through
/// to the font.
pub fn isHandled(cp: u32) bool {
    return switch (cp) {
        0xE0B0, // right-pointing filled triangle (hard divider →)
        0xE0B2, // left-pointing filled triangle  (hard divider ←)
        0xE0B8, // lower-left filled triangle  (slant)
        0xE0BA, // lower-right filled triangle (slant)
        0xE0BC, // upper-left filled triangle  (slant)
        0xE0BE, // upper-right filled triangle (slant)
        => true,
        else => false,
    };
}

/// One baked separator: its atlas record key plus the design→source placement
/// transform produced by `PreparedPath.prepare` (mirrors `AtlasRef.rect_xform`).
pub const Primitive = struct {
    key: snail.record_key.RecordKey,
    xform: snail.Transform2D,
};

/// Fixed-size lookup indexed by `cp - first`. Populated at bootstrap, then
/// read-only for the process lifetime, so no locking is needed.
pub const Table = struct {
    entries: [count]?Primitive = [_]?Primitive{null} ** count,

    pub fn get(self: *const Table, cp: u32) ?Primitive {
        if (cp < first or cp > last) return null;
        return self.entries[cp - first];
    }

    pub fn set(self: *Table, cp: u32, prim: Primitive) void {
        if (cp < first or cp > last) return;
        self.entries[cp - first] = prim;
    }
};

/// Build the unit-space filled path for `cp`, or return null if we don't draw
/// it. Caller owns the returned Path and must `deinit` it. Coordinates use the
/// cell's own frame: x 0→1 left→right, y 0→1 top→bottom.
pub fn buildPath(allocator: std.mem.Allocator, cp: u32) !?snail.Path {
    const V = snail.Vec2.new;
    var p = snail.Path.init(allocator);
    errdefer p.deinit();
    switch (cp) {
        // Right-pointing triangle: full-height left base, apex at right-middle.
        0xE0B0 => {
            try p.moveTo(V(0, 0));
            try p.lineTo(V(1, 0.5));
            try p.lineTo(V(0, 1));
            try p.close();
        },
        // Left-pointing triangle: apex at left-middle, full-height right base.
        0xE0B2 => {
            try p.moveTo(V(1, 0));
            try p.lineTo(V(0, 0.5));
            try p.lineTo(V(1, 1));
            try p.close();
        },
        // Lower-left triangle (diagonal top-left → bottom-right).
        0xE0B8 => {
            try p.moveTo(V(0, 0));
            try p.lineTo(V(0, 1));
            try p.lineTo(V(1, 1));
            try p.close();
        },
        // Lower-right triangle (diagonal top-right → bottom-left).
        0xE0BA => {
            try p.moveTo(V(1, 0));
            try p.lineTo(V(1, 1));
            try p.lineTo(V(0, 1));
            try p.close();
        },
        // Upper-left triangle (diagonal top-right → bottom-left).
        0xE0BC => {
            try p.moveTo(V(0, 0));
            try p.lineTo(V(1, 0));
            try p.lineTo(V(0, 1));
            try p.close();
        },
        // Upper-right triangle (diagonal top-left → bottom-right).
        0xE0BE => {
            try p.moveTo(V(0, 0));
            try p.lineTo(V(1, 0));
            try p.lineTo(V(1, 1));
            try p.close();
        },
        else => {
            p.deinit();
            return null;
        },
    }
    return p;
}
