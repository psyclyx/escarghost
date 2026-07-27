const std = @import("std");
const snail = @import("snail");
const powerline = @import("powerline_glyphs.zig");

const c = @cImport({
    @cInclude("pthread.h");
});

/// Thread-safe snail.Atlas snapshot reference.
///
/// The atlas thread publishes new (immutable) snapshots by calling `publish()`.
/// Renderer threads acquire leases for snapshots they use. A retired snapshot
/// is freed only after its last lease is released, so long CPU frames and
/// in-flight GPU frames cannot race atlas publication.
///
/// In snail 0.13, the atlas is a value type (`snail.Atlas`) backed by a
/// `snail.PagePool`. Extensions produce a new `Atlas` value (sharing
/// unchanged pages with the parent via persistent-map structure sharing).
/// The `PagePool` outlives all atlases — it's owned by `AtlasRef` and
/// shared across every snapshot.
pub const AtlasRef = struct {
    mutex: std.atomic.Mutex = .unlocked,
    /// Serializes every HarfBuzz shape operation. snail's `Faces` keeps
    /// one `hb_buffer_t` per face; all our threads share that buffer when
    /// they call `snail.shape`. Concurrent users would trip HarfBuzz
    /// internal asserts. pthread_mutex (blocking) because shape can take
    /// milliseconds; spinning would burn CPU.
    shape_lock: c.pthread_mutex_t = std.mem.zeroes(c.pthread_mutex_t),
    current: ?*Snapshot = null,
    retired: ?*Snapshot = null,
    generation: std.atomic.Value(u64) = .init(0),
    allocator: std.mem.Allocator,
    /// The shared page pool. Outlives all atlas snapshots.
    pool: *snail.PagePool,
    /// The shared Faces collection. Outlives all atlas snapshots.
    /// Shape operations need this; it's stored here so render threads
    /// can access it through the AtlasRef without a separate pointer.
    faces: ?*snail.Faces = null,

    /// A unit filled-rectangle path record (namespace `path_fill`) baked into
    /// the atlas at bootstrap. Renderers instance it — varying `local_transform`
    /// (position/size) per shape and `world_tint` (color/alpha) per emit call —
    /// to draw solid/translucent cell backgrounds, decorations, selection,
    /// cursor, scrollbar, and bell through the ordinary path pipeline, with no
    /// separate solid-color pipeline. The record persists across atlas
    /// extensions via persistent-map structure sharing.
    rect_key: snail.record_key.RecordKey = .{ .namespace = 0, .a = 0, .b = 0, .c = 0 },
    rect_xform: snail.Transform2D = .identity,
    has_rect: bool = false,

    /// Baked Powerline separator primitives (U+E0B0–E0BF filled shapes),
    /// keyed like `rect_key` but one record per glyph. Populated by
    /// `ensurePowerlineGlyphs` at bootstrap; read-only afterwards.
    powerline: powerline.Table = .{},

    /// When true, the render path draws Powerline separators and
    /// box-drawing/block glyphs itself instead of shaping them from the font.
    /// Set once from config before the first frame. See [[custom_glyphs]].
    custom_glyphs: bool = true,

    const Snapshot = struct {
        atlas: *snail.Atlas,
        readers: usize = 0,
        retired: bool = false,
        next_retired: ?*Snapshot = null,
    };

    pub const Lease = struct {
        ref: *AtlasRef,
        snapshot: ?*Snapshot,

        pub fn get(self: *const Lease) *snail.Atlas {
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

    /// Create an AtlasRef with an initial empty atlas on the heap.
    /// The pool is owned by the AtlasRef and destroyed in deinit.
    pub fn init(allocator: std.mem.Allocator, pool: *snail.PagePool, faces: *snail.Faces) !AtlasRef {
        const atlas_ptr = try allocator.create(snail.Atlas);
        errdefer allocator.destroy(atlas_ptr);
        atlas_ptr.* = try snail.Atlas.init(allocator, pool);

        const snapshot = try allocator.create(Snapshot);
        errdefer allocator.destroy(snapshot);
        snapshot.* = .{ .atlas = atlas_ptr };

        var ref: AtlasRef = .{
            .current = snapshot,
            .generation = .init(1),
            .allocator = allocator,
            .pool = pool,
            .faces = faces,
        };
        if (c.pthread_mutex_init(&ref.shape_lock, null) != 0) return error.MutexInitFailed;
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

    /// Acquire/release the shape lock around a render-path shape. Every
    /// caller of `snail.shape` (via `row_build.buildSnapshot`) must hold
    /// this for the duration of the shape, exactly like `extend` does:
    /// snail's `Faces` keeps one shared `hb_buffer_t`, so the CPU and GPU
    /// render workers shaping concurrently (e.g. during the CPU→GPU path
    /// handoff) would corrupt it and crash. Blocking (not spin): a shape
    /// can take milliseconds and spinning would burn a core.
    pub fn lockShaping(self: *AtlasRef) void {
        _ = c.pthread_mutex_lock(&self.shape_lock);
    }

    pub fn unlockShaping(self: *AtlasRef) void {
        _ = c.pthread_mutex_unlock(&self.shape_lock);
    }

    pub const ExtendResult = enum {
        extended,
        missing,
    };

    /// Synchronously extend the atlas snapshot to cover `miss_text`.
    /// Shapes the text, records missing glyphs into a new atlas, and
    /// publishes the new snapshot. Holds `shape_lock` across the
    /// shape + record + publish to keep concurrent extenders safe.
    pub fn extend(
        self: *AtlasRef,
        baseline: *const snail.Atlas,
        faces: *snail.Faces,
        miss_text: []const u8,
    ) !ExtendResult {
        _ = c.pthread_mutex_lock(&self.shape_lock);
        defer _ = c.pthread_mutex_unlock(&self.shape_lock);

        // Shape the miss text
        var shaped = snail.shape(self.allocator, faces, miss_text, .{}) catch return .missing;
        defer shaped.deinit();

        // Clone the baseline atlas (shares unchanged pages via persistent-map)
        var next = try baseline.extend(self.allocator, &.{});

        // Record unhinted glyphs from the shaped text (in-place on the clone)
        snail.recordUnhintedRun(&next, self.allocator, faces, &shaped, .{}) catch {
            next.deinit();
            return .missing;
        };

        // Publish the new snapshot
        const heap = self.allocator.create(snail.Atlas) catch {
            next.deinit();
            return error.OutOfMemory;
        };
        heap.* = next;
        self.publish(heap) catch |err| {
            heap.deinit();
            self.allocator.destroy(heap);
            return err;
        };
        return .extended;
    }

    /// Record the unit filled-rectangle primitive into the current atlas.
    /// Idempotent; call once during bootstrap before any rendering. The
    /// record's key and design→source placement are stashed for renderers.
    pub fn ensureRectPrimitive(self: *AtlasRef) !void {
        if (self.has_rect) return;
        const alloc = self.allocator;

        var p = snail.Path.init(alloc);
        defer p.deinit();
        try p.addRect(.{ .x = 0, .y = 0, .w = 1, .h = 1 });

        var prep = try p.prepare(alloc);
        defer prep.deinit();

        var curves = try prep.fillCurves(alloc, alloc);
        defer curves.deinit();

        const key = snail.record_key.RecordKey{
            .namespace = snail.record_key.ns.path_fill,
            .a = 0,
            .b = 0,
            .c = 0,
        };
        const entry = snail.AtlasEntry{
            .key = key,
            .curves = curves,
            .paint = try prep.paintForDesign(.{ .solid = .{ 1, 1, 1, 1 } }),
        };

        self.lock();
        defer self.unlock();
        try self.current.?.atlas.extendInPlace(alloc, &.{entry});
        self.rect_key = key;
        self.rect_xform = prep.design_to_source;
        self.has_rect = true;
        _ = self.generation.fetchAdd(1, .release);
    }

    /// Bake the filled Powerline separators (U+E0B0–E0BF) as unit-space
    /// `path_fill` records, one per glyph, keyed by codepoint. Idempotent-ish:
    /// call once during bootstrap after `ensureRectPrimitive`. Each record's
    /// key + design→source placement is stashed in `self.powerline` for the
    /// render path to instance per cell. See [[powerline_glyphs]].
    pub fn ensurePowerlineGlyphs(self: *AtlasRef) !void {
        const alloc = self.allocator;
        var cp: u32 = powerline.first;
        while (cp <= powerline.last) : (cp += 1) {
            if (!powerline.isHandled(cp)) continue;
            if (self.powerline.get(cp) != null) continue;

            var path = (try powerline.buildPath(alloc, cp)) orelse continue;
            defer path.deinit();

            var prep = try path.prepare(alloc);
            defer prep.deinit();

            var curves = try prep.fillCurves(alloc, alloc);
            defer curves.deinit();

            const key = snail.record_key.RecordKey{
                .namespace = snail.record_key.ns.path_fill,
                .a = cp,
                .b = 0,
                .c = 0,
            };
            const entry = snail.AtlasEntry{
                .key = key,
                .curves = curves,
                .paint = try prep.paintForDesign(.{ .solid = .{ 1, 1, 1, 1 } }),
            };

            {
                self.lock();
                defer self.unlock();
                try self.current.?.atlas.extendInPlace(alloc, &.{entry});
                _ = self.generation.fetchAdd(1, .release);
            }
            self.powerline.set(cp, .{ .key = key, .xform = prep.design_to_source });
        }
    }

    /// Publish a new snapshot, retiring the old one.
    pub fn publish(self: *AtlasRef, next: *snail.Atlas) !void {
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
        _ = c.pthread_mutex_destroy(&self.shape_lock);
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
