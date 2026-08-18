const std = @import("std");
const snail = @import("snail");
const powerline = @import("powerline_glyphs.zig");
const bitmap_glyphs = @import("bitmap_glyphs.zig");
const png_decode = @import("png_decode.zig");
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

    // ── Async glyph prep (two-stage pipeline) ──
    //
    // Glyph prep is the bulk of a flood frame (~60ms), so it runs off the
    // render workers: they post miss text via `requestPrep` and render the
    // current atlas; newly-prepped glyphs appear a frame or two later
    // (sample-and-present, see [[render_perf]]). Prep itself is split across
    // two threads so the next batch bakes while the current one commits:
    //
    //   extract thread (`prepLoop`) — shape + plan + bake curves. Reads only
    //     immutable font data + the current atlas snapshot; never mutates the
    //     shared atlas/page pool. The ~90% cost, fanned across `prep_workers`.
    //   apply thread (`applyLoop`) — extend the freshest atlas with the baked
    //     records + publish. The only page-pool mutator; the ~10% cost.
    //
    // The two touch disjoint state, so they overlap safely, and the extract
    // workers no longer idle behind the serial commit. Legality: a baked batch
    // is welded to the atlas it was planned against only by snail's
    // `required_records` ("must still contain these keys"); since `extend` only
    // adds keys, a plan built against snapshot N applies cleanly onto N+1, and
    // resident keys are skipped idempotently — so the apply thread always
    // targets the latest snapshot regardless of which one extract planned on.
    //
    // Only the shape step needs `shape_lock` (shared hb_buffer). The input
    // mailbox is single-slot (latest misses win): misses are re-detected every
    // frame, so a dropped batch just reappears.
    prep_mutex: c.pthread_mutex_t = std.mem.zeroes(c.pthread_mutex_t),
    prep_cond: c.pthread_cond_t = std.mem.zeroes(c.pthread_cond_t),
    prep_thread: ?std.Thread = null,
    prep_active: bool = false,
    prep_pending: bool = false,
    prep_stop: bool = false,
    prep_len: usize = 0,
    prep_text: [glyph_misses.MaxBytes]u8 = undefined,
    /// Warm-fallback mailbox: raw PTY text fed straight from the reader thread
    /// so covering fonts start loading the moment content arrives, in parallel
    /// with the first frame — instead of waiting for a frame to build and
    /// detect misses. The prep thread runs only `ensureFallbackCoverage` on it
    /// (no shape/prep), so escape-sequence bytes are harmless (ASCII → no
    /// fallback). Separate slot from `prep_text`; latest wins.
    warm_pending: bool = false,
    warm_len: usize = 0,
    warm_text: [glyph_misses.MaxBytes]u8 = undefined,
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
    /// Per-worker TrueType hint state (one per `prep_contexts` slot). Each
    /// holds a `TtHintContext` bound to the primary face plus a cached per-ppem
    /// `TtHintSize`. Allocated at `startPrep`; the `TtHintContext`s are only
    /// initialised when `tt_hint_supported`. Freed at `stopPrep`.
    tt_workers: []TtWorker = &.{},
    /// Stable primary `FontSource` (font_id 0) the per-worker `TtHintContext`s
    /// borrow (its `check()` compares against this). Set at `startPrep`.
    tt_source: snail.FontSource = undefined,
    /// Whether the primary face can be TT-hinted (static TrueType, no
    /// variations). Probed once at `startPrep` via `TtHintVm.init`; immutable
    /// after. When false, `tt_hint` is inert.
    tt_hint_supported: bool = false,
    /// Runtime kill-switch: set if the TT prep plan ever fails to bake (a font
    /// the probe accepted but whose glyphs snail can't hint). Reverts the render
    /// path to unhinted (always-resident) keys so hinting can never leave a row
    /// permanently missing — the font stays usable, just unhinted. Written by
    /// the prep thread, read by the render path, so atomic.
    tt_hint_failed: std.atomic.Value(bool) = .init(false),
    /// Live TrueType-hint toggle for the primary face. Read each pass by the
    /// render path (`row_build`) and the prep thread; flipped by the palette
    /// command. Initial state from config (`main` seeds it). Effective only
    /// when `tt_hint_supported`. Fallback faces always render unhinted.
    tt_hint: std.atomic.Value(bool) = .init(false),
    /// eventfd the apply thread bumps on `publish` so the main loop can wake
    /// and re-render newly-prepped glyphs without polling. Stays quiet when
    /// the atlas is warm, so an idle terminal burns no CPU/GPU.
    update_fd: c_int = -1,

    /// Apply-stage handoff: the extract thread hands one baked `ExtractedBatch`
    /// to the apply thread here. Single-slot and back-pressured — the extract
    /// thread blocks in `submitApply` while a batch is still un-applied. Since
    /// the apply stage is far cheaper than extraction it is near-always idle,
    /// so this rarely blocks and nothing is dropped.
    apply_mutex: c.pthread_mutex_t = std.mem.zeroes(c.pthread_mutex_t),
    apply_cond: c.pthread_cond_t = std.mem.zeroes(c.pthread_cond_t),
    apply_thread: ?std.Thread = null,
    apply_stop: bool = false,
    apply_pending: ?ExtractedBatch = null,

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

    /// Baked color-bitmap (emoji) glyph records, keyed by (font, glyph, ppem).
    /// Unlike `powerline`, populated lazily by the prep/apply threads as strikes
    /// are decoded; every access is serialized by `shape_lock`. See
    /// [[custom_glyphs]] / `bitmap_glyphs.zig`.
    bitmaps: bitmap_glyphs.Table = .{},
    /// Current device ppem for bitmap-strike selection, = round(font_size).
    /// Published each frame by `buildSnapshot` (font size changes with zoom),
    /// read by the prep thread's `bakeBitmaps`. Zero until the first frame.
    bitmap_ppem: std.atomic.Value(u16) = .init(0),

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

    /// A decoded emoji strike awaiting commit. The extract thread decodes the
    /// PNG and prepares the em-bbox rect geometry (heavy work, off the apply
    /// thread); the apply thread extends the atlas with it and records the
    /// table entry. Owns the decoded image + prepared geometry until committed.
    const BitmapBake = struct {
        id: bitmap_glyphs.Id,
        /// Heap-allocated decoded texels, stable so the paint and the atlas can
        /// borrow its address. Ownership passes to `bitmaps` on a successful
        /// commit (set null then); otherwise `deinit` frees it.
        image: ?*snail.Image,
        /// Em-space rect over the strike's placement box; source of the
        /// design→source placement and the fill curves. Freed after commit.
        prep: snail.PreparedPath,
        curves: snail.GlyphCurves,
        /// Strike placement box in em space (drives the image UV transform).
        bbox: snail.BBox,

        fn deinit(self: *BitmapBake, allocator: std.mem.Allocator) void {
            self.curves.deinit();
            self.prep.deinit();
            if (self.image) |image| {
                image.deinit();
                allocator.destroy(image);
            }
        }
    };

    /// One miss batch's baked glyph records, produced by the extract stage and
    /// consumed by the apply stage. `results` are views into `owned`; `plan`
    /// carries the insert recipe and the required-record weld (null for a
    /// bitmaps-only batch — e.g. a font-size change whose outlines are already
    /// resident). Freed by `deinit` once the apply stage has committed (or
    /// dropped) it.
    const ExtractedBatch = struct {
        plan: ?snail.PreparePlan,
        owned: []?snail.prepared.OwnedRecord,
        results: []?snail.prepared.RecordView,
        allocator: std.mem.Allocator,
        /// Decoded emoji strikes to commit alongside the outlines. `applyBatch`
        /// consumes this and empties it; on the drop path `deinit` frees it.
        bitmaps: []BitmapBake = &.{},

        fn deinit(self: *ExtractedBatch) void {
            for (self.owned) |*rec| if (rec.*) |*view| view.deinit();
            if (self.owned.len > 0) self.allocator.free(self.owned);
            if (self.results.len > 0) self.allocator.free(self.results);
            if (self.plan) |*plan| plan.deinit();
            for (self.bitmaps) |*bake| bake.deinit(self.allocator);
            if (self.bitmaps.len > 0) self.allocator.free(self.bitmaps);
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
        if (c.pthread_mutex_init(&ref.apply_mutex, null) != 0) return error.MutexInitFailed;
        if (c.pthread_cond_init(&ref.apply_cond, null) != 0) return error.MutexInitFailed;
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

    /// Publish the current device ppem (= round(font_size)) for the prep
    /// thread's bitmap-strike selection. Called by the render pipelines each
    /// frame, since the font size changes with zoom. Lock-free.
    pub fn setBitmapPpem(self: *AtlasRef, ppem: u16) void {
        self.bitmap_ppem.store(ppem, .monotonic);
    }

    /// The font backing `font_id`, or null. `face_specs` is small and mutated
    /// only by the extract thread under `shape_lock`; call this holding
    /// `shape_lock` (the render path does, across `buildSnapshot`).
    pub fn fontForId(self: *const AtlasRef, font_id: u32) ?*const snail.Font {
        for (self.face_specs.items) |spec| {
            if (spec.font_id == font_id) return spec.font;
        }
        return null;
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
        // Glyph extraction is memory-bandwidth-bound, not core-bound: past ~8
        // workers throughput barely rises AND the workers starve the render
        // (the CPU raster's full-surface clear + the GPU's init pound the same
        // bus). So cap modestly by default. Override with SCRGO_PREP_WORKERS to
        // probe the knee on a given machine. Clamped to the core count.
        const cpu = std.Thread.getCpuCount() catch 4;
        var workers: usize = @min(cpu, 8);
        if (std.c.getenv("SCRGO_PREP_WORKERS")) |env| {
            if (std.fmt.parseInt(usize, std.mem.sliceTo(env, 0), 10) catch null) |v| {
                if (v > 0) workers = @min(cpu, v);
            }
        }
        self.prep_workers = @max(1, workers);
        log.info(.atlas, "prep workers", .{ .workers = self.prep_workers, .cores = cpu });
        self.prep_contexts = try self.allocator.alloc(snail.OutlineContext, self.prep_workers);
        for (self.prep_contexts) |*cx| cx.* = snail.OutlineContext.init(self.allocator, self.allocator);

        // Probe the primary face (font_id 0) for TT-hint support and, if it has
        // it, build a stable FontSource plus one TtHintContext per worker. The
        // VM rejects non-static-TrueType faces (CFF/variable) with NoHinting, in
        // which case `tt_hint` stays inert and every glyph renders unhinted.
        self.tt_workers = try self.allocator.alloc(TtWorker, self.prep_workers);
        for (self.tt_workers) |*w| w.* = .{};
        self.tt_hint_supported = false;
        if (self.primaryFace()) |spec| {
            self.tt_source = .{
                .font_id = spec.font_id,
                .font = spec.font,
                .cache_key = fontCacheKey(spec),
            };
            if (snail.TtHintVm.init(self.allocator, spec.font)) |vm_probe| {
                var probe = vm_probe;
                probe.deinit();
                self.tt_hint_supported = true;
                for (self.tt_workers) |*w| {
                    w.ctx = snail.TtHintContext.init(self.allocator, self.allocator, &self.tt_source) catch null;
                    if (w.ctx == null) {
                        // Init should not fail after a successful probe, but if
                        // it does, disable hinting rather than half-arm it.
                        self.tt_hint_supported = false;
                        break;
                    }
                }
            } else |_| {}
        }
        log.info(.atlas, "tt hinting", .{ .supported = self.tt_hint_supported });

        self.prep_active = true;
        // Apply thread first so it's ready to consume the extract thread's
        // first handoff.
        self.apply_stop = false;
        self.apply_thread = std.Thread.spawn(.{}, applyLoop, .{self}) catch |err| {
            self.prep_active = false;
            return err;
        };
        self.prep_thread = std.Thread.spawn(.{}, prepLoop, .{self}) catch |err| {
            // Unwind the apply thread we already started.
            _ = c.pthread_mutex_lock(&self.apply_mutex);
            self.apply_stop = true;
            _ = c.pthread_cond_broadcast(&self.apply_cond);
            _ = c.pthread_mutex_unlock(&self.apply_mutex);
            if (self.apply_thread) |t| t.join();
            self.apply_thread = null;
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
        // Wake the apply thread and any extract thread parked in `submitApply`
        // waiting for the handoff slot (broadcast: both may be waiting).
        _ = c.pthread_mutex_lock(&self.apply_mutex);
        self.apply_stop = true;
        _ = c.pthread_cond_broadcast(&self.apply_cond);
        _ = c.pthread_mutex_unlock(&self.apply_mutex);
        if (self.prep_thread) |t| t.join();
        self.prep_thread = null;
        if (self.apply_thread) |t| t.join();
        self.apply_thread = null;
        self.prep_active = false;
        // Safe now that the only user (the extract thread) has joined.
        for (self.prep_contexts) |*cx| cx.deinit();
        self.allocator.free(self.prep_contexts);
        self.prep_contexts = &.{};
        for (self.tt_workers) |*w| w.deinit();
        self.allocator.free(self.tt_workers);
        self.tt_workers = &.{};
        self.tt_hint_supported = false;
    }

    /// The primary face (font_id 0, the configured monospace font) if present.
    fn primaryFace(self: *const AtlasRef) ?snail.Face {
        for (self.face_specs.items) |spec| {
            if (spec.font_id == 0) return spec;
        }
        return null;
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

    /// Warm covering fonts for the codepoints in `text` ahead of the render
    /// path. Called from the PTY reader with each fresh chunk of raw output,
    /// so fontconfig resolution + font mmap/parse overlap the first frame
    /// rather than waiting for miss detection. Only the fallback-coverage step
    /// runs on this text (no shape/prep), so escape/control bytes cost
    /// nothing. Single-slot, latest-wins; no-op before `startPrep`.
    pub fn requestWarmFallback(self: *AtlasRef, text: []const u8) void {
        if (!self.prep_active or text.len == 0) return;
        const n = @min(text.len, self.warm_text.len);
        _ = c.pthread_mutex_lock(&self.prep_mutex);
        @memcpy(self.warm_text[0..n], text[0..n]);
        self.warm_len = n;
        self.warm_pending = true;
        _ = c.pthread_cond_signal(&self.prep_cond);
        _ = c.pthread_mutex_unlock(&self.prep_mutex);
    }

    fn prepLoop(self: *AtlasRef) void {
        log.info(.atlas, "prep thread running", .{});
        var work: [glyph_misses.MaxBytes]u8 = undefined;
        var warm_work: [glyph_misses.MaxBytes]u8 = undefined;
        while (true) {
            _ = c.pthread_mutex_lock(&self.prep_mutex);
            while (!self.prep_pending and !self.warm_pending and !self.prep_stop) {
                _ = c.pthread_cond_wait(&self.prep_cond, &self.prep_mutex);
            }
            if (self.prep_stop) {
                _ = c.pthread_mutex_unlock(&self.prep_mutex);
                return;
            }
            const warm_have = self.warm_pending;
            const warm_n = self.warm_len;
            if (warm_have) {
                @memcpy(warm_work[0..warm_n], self.warm_text[0..warm_n]);
                self.warm_pending = false;
            }
            const prep_have = self.prep_pending;
            const prep_n = self.prep_len;
            if (prep_have) {
                @memcpy(work[0..prep_n], self.prep_text[0..prep_n]);
                self.prep_pending = false;
            }
            _ = c.pthread_mutex_unlock(&self.prep_mutex);

            // Warm covering fonts first so the subsequent prep (and any
            // render-side reshape) sees the coverage. `ensureFallbackCoverage`
            // dedups via `fallback_tried`, so this is ~free once warm.
            if (warm_have) _ = self.ensureFallbackCoverage(warm_work[0..warm_n]);
            if (prep_have) {
                if (self.extractBatch(work[0..prep_n])) |batch| self.submitApply(batch);
            }
        }
    }

    /// Extract stage (prep thread): shape `miss_text`, then plan + bake its
    /// glyph curves against the current snapshot. Reads only immutable font
    /// data + the atlas HAMT; it does NOT extend the atlas or touch the page
    /// pool — that is the apply thread's job. Returns the baked batch, or null
    /// when there is nothing to commit (shape failed, or every glyph is
    /// already resident).
    fn extractBatch(self: *AtlasRef, miss_text: []const u8) ?ExtractedBatch {
        // Phase A1 — fallback coverage, UNLOCKED. Resolving/mmapping/parsing a
        // covering font and rebuilding `Faces` (per-font HarfBuzz face/shaper
        // objects) touches only immutable font data, not the shared shaping
        // buffer — so it must NOT hold shape_lock, or a single big fallback
        // load (unifont, CJK-VF, …) would block every render-side shape for
        // tens of ms and stall frames. ensureFallbackCoverage takes shape_lock
        // only for the brief `faces` pointer swap. Only the extract thread
        // mutates `face_specs`/`faces`, so the subsequent plan sees a stable set.
        _ = self.ensureFallbackCoverage(miss_text);

        // Phase A2 — shape under shape_lock (Faces has one shared hb_buffer).
        _ = c.pthread_mutex_lock(&self.shape_lock);
        const faces = self.faces orelse {
            _ = c.pthread_mutex_unlock(&self.shape_lock);
            return null;
        };
        var shaped = snail.shape(self.allocator, faces, miss_text, .{}) catch {
            _ = c.pthread_mutex_unlock(&self.shape_lock);
            return null;
        };
        _ = c.pthread_mutex_unlock(&self.shape_lock);
        defer shaped.deinit();

        // Phase B — plan + bake curves against the current snapshot, no lock.
        // Extraction (the ~90% cost) fans across the prep worker stripes.
        var lease = self.acquire();
        defer lease.release();

        // Unhinted plan over every font — always runs, so any cell we leave
        // unhinted (all fallback glyphs, and primary glyphs when hinting is off)
        // always has a resident record.
        var all_sources: std.ArrayList(snail.FontSource) = .empty;
        defer all_sources.deinit(self.allocator);
        self.buildAllSources(&all_sources) catch {};
        var outline: ?ExtractedBatch = self.planAndExtract(lease.get(), &shaped, all_sources.items, .{ .unhinted = .{} }, false) catch blk: {
            prepErrCount += 1;
            break :blk null;
        };

        // TrueType plan for the primary face only, when hinting is effective.
        // Submitted as its own batch here (freshest-complete holds any row until
        // both its unhinted and hinted records land). ppem = round(font_size),
        // matching the render path's `ttHintedGlyph` key + placement scale.
        if (self.ttEffective()) {
            const ppem_px = self.bitmap_ppem.load(.monotonic);
            if (ppem_px != 0) {
                const ppem = snail.TtHintPpem.uniform(@as(u32, ppem_px) << 6);
                const tt_sources = [_]snail.FontSource{self.tt_source};
                const tt_batch: ?ExtractedBatch = self.planAndExtract(lease.get(), &shaped, &tt_sources, .{ .tt_hint = ppem }, true) catch blk: {
                    // A font the probe accepted but that snail can't actually
                    // hint. Disable hinting for the session so the render path
                    // reverts to the always-resident unhinted keys — the font
                    // stays fully usable, just unhinted. Warn once.
                    prepErrCount += 1;
                    if (!self.tt_hint_failed.swap(true, .monotonic)) {
                        log.warn(.atlas, "tt hinting disabled: primary face failed to bake, rendering unhinted", .{});
                    }
                    break :blk null;
                };
                if (tt_batch) |b| self.submitApply(b);
            }
        }

        // Phase C — decode any color-bitmap (emoji) strikes in this run. Runs
        // independently of outline residency: a font-size change needs a fresh
        // record at the new ppem even when the outline is already resident.
        const bitmaps = self.bakeBitmaps(faces, &shaped);

        if (outline == null and bitmaps.len == 0) return null;
        if (outline) |*b| {
            b.bitmaps = bitmaps;
            return b.*;
        }
        // Bitmaps-only: a plan-less batch the apply thread commits by extending
        // the freshest snapshot directly.
        return ExtractedBatch{
            .plan = null,
            .owned = &.{},
            .results = &.{},
            .allocator = self.allocator,
            .bitmaps = bitmaps,
        };
    }

    /// Decode every color-bitmap strike referenced by `shaped` that isn't
    /// already baked at the current ppem, returning them for the apply thread
    /// to commit. `Font.colorBitmap` reads shared HarfBuzz font state, so strike
    /// discovery runs under `shape_lock`; the heavier PNG decode + geometry prep
    /// run unlocked. Returns an empty slice when there is nothing to bake (the
    /// common warm path) or on any allocation failure.
    fn bakeBitmaps(self: *AtlasRef, faces: *snail.Faces, shaped: *const snail.ShapedText) []BitmapBake {
        const ppem = self.bitmap_ppem.load(.monotonic);
        if (ppem == 0) return &.{};

        // Under shape_lock: fetch encoded strikes for glyphs not yet resident at
        // this ppem, deduped. Also mark strike-bearing glyphs so miss detection
        // can re-request a bake after a ppem change without re-querying here.
        const Candidate = struct { id: bitmap_glyphs.Id, strike: snail.font.color_bitmap.ColorBitmap };
        var cands: std.ArrayListUnmanaged(Candidate) = .empty;
        defer cands.deinit(self.allocator);

        _ = c.pthread_mutex_lock(&self.shape_lock);
        for (shaped.glyphs) |g| {
            const id = bitmap_glyphs.Id{ .font_id = g.font_id, .glyph_id = g.glyph_id, .ppem = ppem };
            if (self.bitmaps.isResident(id)) continue;
            var dup = false;
            for (cands.items) |ca| if (std.meta.eql(ca.id, id)) {
                dup = true;
                break;
            };
            if (dup) continue;
            const font = faces.fontForFace(g.face_index) orelse continue;
            const strike = (font.colorBitmap(self.allocator, g.glyph_id, ppem) catch continue) orelse continue;
            self.bitmaps.markStrike(self.allocator, g.font_id, g.glyph_id);
            cands.append(self.allocator, .{ .id = id, .strike = strike }) catch {
                var s = strike;
                s.deinit();
                break;
            };
        }
        _ = c.pthread_mutex_unlock(&self.shape_lock);
        if (cands.items.len == 0) return &.{};

        // Unlocked: decode each PNG + prepare its em-bbox rect geometry.
        var bakes: std.ArrayListUnmanaged(BitmapBake) = .empty;
        for (cands.items) |*ca| {
            var strike = ca.strike;
            defer strike.deinit();
            const bake = self.prepareBitmap(ca.id, &strike) orelse continue;
            bakes.append(self.allocator, bake) catch {
                var b = bake;
                b.deinit(self.allocator);
                break;
            };
        }
        return bakes.toOwnedSlice(self.allocator) catch &.{};
    }

    /// Decode one strike and build its em-bbox rect geometry. Returns null (and
    /// leaves nothing allocated) on any decode/prepare failure; the caller still
    /// owns `strike`.
    fn prepareBitmap(self: *AtlasRef, id: bitmap_glyphs.Id, strike: *snail.font.color_bitmap.ColorBitmap) ?BitmapBake {
        const alloc = self.allocator;
        const bb = strike.bbox;

        var path = snail.Path.init(alloc);
        defer path.deinit();
        path.addRect(.{ .x = bb.min.x, .y = bb.min.y, .w = bb.max.x - bb.min.x, .h = bb.max.y - bb.min.y }) catch return null;

        var prep = path.prepare(alloc) catch return null;
        errdefer prep.deinit();
        var curves = prep.fillCurves(alloc, alloc) catch return null;
        errdefer curves.deinit();

        // Decode last, onto a stable heap address the paint + atlas will borrow.
        const image = alloc.create(snail.Image) catch return null;
        errdefer alloc.destroy(image);
        image.* = png_decode.decoder.decodeImage(strike.format, strike.data, alloc) catch return null;

        return BitmapBake{ .id = id, .image = image, .prep = prep, .curves = curves, .bbox = bb };
    }

    /// Hand a baked batch to the apply thread. Single-slot and back-pressured:
    /// blocks only while the previous batch is still un-applied — rare, since
    /// applying is far cheaper than extraction. Drops (frees) the batch if the
    /// prep threads are being torn down.
    fn submitApply(self: *AtlasRef, batch: ExtractedBatch) void {
        _ = c.pthread_mutex_lock(&self.apply_mutex);
        while (self.apply_pending != null and !self.apply_stop) {
            _ = c.pthread_cond_wait(&self.apply_cond, &self.apply_mutex);
        }
        if (self.apply_stop) {
            _ = c.pthread_mutex_unlock(&self.apply_mutex);
            var b = batch;
            b.deinit();
            return;
        }
        self.apply_pending = batch;
        _ = c.pthread_cond_signal(&self.apply_cond);
        _ = c.pthread_mutex_unlock(&self.apply_mutex);
    }

    /// Apply stage. Consumes baked batches from `submitApply` and commits each
    /// onto the freshest atlas, running concurrently with the extract thread's
    /// work on the next batch.
    fn applyLoop(self: *AtlasRef) void {
        log.info(.atlas, "apply thread running", .{});
        while (true) {
            _ = c.pthread_mutex_lock(&self.apply_mutex);
            while (self.apply_pending == null and !self.apply_stop) {
                _ = c.pthread_cond_wait(&self.apply_cond, &self.apply_mutex);
            }
            if (self.apply_stop) {
                const leftover = self.apply_pending;
                self.apply_pending = null;
                _ = c.pthread_mutex_unlock(&self.apply_mutex);
                if (leftover) |batch| {
                    var b = batch;
                    b.deinit();
                }
                return;
            }
            const batch = self.apply_pending.?;
            self.apply_pending = null;
            // Wake the extract thread if it's parked waiting for the slot.
            _ = c.pthread_cond_signal(&self.apply_cond);
            _ = c.pthread_mutex_unlock(&self.apply_mutex);
            self.applyBatch(batch);
        }
    }

    /// Commit a baked batch: extend the freshest atlas with its records and
    /// publish. The sole page-pool mutator once prep is running. Resident keys
    /// (added by an intervening batch) are skipped idempotently by snail, so
    /// planning against an older snapshot than we commit onto is harmless.
    fn applyBatch(self: *AtlasRef, batch: ExtractedBatch) void {
        var b = batch;
        defer b.deinit();

        var lease = self.acquire();
        defer lease.release();

        // Outline commit: apply the plan, or (bitmaps-only batch) take a fresh
        // snapshot of the freshest atlas to extend the strikes onto.
        var next = if (b.plan) |*plan|
            plan.apply(self.allocator, lease.get(), b.results) catch |err| {
                if (err == error.OutOfLayers) {
                    // Pool exhausted: new glyphs can't be prepped and render as
                    // gaps. Warn once — sustained hits on a *real* workload (not
                    // the synthetic flood) are the signal that LRU eviction is
                    // worth building. See [[render_perf]].
                    if (prepFullCount == 0) log.warn(.atlas, "atlas full — new glyphs dropped (raise max_layers or add eviction)", .{});
                    prepFullCount += 1;
                } else prepErrCount += 1;
                return;
            }
        else
            lease.get().extend(self.allocator, .{}) catch {
                prepErrCount += 1;
                return;
            };

        // Emoji strikes ride onto the same snapshot as image-painted records.
        self.commitBitmaps(&next, &b);

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

    /// Extend `next` with the batch's decoded emoji strikes and record them in
    /// the render-side `bitmaps` table. Each strike becomes an image-painted
    /// em-bbox rect keyed by `colorBitmapGlyph(font, glyph, ppem)`; its decoded
    /// texels move to a heap `snail.Image` the atlas borrows for the process
    /// lifetime. Consumes `b.bitmaps` (emptied on return so the caller's
    /// `deinit` won't double-free). Best-effort: a failed extend drops the whole
    /// group; a failed table insert drops just that glyph.
    fn commitBitmaps(self: *AtlasRef, next: *snail.Atlas, b: *ExtractedBatch) void {
        if (b.bitmaps.len == 0) return;
        const alloc = self.allocator;
        defer {
            // Geometry is copied into the atlas at extend time; images are
            // transferred (image == null) or freed by `deinit`. Drop the slice.
            for (b.bitmaps) |*bake| bake.deinit(alloc);
            alloc.free(b.bitmaps);
            b.bitmaps = &.{};
        }

        // Build the image-painted entries; `committed[i]` maps an entry back to
        // its bake so we can transfer the image once the extend succeeds.
        var entries: std.ArrayListUnmanaged(snail.AtlasEntry) = .empty;
        defer entries.deinit(alloc);
        var committed: std.ArrayListUnmanaged(usize) = .empty;
        defer committed.deinit(alloc);
        entries.ensureTotalCapacity(alloc, b.bitmaps.len) catch return;
        committed.ensureTotalCapacity(alloc, b.bitmaps.len) catch return;

        for (b.bitmaps, 0..) |*bake, i| {
            const source_paint = snail.Paint{ .image = .{
                .image = bake.image.?,
                .uv_transform = snail.font.color_bitmap.imageUvTransform(bake.bbox),
                .filter = .nearest,
            } };
            const paint = bake.prep.paintForDesign(source_paint) catch continue;
            const key = snail.record_key.colorBitmapGlyph(bake.id.font_id, bake.id.glyph_id, bake.id.ppem);
            entries.append(alloc, .{ .geometry = .{
                .key = key,
                .curves = bake.curves.view(),
                .paint = paint,
            } }) catch continue;
            committed.append(alloc, i) catch {
                _ = entries.pop();
                continue;
            };
        }
        if (entries.items.len == 0) return;

        // On failure `next` is logically unchanged (the images were never
        // borrowed), so leave them owned by the bakes for `deinit` to free.
        next.extendInPlace(alloc, .{ .entries = entries.items }) catch return;

        // Committed: the atlas now borrows each image, so ownership passes out of
        // the bake (set null) into `bitmaps` — regardless of a put failure, the
        // image must stay alive while the snapshot references it. Published under
        // shape_lock, where the render path reads the table.
        _ = c.pthread_mutex_lock(&self.shape_lock);
        for (committed.items) |i| {
            const bake = &b.bitmaps[i];
            const image = bake.image.?;
            bake.image = null;
            _ = self.bitmaps.put(alloc, bake.id, .{
                .key = snail.record_key.colorBitmapGlyph(bake.id.font_id, bake.id.glyph_id, bake.id.ppem),
                .xform = bake.prep.design_to_source,
                .image = image,
            });
        }
        _ = c.pthread_mutex_unlock(&self.shape_lock);
    }

    /// Per-worker TrueType hint state: a `TtHintContext` for the primary face
    /// plus its cached per-ppem `TtHintSize`. Thread-confined — one per prep
    /// worker. `ctx` is null until `startPrep` initialises it (only when
    /// `tt_hint_supported`). A prep batch is single-ppem, so the size is built
    /// once per batch and reused across every `.tt_glyph`/`.tt_advance` request.
    const TtWorker = struct {
        ctx: ?snail.TtHintContext = null,
        size: ?snail.TtHintSize = null,
        size_ppem_26_6: u32 = 0,

        /// Prepare one TT request, (re)building the per-ppem size on demand.
        /// The ppem rides on the request itself, so no external plumbing.
        fn prepare(self: *TtWorker, request: snail.PrepareRequest) !snail.prepared.OwnedRecord {
            const ppem = switch (request.operation) {
                .tt_glyph => |o| o.ppem,
                .tt_advance => |o| o.ppem,
                else => return error.WrongContext,
            };
            if (self.ctx == null) return error.NoHinting;
            if (self.size == null or self.size_ppem_26_6 != ppem.x_26_6) {
                if (self.size) |*s| s.deinit();
                self.size = null;
                self.size = try self.ctx.?.prepareSize(ppem);
                self.size_ppem_26_6 = ppem.x_26_6;
            }
            return self.ctx.?.prepare(&self.size.?, request);
        }

        fn deinit(self: *TtWorker) void {
            if (self.size) |*s| s.deinit();
            if (self.ctx) |*cx| cx.deinit();
            self.* = .{};
        }
    };

    /// Effective TT-hint state this pass: the live toggle AND primary-face
    /// support AND no runtime bake failure. Read by the render path and the
    /// prep thread.
    pub fn ttEffective(self: *const AtlasRef) bool {
        return self.tt_hint_supported and
            !self.tt_hint_failed.load(.monotonic) and
            self.tt_hint.load(.monotonic);
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
        /// Per-worker TT context, non-null only for a `.tt_hint` plan.
        /// `.tt_glyph`/`.tt_advance` requests route here; `.outline` uses `ctx`.
        tt: ?*TtWorker = null,
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
                    // Both hinted and unhinted runs are dependency-free, so any
                    // worker prepares any index in any order. `.outline` goes to
                    // the shared OutlineContext; `.tt_glyph`/`.tt_advance` to the
                    // per-worker TtHintContext (populated for `.tt_hint` plans).
                    const request = self.requests[i];
                    const record = (switch (request.operation) {
                        .outline => self.ctx.prepare(request),
                        else => self.tt.?.prepare(request),
                    }) catch |e| {
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

    /// FontSource selection set: every distinct font the runs may reference.
    /// `planRuns` skips glyphs whose font_id isn't listed and rejects duplicate
    /// ids, so dedup by font_id here. Used for the unhinted-all plan.
    fn buildAllSources(self: *AtlasRef, out: *std.ArrayList(snail.FontSource)) !void {
        for (self.face_specs.items) |spec| {
            var dup = false;
            for (out.items) |s| {
                if (s.font_id == spec.font_id) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            try out.append(self.allocator, .{
                .font_id = spec.font_id,
                .font = spec.font,
                .cache_key = fontCacheKey(spec),
            });
        }
    }

    /// Plan → parallel-prepare. Enumerates the miss glyphs not already resident
    /// in `base` and bakes them across up to `prep_workers` workers (this thread
    /// runs one, spawns the rest); planning stays serial. `mode` selects the
    /// hinting path and `sources` the participating fonts; when `hinted`, TT
    /// requests route to the per-worker `TtHintContext`s. Does NOT mutate the
    /// atlas — the baked records are returned as an `ExtractedBatch` for the
    /// apply thread to commit. Returns null when nothing new needs baking. Any
    /// prepare error frees the partial work and propagates.
    fn planAndExtract(
        self: *AtlasRef,
        base: *const snail.Atlas,
        shaped: *const snail.ShapedText,
        sources: []const snail.FontSource,
        mode: snail.PrepareMode,
        hinted: bool,
    ) !?ExtractedBatch {
        var plan = try snail.planRuns(base, self.allocator, sources, &.{shaped}, mode);
        errdefer plan.deinit();

        const requests = plan.requests();
        const count = requests.len;
        if (count == 0) {
            // Every glyph is already resident: nothing to bake or publish.
            plan.deinit();
            return null;
        }

        // One owned artifact + one result view per request. On success these
        // become the batch's; on error the errdefers free them.
        const owned = try self.allocator.alloc(?snail.prepared.OwnedRecord, count);
        errdefer {
            for (owned) |*rec| if (rec.*) |*value| value.deinit();
            self.allocator.free(owned);
        }
        @memset(owned, null);
        const results = try self.allocator.alloc(?snail.prepared.RecordView, count);
        errdefer self.allocator.free(results);
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
            .tt = if (hinted) &self.tt_workers[ti] else null,
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

        return ExtractedBatch{
            .plan = plan,
            .owned = owned,
            .results = results,
            .allocator = self.allocator,
        };
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
        // Stop the prep threads first — the apply thread publishes/retires
        // snapshots and must not race the teardown below.
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
        self.bitmaps.deinit(self.allocator);
        _ = c.pthread_mutex_destroy(&self.shape_lock);
        _ = c.pthread_cond_destroy(&self.prep_cond);
        _ = c.pthread_mutex_destroy(&self.prep_mutex);
        _ = c.pthread_cond_destroy(&self.apply_cond);
        _ = c.pthread_mutex_destroy(&self.apply_mutex);
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
