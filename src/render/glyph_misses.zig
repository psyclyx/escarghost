/// Collects text that may contain glyphs not yet in the atlas.
/// Passed to the atlas owner thread which uses HarfBuzz-aware
/// extension (`TextAtlas.ensureText`) to discover all needed glyphs
/// — including ligature substitutions.
///
/// Bounds one bake step: `AtlasRef.extend` shapes + rasterizes this whole
/// buffer in a single uninterruptible call, and the render worker time-boxes
/// how many such steps it runs per frame (see gpu_worker). Keep it small
/// enough that one step stays well under a frame budget — a burst of novel
/// text bakes over a few sampled frames rather than freezing one frame to
/// bake it all. ~4k codepoints per step. The pipelines that embed a `Set`
/// are heap allocated, so this is not a stack concern.
const std = @import("std");

pub const MaxBytes = 16 * 1024;

pub const Set = struct {
    len: usize = 0,
    buf: [MaxBytes]u8 = undefined,
    /// When the buffer fills (a flood: more misses than fit in one bake step),
    /// FIFO (default) drops the newly-added runs — keeping the *top* of the
    /// screen, since runs are added top→bottom. LIFO instead evicts the oldest
    /// (top) runs to admit new ones, keeping the *bottom* — the newest / most-
    /// looked-at content in a terminal. Set from SCRGO_MISS_LIFO at pipeline
    /// init. No effect until the buffer overflows.
    lifo: bool = false,

    pub fn isEmpty(self: *const Set) bool {
        return self.len == 0;
    }

    pub fn clear(self: *Set) void {
        self.len = 0;
    }

    pub fn text(self: *const Set) []const u8 {
        return self.buf[0..self.len];
    }

    /// Append a text run. Runs are separated by spaces so that
    /// HarfBuzz sees word boundaries (won't incorrectly ligate
    /// across unrelated cells).
    pub fn addRun(self: *Set, run: []const u8) void {
        if (run.len == 0) return;
        const need = if (self.len > 0) run.len + 1 else run.len;
        if (need > MaxBytes) return; // a single run larger than the buffer
        if (self.len + need > MaxBytes) {
            if (!self.lifo) return; // FIFO: drop this newest run
            // LIFO: evict whole runs from the front until `run` fits.
            while (self.len + need > MaxBytes) {
                const sp = std.mem.indexOfScalar(u8, self.buf[0..self.len], ' ') orelse {
                    self.len = 0; // only one run left; drop it
                    break;
                };
                const drop = sp + 1; // include the separator
                std.mem.copyForwards(u8, self.buf[0 .. self.len - drop], self.buf[drop..self.len]);
                self.len -= drop;
            }
        }
        if (self.len > 0) {
            self.buf[self.len] = ' ';
            self.len += 1;
        }
        @memcpy(self.buf[self.len..][0..run.len], run);
        self.len += run.len;
    }

    /// Legacy: add a single codepoint (for CPU renderer path).
    pub fn addCodepoint(self: *Set, cp: u32) void {
        if (cp == 0) return;
        var tmp: [4]u8 = undefined;
        const n = @import("std").unicode.utf8Encode(@intCast(cp), &tmp) catch return;
        self.addRun(tmp[0..n]);
    }

    pub fn mergeFrom(self: *Set, other: *const Set) void {
        if (other.isEmpty()) return;
        self.addRun(other.text());
    }
};

test "overflow: fifo keeps oldest runs, lifo keeps newest" {
    const testing = std.testing;
    const big = MaxBytes / 2 - 8; // two fit, a third overflows
    var a: [big]u8 = undefined;
    var b: [big]u8 = undefined;
    var cc: [big]u8 = undefined;
    @memset(&a, 'a');
    @memset(&b, 'b');
    @memset(&cc, 'c');

    var fifo: Set = .{};
    fifo.addRun(&a);
    fifo.addRun(&b);
    fifo.addRun(&cc);
    try testing.expect(std.mem.indexOfScalar(u8, fifo.text(), 'a') != null); // kept oldest
    try testing.expect(std.mem.indexOfScalar(u8, fifo.text(), 'c') == null); // dropped newest
    try testing.expect(fifo.len <= MaxBytes);

    var lifo: Set = .{ .lifo = true };
    lifo.addRun(&a);
    lifo.addRun(&b);
    lifo.addRun(&cc);
    try testing.expect(std.mem.indexOfScalar(u8, lifo.text(), 'a') == null); // evicted oldest
    try testing.expect(std.mem.indexOfScalar(u8, lifo.text(), 'c') != null); // kept newest
    try testing.expect(lifo.len <= MaxBytes);
}
