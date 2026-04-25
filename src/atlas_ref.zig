const std = @import("std");
const snail = @import("snail");

/// Thread-safe, lock-free atlas reference.
///
/// The atlas thread publishes new (immutable) atlases by calling `publish()`.
/// Renderer threads call `load()` at frame start to get a snapshot that remains
/// valid for the entire frame — no locking required on the read path.
///
/// Memory safety: `publish()` keeps the previous atlas alive until the *next*
/// publish, which is always long after any in-flight frame has completed
/// (atlas extensions take tens of ms; frames take <2ms with only 2 buffer
/// slots per renderer).
pub const AtlasRef = struct {
    current: std.atomic.Value(?*snail.Atlas) = .init(null),
    generation: std.atomic.Value(u64) = .init(0),

    /// Previous atlas kept alive so in-flight readers don't use-after-free.
    /// Only written by the atlas thread (via `publish`).
    previous: ?*snail.Atlas = null,

    allocator: std.mem.Allocator,

    /// Create an AtlasRef with the given atlas moved to the heap.
    /// The caller must not use `initial` after this call.
    pub fn init(allocator: std.mem.Allocator, initial: snail.Atlas) !AtlasRef {
        const heap = try allocator.create(snail.Atlas);
        heap.* = initial;
        return .{
            .current = .init(heap),
            .generation = .init(1),
            .previous = null,
            .allocator = allocator,
        };
    }

    /// Atomically load the current atlas pointer. Lock-free.
    pub fn load(self: *const AtlasRef) *snail.Atlas {
        return self.current.load(.acquire).?;
    }

    /// Atomically load the generation counter. Lock-free.
    pub fn loadGeneration(self: *const AtlasRef) u64 {
        return self.generation.load(.acquire);
    }

    /// Publish a new atlas, retiring the old one.
    /// Must only be called from the atlas thread.
    pub fn publish(self: *AtlasRef, next: *snail.Atlas) void {
        // Free the atlas from two publishes ago (safe — no readers left).
        if (self.previous) |prev| {
            prev.deinit();
            self.allocator.destroy(prev);
        }
        // Retire current → previous.
        self.previous = self.current.load(.acquire);
        // Publish new.
        self.current.store(next, .release);
        _ = self.generation.fetchAdd(1, .release);
    }

    /// Clean up all held atlases. Call only when no threads are reading.
    pub fn deinit(self: *AtlasRef) void {
        if (self.previous) |prev| {
            prev.deinit();
            self.allocator.destroy(prev);
            self.previous = null;
        }
        if (self.current.load(.acquire)) |cur| {
            cur.deinit();
            self.allocator.destroy(cur);
            self.current.store(null, .release);
        }
    }
};
