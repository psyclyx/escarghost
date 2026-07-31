const std = @import("std");
const snail = @import("snail");
const powerline = @import("powerline_glyphs.zig");
const glyph_misses = @import("glyph_misses.zig");
const log = @import("../log.zig");

const c = @cImport({
    @cInclude("pthread.h");
    @cInclude("sys/eventfd.h");
    @cInclude("unistd.h");
});

// Prep-thread diagnostics (globals: one AtlasRef per process). `prep_full`
// counts records dropped because the page pool is out of layers — the
// "atlas can't hold all distinct glyphs, needs eviction" signal. `records`
// is the live glyph count in the latest published atlas.
pub var prepOkCount: u64 = 0;
pub var prepFullCount: u64 = 0;
pub var prepErrCount: u64 = 0;
pub var atlasRecords: u64 = 0;

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
    ///
    /// Auto-fallback (see `ensureFallbackCoverage`) may swap this pointer
    /// for a rebuilt `Faces` that appends a newly loaded font. The swap
    /// happens under `shape_lock`; the superseded `Faces` is moved to
    /// `retired_faces` (never freed until deinit) rather than destroyed,
    /// so a render worker still holding a stale pointer can't dangle.
    faces: ?*snail.Faces = null,

    // ── Automatic per-glyph font fallback ──
    //
    // The configured chain (primary + user `fallback_fonts`) only covers
    // the scripts those fonts carry. When shaping a miss run turns up a
    // codepoint no current face covers, we ask `fallback_resolve` (a
    // fontconfig-backed lookup installed at bootstrap) for a font that
    // does, load it, and rebuild `Faces` with it appended. All of this
    // runs inside `extend`, under `shape_lock`, so it's serialized with
    // every other shape.

    /// Live face specs backing `faces`. Seeded with the bootstrap chain
    /// via `registerFallback`; grown as auto-fallback loads fonts. The
    /// `*const Font` pointers live for the process lifetime.
    face_specs: std.ArrayListUnmanaged(snail.Face) = .empty,
    /// Superseded `Faces` values, kept alive so stale reader pointers stay
    /// valid. Freed only in `deinit`.
    retired_faces: std.ArrayListUnmanaged(*snail.Faces) = .empty,
    /// Codepoints we've already run through the resolver (covered or not),
    /// so a permanently-uncovered glyph doesn't re-query fontconfig every
    /// frame.
    fallback_tried: std.AutoHashMapUnmanaged(u32, void) = .empty,
    /// Next stable `font_id` to assign to an auto-loaded fallback face.
    next_font_id: u32 = 0,
    /// Type-erased resolver context + fn (installed by `atlas_worker`).
    /// `resolve` returns a covering `*const Font` for a codepoint, or null.
    fallback_ctx: ?*anyopaque = null,
    fallback_resolve: ?*const fn (*anyopaque, u32) ?*const snail.Font = null,
    /// Batch resolver: covering fonts for a set of codepoints in one call
    /// (owned slice, caller frees). One `FcFontSort` for the whole miss text
    /// instead of an `FcFontMatch` per uncovered codepoint.
    fallback_resolve_batch: ?*const fn (*anyopaque, std.mem.Allocator, []const u32) []*const snail.Font = null,

    // ── Async glyph prep ──
    //
    // Glyph prep (shape + `planRuns`/prepare/apply curve extraction) is the bulk
    // of a flood frame (~60ms). It runs on a dedicated thread so the render
    // workers never block on it: they post miss text via `requestPrep` and
    // render the current atlas; newly-prepped glyphs appear a frame or two
    // later (sample-and-present, see [[render_perf]]). Only the shape step
    // needs `shape_lock` (shared hb_buffer); the heavy record step reads
    // immutable font data and runs unlocked, in parallel with render-side
    // shaping. A single-slot mailbox (latest misses win) is enough: misses
    // are re-detected every frame, so a dropped batch just reappears.
    prep_mutex: c.pthread_mutex_t = std.mem.zeroes(c.pthread_mutex_t),
    prep_cond: c.pthread_cond_t = std.mem.zeroes(c.pthread_cond_t),
    prep_thread: ?std.Thread = null,
    prep_active: bool = false,
    prep_pending: bool = false,
    prep_stop: bool = false,
    prep_len: usize = 0,
    prep_text: [glyph_misses.MaxBytes]u8 = undefined,
    /// Number of worker stripes for parallel glyph extraction. Set at
    /// `startPrep` to min(nproc, 8); the prep thread runs one stripe itself
    /// and spawns the rest per batch (prep batches are infrequent).
    prep_workers: usize = 1,
    /// One persistent `OutlineContext` per worker, reused across prep
    /// batches so per-font HarfBuzz Instances (expensive to build for large
    /// CJK variable fonts) and scratch capacity survive between batches
    /// instead of being rebuilt each time. Owned; allocated at `startPrep`,
    /// freed at `stopPrep` after the prep thread joins.
    prep_contexts: []snail.OutlineContext = &.{},
    /// eventfd the prep thread bumps on `publish` so the main loop can wake
    /// and re-render newly-prepped glyphs without polling. Stays quiet when
    /// the atlas is warm, so an idle terminal burns no CPU/GPU.
    update_fd: c_int = -1,

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
        /// Generation this snapshot's atlas represents. Captured with the
        /// snapshot so a lease-holder uploads/caches by the atlas it actually
        /// leased, not the global counter (which the async prep thread may
        /// have advanced past since the lease was taken).
        generation: u64 = 0,
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

        /// Generation of the leased atlas (stable for the lease's lifetime).
        pub fn generation(self: *const Lease) u64 {
            return self.snapshot.?.generation;
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
        snapshot.* = .{ .atlas = atlas_ptr, .generation = 1 };

        var ref: AtlasRef = .{
            .current = snapshot,
            .generation = .init(1),
            .allocator = allocator,
            .pool = pool,
            .faces = faces,
        };
        if (c.pthread_mutex_init(&ref.shape_lock, null) != 0) return error.MutexInitFailed;
        if (c.pthread_mutex_init(&ref.prep_mutex, null) != 0) return error.MutexInitFailed;
        if (c.pthread_cond_init(&ref.prep_cond, null) != 0) return error.MutexInitFailed;
        ref.update_fd = c.eventfd(0, c.EFD_NONBLOCK | c.EFD_CLOEXEC);
        return ref;
    }

    /// Read end of the update eventfd — add to the main loop's poll set; a
    /// readable fd means the atlas advanced and a re-render is due. Drain it
    /// with `drainUpdate`.
    pub fn updateFd(self: *const AtlasRef) c_int {
        return self.update_fd;
    }

    /// Drain the update eventfd after it signals (clears its counter).
    pub fn drainUpdate(self: *AtlasRef) void {
        if (self.update_fd < 0) return;
        var buf: u64 = 0;
        _ = c.read(self.update_fd, &buf, @sizeOf(u64));
    }

    fn notifyUpdate(self: *AtlasRef) void {
        if (self.update_fd < 0) return;
        const one: u64 = 1;
        _ = c.write(self.update_fd, &one, @sizeOf(u64));
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

    /// Start the async glyph-prep thread. Call once, after `faces` and the
    /// fallback resolver are set (i.e. after bootstrap).
    pub fn startPrep(self: *AtlasRef) !void {
        if (self.prep_active) return;
        // Cap at 8: enough to clear a glyph flood in a frame or two while
        // leaving cores for the render loop, GPU worker, and CPU raster pool.
        self.prep_workers = @max(1, @min(std.Thread.getCpuCount() catch 4, 8));
        self.prep_contexts = try self.allocator.alloc(snail.OutlineContext, self.prep_workers);
        for (self.prep_contexts) |*cx| cx.* = snail.OutlineContext.init(self.allocator, self.allocator);
        self.prep_active = true;
        self.prep_thread = std.Thread.spawn(.{}, prepLoop, .{self}) catch |err| {
            self.prep_active = false;
            return err;
        };
    }

    /// Signal the prep thread to exit and join it. Call before `deinit`.
    pub fn stopPrep(self: *AtlasRef) void {
        if (!self.prep_active) return;
        _ = c.pthread_mutex_lock(&self.prep_mutex);
        self.prep_stop = true;
        _ = c.pthread_cond_signal(&self.prep_cond);
        _ = c.pthread_mutex_unlock(&self.prep_mutex);
        if (self.prep_thread) |t| t.join();
        self.prep_thread = null;
        self.prep_active = false;
        // Safe now that the only user (the prep thread) has joined.
        for (self.prep_contexts) |*cx| cx.deinit();
        self.allocator.free(self.prep_contexts);
        self.prep_contexts = &.{};
    }

    /// Hand `miss_text` to the prep thread and return immediately. Single-slot
    /// mailbox: a pending batch not yet picked up is overwritten (misses are
    /// re-detected every frame, so nothing is permanently lost). No-op before
    /// `startPrep` — callers on that path get glyphs prepped once prep runs.
    pub fn requestPrep(self: *AtlasRef, miss_text: []const u8) void {
        if (!self.prep_active or miss_text.len == 0) return;
        const n = @min(miss_text.len, self.prep_text.len);
        _ = c.pthread_mutex_lock(&self.prep_mutex);
        @memcpy(self.prep_text[0..n], miss_text[0..n]);
        self.prep_len = n;
        self.prep_pending = true;
        _ = c.pthread_cond_signal(&self.prep_cond);
        _ = c.pthread_mutex_unlock(&self.prep_mutex);
    }

    fn prepLoop(self: *AtlasRef) void {
        log.info(.atlas, "prep thread running", .{});
        var work: [glyph_misses.MaxBytes]u8 = undefined;
        while (true) {
            _ = c.pthread_mutex_lock(&self.prep_mutex);
            while (!self.prep_pending and !self.prep_stop) {
                _ = c.pthread_cond_wait(&self.prep_cond, &self.prep_mutex);
            }
            if (self.prep_stop) {
                _ = c.pthread_mutex_unlock(&self.prep_mutex);
                return;
            }
            const n = self.prep_len;
            @memcpy(work[0..n], self.prep_text[0..n]);
            self.prep_pending = false;
            _ = c.pthread_mutex_unlock(&self.prep_mutex);
            self.runPrep(work[0..n]);
        }
    }

    /// Extend the current atlas to cover `miss_text`, then publish it.
    /// Runs on the prep thread. Phase A (fallback + shape) holds `shape_lock`
    /// because it touches the shared HarfBuzz buffer; Phase B (`recordUnhinted`
    /// curve extraction) reads only immutable font data, so it runs unlocked —
    /// in parallel with render-side shaping. Only the prep thread extends, so
    /// there is no concurrent page-pool mutation.
    fn runPrep(self: *AtlasRef, miss_text: []const u8) void {
        // Phase A1 — fallback coverage, UNLOCKED. Resolving/mmapping/parsing a
        // covering font and rebuilding `Faces` (per-font HarfBuzz face/shaper
        // objects) touches only immutable font data, not the shared shaping
        // buffer — so it must NOT hold shape_lock, or a single big fallback
        // load (unifont, CJK-VF, …) would block every render-side shape for
        // tens of ms and stall frames. ensureFallbackCoverage takes shape_lock
        // only for the brief `faces` pointer swap.
        _ = self.ensureFallbackCoverage(miss_text);

        // Phase A2 — shape under shape_lock (Faces has one shared hb_buffer).
        _ = c.pthread_mutex_lock(&self.shape_lock);
        const faces = self.faces orelse {
            _ = c.pthread_mutex_unlock(&self.shape_lock);
            return;
        };
        var shaped = snail.shape(self.allocator, faces, miss_text, .{}) catch {
            _ = c.pthread_mutex_unlock(&self.shape_lock);
            return;
        };
        _ = c.pthread_mutex_unlock(&self.shape_lock);
        defer shaped.deinit();

        // Phase B — clone the current atlas + record, no lock. Extraction
        // (the ~90% curve-baking cost) fans across the prep worker stripes;
        // planning (dedup) and insertion stay serial on this thread. Only the
        // prep thread extends, so there is no concurrent page-pool mutation.
        var lease = self.acquire();
        defer lease.release();
        var next = lease.get().extend(self.allocator, .{}) catch return;
        self.recordParallel(&next, faces, &shaped) catch |err| {
            if (err == error.OutOfLayers) {
                // Pool exhausted: new glyphs can't be prepped and render as
                // gaps. Warn once — sustained hits on a *real* workload (not
                // the synthetic flood) are the signal that LRU eviction is
                // worth building. See [[render_perf]].
                if (prepFullCount == 0) log.warn(.atlas, "atlas full — new glyphs dropped (raise max_layers or add eviction)", .{});
                prepFullCount += 1;
            } else prepErrCount += 1;
            next.deinit();
            return;
        };
        prepOkCount += 1;
        atlasRecords = next.recordCount();

        const heap = self.allocator.create(snail.Atlas) catch {
            next.deinit();
            return;
        };
        heap.* = next;
        self.publish(heap) catch {
            heap.deinit();
            self.allocator.destroy(heap);
        };
    }

    /// One extraction worker. Claims contiguous chunks of request indices
    /// from a shared atomic cursor — contiguous for cache locality and to
    /// avoid false sharing on the large `results[]` slots, dynamic so workers
    /// self-balance across glyphs whose extraction cost varies and clusters
    /// by script. Owns its `ExtractContext` (per-thread scratch + Instances).
    const PrepTask = struct {
        requests: []const snail.PrepareRequest,
        /// Owned prepared artifacts (freed after apply); `results` are views
        /// into them. Distinct indices are written by distinct workers, so no
        /// synchronization is needed on the slices themselves.
        owned: []?snail.prepared.OwnedRecord,
        results: []?snail.prepared.RecordView,
        ctx: *snail.OutlineContext,
        cursor: *std.atomic.Value(usize),
        err: ?anyerror = null,

        /// Chunk size trades scheduling granularity (smaller = better balance)
        /// against atomic/locality overhead. 16 gives ~cores×8 chunks over a
        /// typical flood — ample for balancing.
        const chunk: usize = 16;

        fn run(self: *PrepTask) void {
            // `ctx` is a persistent per-worker context (Instances + scratch
            // survive across batches); do not deinit it here.
            const count = self.requests.len;
            while (true) {
                const start = self.cursor.fetchAdd(chunk, .monotonic);
                if (start >= count) break;
                const end = @min(start + chunk, count);
                for (start..end) |i| {
                    // Unhinted runs are all `.outline` operations with no
                    // inter-request dependencies, so any worker can prepare any
                    // index in any order.
                    const record = self.ctx.prepare(self.requests[i]) catch |e| {
                        self.err = e;
                        return;
                    };
                    self.owned[i] = record;
                    self.results[i] = self.owned[i].?.view();
                }
            }
        }
    };

    /// A cheap, process-unique cache key per font. It feeds only the prepared
    /// artifact's archive-lookup `Key`, never the atlas `RecordKey` (which is
    /// `record_key.unhintedGlyph(font_id, glyph_id)`), and scrgo does not
    /// persist prepared archives — so uniqueness in-process is all that's
    /// required. If disk archives are ever added, switch to a content hash of
    /// the font bytes + face index + variations.
    fn fontCacheKey(spec: snail.Face) snail.prepared.FontKey {
        var key: snail.prepared.FontKey = [_]u8{0} ** 16;
        std.mem.writeInt(u32, key[0..4], spec.font_id, .little);
        std.mem.writeInt(u32, key[4..8], spec.font.faceIndex(), .little);
        return key;
    }

    /// Plan → parallel-prepare → apply. Outline preparation (the ~90% curve
    /// cost) fans across up to `prep_workers` workers (this thread runs one,
    /// spawns the rest); planning and insertion stay serial. Any prepare error
    /// aborts before `applyInPlace`, so `next` is left unchanged.
    fn recordParallel(
        self: *AtlasRef,
        next: *snail.Atlas,
        faces: *const snail.Faces,
        shaped: *const snail.ShapedText,
    ) !void {
        _ = faces; // planRuns enumerates glyphs from `shaped` by font_id.

        // FontSource selection set: every distinct font the runs may reference.
        // `planRuns` skips glyphs whose font_id isn't listed and rejects
        // duplicate ids, so dedup by font_id here.
        var sources: std.ArrayList(snail.FontSource) = .empty;
        defer sources.deinit(self.allocator);
        for (self.face_specs.items) |spec| {
            var dup = false;
            for (sources.items) |s| {
                if (s.font_id == spec.font_id) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            try sources.append(self.allocator, .{
                .font_id = spec.font_id,
                .font = spec.font,
                .cache_key = fontCacheKey(spec),
            });
        }

        var plan = try snail.planRuns(next, self.allocator, sources.items, &.{shaped}, .{ .unhinted = .{} });
        defer plan.deinit();

        const requests = plan.requests();
        const count = requests.len;
        if (count == 0) return plan.applyInPlace(self.allocator, next, &.{});

        // One owned artifact + one result view per request.
        const owned = try self.allocator.alloc(?snail.prepared.OwnedRecord, count);
        defer {
            for (owned) |*rec| if (rec.*) |*value| value.deinit();
            self.allocator.free(owned);
        }
        @memset(owned, null);
        const results = try self.allocator.alloc(?snail.prepared.RecordView, count);
        defer self.allocator.free(results);
        @memset(results, null);

        const n = @max(1, @min(self.prep_workers, count));
        var cursor = std.atomic.Value(usize).init(0);
        const tasks = try self.allocator.alloc(PrepTask, n);
        defer self.allocator.free(tasks);
        const threads = try self.allocator.alloc(?std.Thread, n);
        defer self.allocator.free(threads);
        for (tasks, 0..) |*t, ti| t.* = .{
            .requests = requests,
            .owned = owned,
            .results = results,
            .ctx = &self.prep_contexts[ti],
            .cursor = &cursor,
        };

        // Spawn workers 1..n; run worker 0 on this thread. A failed spawn just
        // runs that worker inline here — parallelism is best-effort, and all
        // workers pull from the same cursor so nothing is skipped.
        for (1..n) |ti| {
            threads[ti] = std.Thread.spawn(.{}, PrepTask.run, .{&tasks[ti]}) catch blk: {
                PrepTask.run(&tasks[ti]);
                break :blk null;
            };
        }
        PrepTask.run(&tasks[0]);
        for (1..n) |ti| if (threads[ti]) |th| th.join();

        for (tasks) |t| if (t.err) |e| return e;
        try plan.applyInPlace(self.allocator, next, results);
    }

    /// Seed the auto-fallback machinery with the bootstrap chain and the
    /// resolver used to load covering fonts on demand. `specs` is copied
    /// (the borrowed `*const Font` pointers must outlive the process, as
    /// they already do). Call once, at bootstrap, before any rendering.
    pub fn registerFallback(
        self: *AtlasRef,
        specs: []const snail.Face,
        ctx: *anyopaque,
        resolve: *const fn (*anyopaque, u32) ?*const snail.Font,
        resolve_batch: *const fn (*anyopaque, std.mem.Allocator, []const u32) []*const snail.Font,
    ) !void {
        try self.face_specs.appendSlice(self.allocator, specs);
        var max_id: u32 = 0;
        for (specs) |s| max_id = @max(max_id, s.font_id);
        self.next_font_id = if (specs.len == 0) 0 else max_id + 1;
        self.fallback_ctx = ctx;
        self.fallback_resolve = resolve;
        self.fallback_resolve_batch = resolve_batch;
    }

    /// True if any live face has a real glyph for `cp`. Checked against
    /// `face_specs` (not `faces`) so fonts appended earlier in the same
    /// `ensureFallbackCoverage` pass count immediately.
    fn coversCodepoint(self: *const AtlasRef, cp: u21) bool {
        for (self.face_specs.items) |s| {
            const gid = s.font.glyphIndex(cp) catch continue;
            if (gid != 0) return true;
        }
        return false;
    }

    /// Load covering fonts for any uncovered codepoint in `miss_text` and,
    /// if at least one was added, rebuild `faces`. Runs UNLOCKED — the heavy
    /// resolve/parse/`Faces.build` only touches immutable font data and fresh
    /// per-font hb objects — and grabs `shape_lock` solely for the final
    /// pointer swap (render-side shaping reads `self.faces` under that lock).
    /// Best-effort: resolver / build failures leave the existing chain intact.
    /// Only the prep thread calls this, so `face_specs` needs no lock.
    /// Returns true when `faces` was swapped.
    fn ensureFallbackCoverage(self: *AtlasRef, miss_text: []const u8) bool {
        const resolve_batch = self.fallback_resolve_batch orelse return false;
        const ctx = self.fallback_ctx.?;

        const base_len = self.face_specs.items.len;
        const base_next = self.next_font_id;

        // Collect the distinct codepoints no current face covers. `fallback_tried`
        // dedups across calls and within this one, and marks each attempted so a
        // glyph no installed font carries doesn't re-resolve every frame.
        var uncovered: std.ArrayList(u32) = .empty;
        defer uncovered.deinit(self.allocator);
        var view = std.unicode.Utf8View.init(miss_text) catch return false;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp <= 0x20) continue; // run separators / control
            if (self.fallback_tried.contains(cp)) continue;
            self.fallback_tried.put(self.allocator, cp, {}) catch {};
            if (self.coversCodepoint(cp)) continue;
            uncovered.append(self.allocator, cp) catch {};
        }
        if (uncovered.items.len == 0) return false;

        // One batched fontconfig sort for the whole set, instead of a match
        // per codepoint. Append each covering font once (deduped by pointer).
        const fonts = resolve_batch(ctx, self.allocator, uncovered.items);
        defer self.allocator.free(fonts);
        for (fonts) |font| {
            var dup = false;
            for (self.face_specs.items) |s| {
                if (s.font == font) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            self.face_specs.append(self.allocator, .{
                .font = font,
                .font_id = self.next_font_id,
                .fallback = true,
            }) catch continue;
            self.next_font_id += 1;
        }

        if (self.face_specs.items.len == base_len) return false;

        const new_faces = self.allocator.create(snail.Faces) catch {
            self.face_specs.items.len = base_len;
            self.next_font_id = base_next;
            return false;
        };
        new_faces.* = snail.Faces.build(self.allocator, self.face_specs.items) catch {
            self.allocator.destroy(new_faces);
            self.face_specs.items.len = base_len;
            self.next_font_id = base_next;
            return false;
        };

        // Publish under shape_lock: render-side shaping reads `self.faces`
        // under the same lock, so the swap can't race a live shaper, and the
        // retired Faces is out of use past this point (freed only at deinit).
        // Only the pointer swap is locked; the Faces.build above ran unlocked.
        _ = c.pthread_mutex_lock(&self.shape_lock);
        if (self.faces) |old| self.retired_faces.append(self.allocator, old) catch {};
        self.faces = new_faces;
        _ = c.pthread_mutex_unlock(&self.shape_lock);
        return true;
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
        const entry = snail.AtlasEntry{ .geometry = .{
            .key = key,
            .curves = curves.view(),
            .paint = try prep.paintForDesign(.{ .solid = .{ 1, 1, 1, 1 } }),
        } };

        self.lock();
        defer self.unlock();
        try self.current.?.atlas.extendInPlace(alloc, .{ .entries = &.{entry} });
        self.rect_key = key;
        self.rect_xform = prep.design_to_source;
        self.has_rect = true;
        self.current.?.generation = self.generation.fetchAdd(1, .release) + 1;
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
            const entry = snail.AtlasEntry{ .geometry = .{
                .key = key,
                .curves = curves.view(),
                .paint = try prep.paintForDesign(.{ .solid = .{ 1, 1, 1, 1 } }),
            } };

            {
                self.lock();
                defer self.unlock();
                try self.current.?.atlas.extendInPlace(alloc, .{ .entries = &.{entry} });
                self.current.?.generation = self.generation.fetchAdd(1, .release) + 1;
            }
            self.powerline.set(cp, .{ .key = key, .xform = prep.design_to_source });
        }
    }

    /// Publish a new snapshot, retiring the old one.
    pub fn publish(self: *AtlasRef, next: *snail.Atlas) !void {
        const next_snapshot = try self.allocator.create(Snapshot);
        errdefer self.allocator.destroy(next_snapshot);

        self.lock();
        defer self.unlock();

        // fetchAdd returns the prior value; the new generation is +1.
        const new_gen = self.generation.fetchAdd(1, .release) + 1;
        next_snapshot.* = .{ .atlas = next, .generation = new_gen };
        const old = self.current;
        self.current = next_snapshot;
        if (old) |snapshot| self.retireLocked(snapshot);
        self.notifyUpdate();
    }

    /// Clean up all held snapshots. Call only when no threads are reading.
    pub fn deinit(self: *AtlasRef) void {
        // Stop the prep thread first — it publishes/retires snapshots and
        // must not race the teardown below.
        self.stopPrep();
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
        // Free the auto-fallback bookkeeping. Retired `Faces` are ours to
        // destroy (the bootstrap `Faces`, once superseded, lands here too);
        // the current `faces` and every borrowed `Font` leak by design, as
        // the process exits via `_exit`.
        for (self.retired_faces.items) |f| {
            f.deinit();
            self.allocator.destroy(f);
        }
        self.retired_faces.deinit(self.allocator);
        self.face_specs.deinit(self.allocator);
        self.fallback_tried.deinit(self.allocator);
        _ = c.pthread_mutex_destroy(&self.shape_lock);
        _ = c.pthread_cond_destroy(&self.prep_cond);
        _ = c.pthread_mutex_destroy(&self.prep_mutex);
        if (self.update_fd >= 0) _ = c.close(self.update_fd);
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
