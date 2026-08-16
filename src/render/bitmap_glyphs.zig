//! Color-bitmap (emoji) glyph residency + placement table.
//!
//! snail 0.18 surfaces embedded emoji strikes as encoded PNG bytes; we decode
//! them (see `png_decode.zig`) and bake each as an image-painted em-bbox rect
//! into the atlas — a bitmap glyph is a placed image, not a coverage glyph
//! (see snail's `src/snail-raster/draw.zig` bitmap tests for the pattern).
//!
//! This table is the prep↔render bridge. The prep/apply threads populate it as
//! strikes are decoded and baked; the render path reads it to (a) treat a baked
//! strike as resident during miss detection and (b) swap a shaped glyph onto
//! its bitmap record at placement time (like `powerline.Primitive`).
//!
//! **All access is serialized by `AtlasRef.shape_lock`** — the render path
//! holds it across the whole `buildSnapshot`; the prep and apply threads take
//! it for the brief table read/write — so the maps need no internal locking.

const std = @import("std");
const snail = @import("snail");

/// A baked strike, keyed by (font, glyph, ppem). Bitmaps are ppem-specific:
/// a font-size change needs a fresh record at the new ppem.
pub const Id = struct { font_id: u32, glyph_id: u16, ppem: u16 };

/// One baked bitmap glyph: the atlas record key, the design→source placement of
/// its em-bbox rect (folded into the glyph's placement transform, mirroring
/// `powerline.Primitive.xform`), and the owned decoded image the atlas borrows.
/// The image is heap-allocated so its address is stable while referenced by an
/// atlas snapshot, and is kept for the process lifetime (freed in `deinit`).
pub const Entry = struct {
    key: snail.record_key.RecordKey,
    xform: snail.Transform2D,
    image: *snail.Image,
};

pub const Table = struct {
    baked: std.AutoHashMapUnmanaged(Id, Entry) = .empty,
    /// `(font_id << 32 | glyph_id)` for every glyph we've ever found a strike
    /// on, at any ppem. Lets miss detection re-request a bake after a font-size
    /// change (new ppem ⇒ new record) without paying `Font.colorBitmap` on the
    /// render hot path.
    strikes: std.AutoHashMapUnmanaged(u64, void) = .empty,

    fn strikeKey(font_id: u32, glyph_id: u16) u64 {
        return (@as(u64, font_id) << 32) | glyph_id;
    }

    /// The baked strike for `id`, or null if not yet resident. Read under
    /// `shape_lock`.
    pub fn get(self: *const Table, id: Id) ?Entry {
        return self.baked.get(id);
    }

    /// True once `id`'s record is baked and placeable.
    pub fn isResident(self: *const Table, id: Id) bool {
        return self.baked.contains(id);
    }

    /// True if this glyph is known to carry a strike (at any ppem seen so far).
    pub fn hasStrike(self: *const Table, font_id: u32, glyph_id: u16) bool {
        return self.strikes.contains(strikeKey(font_id, glyph_id));
    }

    /// Record that `glyph_id` in `font_id` carries a strike. Best-effort: an
    /// allocation failure just means we re-discover it via `Font.colorBitmap`.
    pub fn markStrike(self: *Table, allocator: std.mem.Allocator, font_id: u32, glyph_id: u16) void {
        self.strikes.put(allocator, strikeKey(font_id, glyph_id), {}) catch {};
    }

    /// Publish a baked strike. On allocation failure the caller must free
    /// `entry.image` itself (returns false); on success the table owns it.
    pub fn put(self: *Table, allocator: std.mem.Allocator, id: Id, entry: Entry) bool {
        self.baked.put(allocator, id, entry) catch return false;
        return true;
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        var it = self.baked.valueIterator();
        while (it.next()) |e| {
            e.image.deinit();
            allocator.destroy(e.image);
        }
        self.baked.deinit(allocator);
        self.strikes.deinit(allocator);
    }
};
