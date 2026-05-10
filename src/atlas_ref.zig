const std = @import("std");
const snail = @import("snail");

/// Thread-safe, lock-free TextAtlas snapshot reference.
///
/// The atlas thread publishes new (immutable) snapshots by calling `publish()`.
/// Renderer threads call `load()` at frame start to get a snapshot that remains
/// valid for the entire frame — no locking required on the read path.
///
/// Memory safety: `publish()` keeps the previous snapshot alive until the *next*
/// publish, which is always long after any in-flight frame has completed
/// (atlas extensions take tens of ms; frames take <2ms with only 2 buffer
/// slots per renderer).
pub const AtlasRef = struct {
    current: std.atomic.Value(?*snail.TextAtlas) = .init(null),
    generation: std.atomic.Value(u64) = .init(0),

    /// Previous snapshot kept alive so in-flight readers don't use-after-free.
    /// Only written by the atlas thread (via `publish`).
    previous: ?*snail.TextAtlas = null,

    allocator: std.mem.Allocator,

    /// Create an AtlasRef with the given snapshot moved to the heap.
    /// The caller must not use `initial` after this call.
    pub fn init(allocator: std.mem.Allocator, initial: snail.TextAtlas) !AtlasRef {
        const heap = try allocator.create(snail.TextAtlas);
        heap.* = initial;
        return .{
            .current = .init(heap),
            .generation = .init(1),
            .previous = null,
            .allocator = allocator,
        };
    }

    /// Atomically load the current snapshot pointer. Lock-free.
    pub fn load(self: *const AtlasRef) *snail.TextAtlas {
        return self.current.load(.acquire).?;
    }

    /// Atomically load the generation counter. Lock-free.
    pub fn loadGeneration(self: *const AtlasRef) u64 {
        return self.generation.load(.acquire);
    }

    /// Publish a new snapshot, retiring the old one.
    /// Must only be called from the atlas thread.
    pub fn publish(self: *AtlasRef, next: *snail.TextAtlas) void {
        if (self.previous) |prev| {
            prev.deinit();
            self.allocator.destroy(prev);
        }
        self.previous = self.current.load(.acquire);
        self.current.store(next, .release);
        _ = self.generation.fetchAdd(1, .release);
    }

    /// Clean up all held snapshots. Call only when no threads are reading.
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
