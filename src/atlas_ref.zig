const std = @import("std");
const snail = @import("snail");

const c = @cImport({
    @cInclude("pthread.h");
});

/// Thread-safe TextAtlas snapshot reference.
///
/// The atlas thread publishes new (immutable) snapshots by calling `publish()`.
/// Renderer threads acquire leases for snapshots they use. A retired snapshot
/// is freed only after its last lease is released, so long CPU frames and
/// cached TextBlobs cannot race atlas publication.
pub const AtlasRef = struct {
    mutex: std.atomic.Mutex = .unlocked,
    /// Serializes `ensureText + publish` pairs. Two concurrent extenders
    /// (render thread doing sync extension; the optional prefetch worker)
    /// otherwise race against the same baseline, with the loser's work
    /// silently overwritten on publish. pthread_mutex (blocking) instead
    /// of the spin `mutex` above because ensureText is an O(ms) shaping
    /// + page-build operation; spinning on it would burn CPU.
    extension_lock: c.pthread_mutex_t = std.mem.zeroes(c.pthread_mutex_t),
    current: ?*Snapshot = null,
    retired: ?*Snapshot = null,
    generation: std.atomic.Value(u64) = .init(0),
    allocator: std.mem.Allocator,

    const Snapshot = struct {
        atlas: *snail.TextAtlas,
        readers: usize = 0,
        retired: bool = false,
        next_retired: ?*Snapshot = null,
    };

    pub const Lease = struct {
        ref: *AtlasRef,
        snapshot: ?*Snapshot,

        pub fn get(self: *const Lease) *snail.TextAtlas {
            return self.snapshot.?.atlas;
        }

        pub fn clone(self: *const Lease) Lease {
            return self.ref.retain(self.snapshot.?);
        }

        pub fn release(self: *Lease) void {
            const snapshot = self.snapshot orelse return;
            self.ref.releaseSnapshot(snapshot);
            self.snapshot = null;
        }
    };

    /// Create an AtlasRef with the given snapshot moved to the heap.
    /// The caller must not use `initial` after this call.
    pub fn init(allocator: std.mem.Allocator, initial: snail.TextAtlas) !AtlasRef {
        const heap = try allocator.create(snail.TextAtlas);
        errdefer allocator.destroy(heap);
        heap.* = initial;
        const snapshot = try allocator.create(Snapshot);
        errdefer allocator.destroy(snapshot);
        snapshot.* = .{ .atlas = heap };
        var ref: AtlasRef = .{
            .current = snapshot,
            .generation = .init(1),
            .allocator = allocator,
        };
        if (c.pthread_mutex_init(&ref.extension_lock, null) != 0) return error.MutexInitFailed;
        return ref;
    }

    /// Acquire the current snapshot and keep it alive until the lease is
    /// released.
    pub fn acquire(self: *AtlasRef) Lease {
        self.lock();
        defer self.unlock();

        const snapshot = self.current.?;
        snapshot.readers += 1;
        return .{ .ref = self, .snapshot = snapshot };
    }

    /// Atomically load the generation counter. Lock-free.
    pub fn loadGeneration(self: *const AtlasRef) u64 {
        return self.generation.load(.acquire);
    }

    pub const ExtendResult = enum {
        /// The extension produced a new atlas snapshot and it has been
        /// published. Caller should re-acquire to see it.
        extended,
        /// The font has no glyphs for some of the requested codepoints.
        /// No new snapshot was produced; caller should ship partial.
        missing,
    };

    /// Synchronously extend the atlas snapshot to cover `miss_text`. Holds
    /// `extension_lock` across the `ensureText + publish` pair to keep two
    /// concurrent extenders from clobbering each other.
    pub fn extend(
        self: *AtlasRef,
        baseline: *const snail.TextAtlas,
        miss_text: []const u8,
    ) !ExtendResult {
        _ = c.pthread_mutex_lock(&self.extension_lock);
        defer _ = c.pthread_mutex_unlock(&self.extension_lock);

        var next = (try baseline.ensureText(.{}, miss_text)) orelse return .missing;
        const heap = self.allocator.create(snail.TextAtlas) catch |err| {
            next.deinit();
            return err;
        };
        heap.* = next;
        self.publish(heap) catch |err| {
            heap.deinit();
            self.allocator.destroy(heap);
            return err;
        };
        return .extended;
    }

    /// Publish a new snapshot, retiring the old one.
    /// Must only be called from the atlas thread.
    pub fn publish(self: *AtlasRef, next: *snail.TextAtlas) !void {
        const next_snapshot = try self.allocator.create(Snapshot);
        errdefer self.allocator.destroy(next_snapshot);
        next_snapshot.* = .{ .atlas = next };

        self.lock();
        defer self.unlock();

        const old = self.current;
        self.current = next_snapshot;
        if (old) |snapshot| self.retireLocked(snapshot);
        _ = self.generation.fetchAdd(1, .release);
    }

    /// Clean up all held snapshots. Call only when no threads are reading.
    pub fn deinit(self: *AtlasRef) void {
        {
            self.lock();
            defer self.unlock();

            self.sweepRetiredLocked();
            while (self.retired) |snapshot| {
                self.retired = snapshot.next_retired;
                self.destroySnapshot(snapshot);
            }
            if (self.current) |snapshot| {
                self.destroySnapshot(snapshot);
                self.current = null;
            }
        }
        _ = c.pthread_mutex_destroy(&self.extension_lock);
    }

    fn retain(self: *AtlasRef, snapshot: *Snapshot) Lease {
        self.lock();
        defer self.unlock();
        snapshot.readers += 1;
        return .{ .ref = self, .snapshot = snapshot };
    }

    fn releaseSnapshot(self: *AtlasRef, snapshot: *Snapshot) void {
        self.lock();
        defer self.unlock();

        std.debug.assert(snapshot.readers > 0);
        snapshot.readers -= 1;
        if (snapshot.retired and snapshot.readers == 0) self.sweepRetiredLocked();
    }

    fn retireLocked(self: *AtlasRef, snapshot: *Snapshot) void {
        snapshot.retired = true;
        snapshot.next_retired = self.retired;
        self.retired = snapshot;
        self.sweepRetiredLocked();
    }

    fn sweepRetiredLocked(self: *AtlasRef) void {
        var cursor: *?*Snapshot = &self.retired;
        while (cursor.*) |snapshot| {
            if (snapshot.readers == 0) {
                cursor.* = snapshot.next_retired;
                self.destroySnapshot(snapshot);
            } else {
                cursor = &snapshot.next_retired;
            }
        }
    }

    fn destroySnapshot(self: *AtlasRef, snapshot: *Snapshot) void {
        snapshot.atlas.deinit();
        self.allocator.destroy(snapshot.atlas);
        self.allocator.destroy(snapshot);
    }

    fn lock(self: *AtlasRef) void {
        while (!self.mutex.tryLock()) std.atomic.spinLoopHint();
    }

    fn unlock(self: *AtlasRef) void {
        self.mutex.unlock();
    }
};
