const std = @import("std");

pub const MaxCodepoints = 64;

pub const Set = struct {
    count: u8 = 0,
    codepoints: [MaxCodepoints]u32 = [_]u32{0} ** MaxCodepoints,

    pub fn isEmpty(self: *const Set) bool {
        return self.count == 0;
    }

    pub fn clear(self: *Set) void {
        self.count = 0;
    }

    pub fn slice(self: *const Set) []const u32 {
        return self.codepoints[0..self.count];
    }

    pub fn add(self: *Set, cp: u32) void {
        if (cp == 0) return;
        for (self.codepoints[0..self.count]) |existing| {
            if (existing == cp) return;
        }
        if (self.count >= MaxCodepoints) return;
        self.codepoints[self.count] = cp;
        self.count += 1;
    }

    pub fn mergeFrom(self: *Set, other: *const Set) void {
        for (other.slice()) |cp| self.add(cp);
    }
};
