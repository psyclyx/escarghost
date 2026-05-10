/// Collects text that may contain glyphs not yet in the atlas.
/// Passed to the atlas owner thread which uses HarfBuzz-aware
/// extension (`atlas.extendText`) to discover all needed glyphs
/// — including ligature substitutions.

pub const MaxBytes = 4096;

pub const Set = struct {
    len: usize = 0,
    buf: [MaxBytes]u8 = undefined,

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
        if (self.len + need > MaxBytes) return;
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
