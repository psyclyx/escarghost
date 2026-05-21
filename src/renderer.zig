const std = @import("std");
const snail = @import("snail");
const atlas_ref_mod = @import("atlas_ref.zig");
const render_env = @import("render_env.zig");
const render_snapshot = @import("render_snapshot.zig");
const render_config = @import("render_config.zig");
const render_common = @import("render_common.zig");
const glyph_misses = @import("glyph_misses.zig");
const row_build = @import("row_build.zig");
const color = @import("color.zig");
const perf = @import("perf.zig");
const Rgb = color.Rgb;

const gl = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GLES3/gl3.h");
    @cInclude("GLES3/gl3ext.h");
});

const MAX_SNAPSHOT_ROWS: usize = render_snapshot.MaxRows;
const MAX_OVERRIDES: usize = MAX_SNAPSHOT_ROWS + 4; // rows + cursor blob

// Stable resource keys. Atlas dedupes across blobs; the picture is rebuilt
// every frame but reuses the same key so snail's resource cache can identify
// the upload as a content change rather than a new resource.
const ATLAS_KEY = snail.ResourceKey.named("scrgo.atlas");
const PICTURE_KEY = snail.ResourceKey.named("scrgo.rects");
const TEXT_KEYS: snail.TextResourceKeys = .{ .atlas = ATLAS_KEY };

// One atlas + one path picture per frame. snail's manifest dedupes on key.
const MANIFEST_CAP: usize = 2;

// Baseline offset for the warmup glyph; matches row_build.baseline_factor
// closely enough to keep the warm-up output in a sane place on the
// dmabuf before we invalidate and repaint.
const baseline_warm: f32 = 0.8;

pub const CellMetrics = struct { cell_width: f32, cell_height: f32 };

/// Compute terminal cell dimensions from the atlas's primary face.
/// Cell width is the font's natural 'M' advance — *not* ceiled. A
/// well-behaved monospace font's ligatures (`==`, `=>`, `fl`, etc.) have
/// advances that are exact N×em multiples of this, so HB's natural glyph
/// advances align with our cell grid by construction. Rounding cell_width
/// up would compound a fractional-pixel mismatch over a long row and
/// drift the cursor away from the text.
pub fn computeCellMetrics(atlas: *const snail.TextAtlas, font_size: f32) !CellMetrics {
    const cm = try atlas.cellMetrics(.{ .em = font_size });
    return .{
        .cell_width = cm.cell_width,
        .cell_height = @ceil(cm.line_height),
    };
}

pub const MaxTargets: usize = 4;

/// Per-output-buffer paint state. We render directly into the caller's
/// dmabuf with `backdrop = .target`, so each dmabuf's pixels persist
/// across the swap chain rotation — but each one persists *its own*
/// content era, not the canvas's. When we come back to dmabuf #i for
/// the second time, we have to bring it up to date with the rows that
/// changed since its prior paint. Each `TargetState` records what that
/// dmabuf currently shows so we can compute the delta cheaply.
const TargetState = struct {
    /// False until the first paint completes for this buffer. With
    /// `backdrop = .target` we must avoid sampling undefined pixels —
    /// the first frame into any buffer uses `backdrop = .clear` to
    /// seed it.
    seeded: bool = false,
    /// Blob pointer painted at each row index. `null` = no row was
    /// painted at this index. Dirty-test: current blob ptr != recorded.
    row_blobs: [MAX_SNAPSHOT_ROWS]?*const snail.TextBlob = [_]?*const snail.TextBlob{null} ** MAX_SNAPSHOT_ROWS,
    /// Content hash painted at each row index. Lets a `rebindAll`
    /// eviction (which carries content hashes, not row indices) map
    /// back to which target rows need repainting.
    row_hashes: [MAX_SNAPSHOT_ROWS]u64 = [_]u64{0} ** MAX_SNAPSHOT_ROWS,
    /// Cursor identity painted onto this buffer; see `packCursorId`.
    cursor_id: u64 = 0,
    /// Selection identity painted onto this buffer. Zero = no
    /// selection was painted. See `packSelectionId` in row_build.
    selection_id: u64 = 0,
    /// Row indices that the most-recent painted selection covered.
    /// Used to dirty those rows when the selection changes (so the
    /// stale highlight gets repainted with no-selection cells).
    selection_rows: [MAX_SNAPSHOT_ROWS]u16 = [_]u16{0} ** MAX_SNAPSHOT_ROWS,
    selection_row_count: usize = 0,

    fn reset(self: *TargetState) void {
        self.seeded = false;
        @memset(&self.row_blobs, null);
        @memset(&self.row_hashes, 0);
        self.cursor_id = 0;
        self.selection_id = 0;
        self.selection_row_count = 0;
    }

    fn clearEvicted(self: *TargetState, evicted_hashes: []const u64) void {
        for (&self.row_hashes, 0..) |h, i| {
            for (evicted_hashes) |k| {
                if (h == k) {
                    self.row_blobs[i] = null;
                    self.row_hashes[i] = 0;
                    break;
                }
            }
        }
    }
};

/// Pack a cursor overlay into a u64 for cheap "has the cursor changed in
/// a way that would redirty its row?" comparisons. Layout: bit 63 set =
/// cursor visible; low bits carry x, y, style, has-inverted-glyph. Zero
/// is reserved for "no cursor."
fn packCursorId(cursor: ?row_build.CursorOverlay) u64 {
    const c = cursor orelse return 0;
    const inverted_bit: u64 = if (c.inverted_glyph != null) 1 else 0;
    return (@as(u64, 1) << 63) |
        (@as(u64, c.cell_x) & 0xFFFF) |
        ((@as(u64, c.cell_y) & 0xFFFF) << 16) |
        ((@as(u64, @intFromEnum(c.style)) & 0xFF) << 32) |
        (inverted_bit << 40);
}

fn containsIndex(slice: []const usize, target: usize) bool {
    for (slice) |v| {
        if (v == target) return true;
    }
    return false;
}

fn cursorRowFromId(id: u64) ?usize {
    if (id == 0) return null;
    return @intCast((id >> 16) & 0xFFFF);
}

pub fn computeGridSize(cell_width: f32, cell_height: f32, pixel_w: u32, pixel_h: u32) struct { cols: u16, rows: u16 } {
    return .{
        .cols = @intFromFloat(@max(1.0, @floor(@as(f32, @floatFromInt(pixel_w)) / cell_width))),
        .rows = @intFromFloat(@max(1.0, @floor(@as(f32, @floatFromInt(pixel_h)) / cell_height))),
    };
}

/// GPU renderer state. Owned exclusively by the GPU renderer thread.
/// Reads the shared atlas (via AtlasRef, lock-free).
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    atlas_ref: *atlas_ref_mod.AtlasRef,
    atlas_lease: atlas_ref_mod.AtlasRef.Lease,

    gl_renderer: snail.Gles30Renderer,
    scene: snail.Scene,
    builder: snail.TextBlobBuilder,

    last_atlas_gen: u64 = 0,
    last_atlas_identity: u64 = 0,

    row_cache: row_build.RowCache,

    scratch_rects: []row_build.ColoredRect = &.{},
    overrides: [MAX_OVERRIDES]snail.Override = undefined,
    manifest_entries: [MANIFEST_CAP]snail.ResourceManifest.Entry = undefined,

    draw_buf: std.ArrayList(u32) = .empty,
    seg_buf: std.ArrayList(snail.DrawList.Segment) = .empty,

    /// Per-frame ephemeral blob storage (cursor inversion). Heap-allocated
    /// so the scene can record stable `*const TextBlob` pointers across
    /// mid-frame growth; bulk-released after each frame.
    ephemeral_blobs: row_build.EphemeralBlobs,

    cell_width: f32,
    cell_height: f32,
    font_size: f32,
    viewport_w: f32,
    viewport_h: f32,
    config: render_config.RenderConfig,

    scratch_ready: bool = false,
    debug_log_renderers: bool = false,
    debug_log_frames: bool = false,
    debug_log_atlas: bool = false,
    debug_reset_atlas_each_frame: bool = false,

    /// Prior-frame state for the dirty-row stats counters. `prev_row_count == 0`
    /// distinguishes the very-first frame from a mid-run canvas invalidation.
    /// `prev_atlas_identity` lets us tell atlas snapshots apart for diagnostic
    /// bucketing.
    prev_row_count: usize = 0,
    prev_atlas_identity: u64 = 0,
    /// Per-output-buffer paint state. The dmabuf swap chain rotates,
    /// but each individual dmabuf preserves its own pixels across
    /// rotations — so we treat each dmabuf as its own persistent
    /// canvas. The caller selects which one before `drawSnapshot` via
    /// `setActiveTarget`. See `TargetState` for the per-buffer fields.
    targets: [MaxTargets]TargetState = [_]TargetState{.{}} ** MaxTargets,
    /// Index into `targets` for the buffer the next `drawSnapshot`
    /// will paint into. Set by the caller via `setActiveTarget`.
    active_target: u8 = 0,

    /// Per-frame scratch: indices into `built.rows` that need repainting.
    dirty_rows_buf: [MAX_SNAPSHOT_ROWS]usize = undefined,

    pub var frame_stats: perf.FrameStats = .{};

    /// Per-phase wall-time accumulators (ns). Written by the GPU worker
    /// thread only; main reads them at exit when SCRGO_LOG=commits. Single
    /// writer + single reader, race is benign for diagnostics.
    pub var phase_row_build_ns: u64 = 0;
    pub var phase_picture_ns: u64 = 0;
    pub var phase_upload_ns: u64 = 0;
    pub var phase_drawlist_ns: u64 = 0;
    pub var phase_draw_ns: u64 = 0;
    pub var phase_frame_count: u64 = 0;

    /// Dirty-row measurement. For each rendered frame, counts how many rows
    /// would have needed repainting under a canvas-preserving scheme:
    /// rows whose content_hash differs from the prior frame's, plus rows
    /// touched by cursor movement. `dirty_rows_with_cursor_total` and
    /// `dirty_rows_content_only_total` differ by exactly the cursor cost.
    /// Histograms bucket frames by how many rows were dirty under the
    /// cursor-inclusive rule.
    pub var dirty_frames_examined: u64 = 0;
    pub var dirty_rows_content_only_total: u64 = 0;
    pub var dirty_rows_with_cursor_total: u64 = 0;
    pub var dirty_rows_visible_total: u64 = 0;
    pub var dirty_bucket_0: u64 = 0;
    pub var dirty_bucket_1: u64 = 0;
    pub var dirty_bucket_2_4: u64 = 0;
    pub var dirty_bucket_5_25: u64 = 0;
    pub var dirty_bucket_26plus: u64 = 0;
    pub var dirty_full_repaint_frames: u64 = 0;
    pub var dirty_repaint_first_frame: u64 = 0;
    pub var dirty_repaint_atlas_changed: u64 = 0;
    /// Atlas-snapshot bumps where `rebindAll` evicted at least one row.
    /// Those evictions mean the canvas's painted pixels for those rows
    /// are stale; the canvas must repaint. A subset of `atlas_changed`.
    pub var dirty_repaint_atlas_hard: u64 = 0;
    /// Most recent rebindAll() eviction count, snapshotted at the moment
    /// of atlas refresh so recordDirtyStats can attribute hard vs soft.
    var last_rebind_evicted: usize = 0;

    pub fn init(
        allocator: std.mem.Allocator,
        atlas_ref: *atlas_ref_mod.AtlasRef,
        font_size: f32,
        cell_width: f32,
        cell_height: f32,
    ) !Renderer {
        var gl_renderer = try snail.Gles30Renderer.init(allocator);
        errdefer gl_renderer.deinit();

        var atlas_lease = atlas_ref.acquire();
        errdefer atlas_lease.release();
        const atlas = atlas_lease.get();
        const builder = snail.TextBlobBuilder.init(allocator, atlas);
        var scene = snail.Scene.init(allocator);
        errdefer scene.deinit();

        return .{
            .allocator = allocator,
            .atlas_ref = atlas_ref,
            .atlas_lease = atlas_lease,
            .gl_renderer = gl_renderer,
            .scene = scene,
            .builder = builder,
            .last_atlas_gen = atlas_ref.loadGeneration(),
            .last_atlas_identity = atlas.snapshotIdentity(),
            .row_cache = row_build.RowCache.init(allocator, 32 * 1024 * 1024),
            .ephemeral_blobs = row_build.EphemeralBlobs.init(allocator),
            .cell_width = cell_width,
            .cell_height = cell_height,
            .font_size = font_size,
            .viewport_w = 0,
            .viewport_h = 0,
            .config = render_config.loadFromEnv(),
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.row_cache.deinit();
        self.ephemeral_blobs.deinit();
        if (self.scratch_ready) self.allocator.free(self.scratch_rects);
        self.draw_buf.deinit(self.allocator);
        self.seg_buf.deinit(self.allocator);
        self.builder.deinit();
        self.atlas_lease.release();
        self.scene.deinit();
        self.gl_renderer.deinit();
    }

    /// Drop all per-target paint state so the next paint into any
    /// dmabuf starts from a clean clear. Used when viewport/metrics
    /// change (every dmabuf's geometry is now stale).
    fn invalidateAllTargets(self: *Renderer) void {
        for (&self.targets) |*t| t.reset();
    }

    /// Select which output buffer `drawSnapshot` will paint into. The
    /// caller is responsible for binding that buffer's FBO before
    /// calling `drawSnapshot`; we use the index to look up its
    /// persistent paint state.
    pub fn setActiveTarget(self: *Renderer, idx: u8) void {
        self.active_target = if (idx < MaxTargets) idx else 0;
    }

    /// Render a tiny synthetic frame to compile every shader program
    /// snail will use at steady state: text (glyph blob), vector path
    /// (filled rect), and the linear-resolve seed + encode shaders
    /// (via `backdrop = .target`). Atlas textures + glyph pages get
    /// uploaded here too. Without this, those one-time costs would
    /// land on the first real frames the user sees as visible jank
    /// (~10ms on frame 1, then a smaller spike on the first `.target`
    /// frame). Caller must bind a valid FBO; we paint into it and
    /// then invalidate all per-buffer state so the first real frame
    /// repaints from scratch.
    pub fn warmPipeline(self: *Renderer) !void {
        defer {
            self.scene.reset();
            self.builder.reset();
            self.ephemeral_blobs.releaseAll();
            self.invalidateAllTargets();
        }

        const atlas = self.atlas_lease.get();
        self.scene.reset();
        self.builder.reset();

        // Path picture: one tiny rect → compiles vector path shader
        // and exercises the path-picture upload path.
        var picture_builder = snail.PathPictureBuilder.init(self.allocator);
        defer picture_builder.deinit();
        try picture_builder.addFilledRect(
            .{ .x = 0, .y = 0, .w = 2, .h = 2 },
            .{ .paint = .{ .solid = .{ 1, 1, 1, 1 } } },
            .identity,
        );
        var picture = try picture_builder.freeze(.{
            .persistent_allocator = self.allocator,
            .scratch_allocator = self.allocator,
        });
        defer picture.deinit();

        // Text blob: shape & lay out one glyph → compiles text shader
        // and forces the atlas to be uploaded to the GPU. We pick 'a'
        // because atlas_owner's bootstrap populates ASCII.
        var shaped = atlas.shapeText(self.allocator, .{}, "a") catch null;
        var blob_opt: ?snail.TextBlob = null;
        defer if (blob_opt) |*b| b.deinit();
        if (shaped) |*s| {
            defer s.deinit();
            _ = self.builder.append(.{
                .shaped = s,
                .placement = .{
                    .baseline = .{ .x = 0, .y = self.cell_height * baseline_warm },
                    .em = self.font_size,
                },
                .fill = .{ .solid = .{ 1, 1, 1, 1 } },
            }) catch null;
            blob_opt = self.builder.finish() catch null;
        }

        var manifest = snail.ResourceManifest.init(self.manifest_entries[0..]);
        try manifest.putPathPicture(PICTURE_KEY, &picture);
        try self.scene.addPath(.{ .picture = &picture, .resource_key = PICTURE_KEY });

        if (blob_opt) |*blob| {
            try manifest.putTextBlob(TEXT_KEYS, blob);
            try self.scene.addText(.{ .blob = blob, .resources = TEXT_KEYS });
        }

        var prepared = try self.gl_renderer.uploadResourcesBlocking(
            .{ .persistent = self.allocator, .scratch = self.allocator },
            &manifest,
        );
        defer prepared.deinit();

        const buf_words = snail.DrawList.estimate(&self.scene);
        const seg_count = snail.DrawList.estimateSegments(&self.scene);
        try self.draw_buf.resize(self.allocator, buf_words);
        try self.seg_buf.resize(self.allocator, seg_count);
        var draw_list = snail.DrawList.init(self.draw_buf.items, self.seg_buf.items);
        try draw_list.addScene(&prepared, &self.scene);

        const pass: snail.DrawPass = .{
            .state = self.drawState(),
            .resolve = .{ .linear = .{
                .backdrop = .target,
                .region = .{ .pixel_rect = .{ .x = 0, .y = 0, .w = 4, .h = 4 } },
            } },
        };
        try self.gl_renderer.drawPass(&prepared, &draw_list, pass);
        gl.glFinish();
    }

    /// Notify the renderer that the output buffer set has been
    /// (re)allocated. Every dmabuf now backs a *new* texture with
    /// undefined pixel contents, so any "this buffer is seeded"
    /// belief from the prior allocation is stale and must be dropped
    /// — otherwise the next paint reads garbage via `backdrop = .target`.
    /// Call this whenever the GPU side re-imports its dmabufs (initial
    /// install, reconfigure, GPU/context restart, etc.), even if the
    /// viewport dimensions didn't change.
    pub fn notifyTargetsReinstalled(self: *Renderer) void {
        self.invalidateAllTargets();
    }

    fn ensureScratch(self: *Renderer) !void {
        if (self.scratch_ready) return;
        self.scratch_rects = try self.allocator.alloc(row_build.ColoredRect, row_build.MAX_RECTS_PER_ROW);
        self.scratch_ready = true;
    }

    pub fn setDebugResetAtlas(self: *Renderer, enabled: bool) void {
        self.debug_reset_atlas_each_frame = enabled;
    }

    pub fn setDebugLogs(self: *Renderer, options: render_env.RendererDebug) void {
        self.debug_log_renderers = options.renderers;
        self.debug_log_frames = options.frames;
        self.debug_log_atlas = options.atlas;
    }

    /// Resize the drawable. Pure window-resize; cell metrics are unchanged
    /// so the row cache stays hot.
    pub fn setViewport(self: *Renderer, w: u32, h: u32) void {
        if (self.viewport_w == @as(f32, @floatFromInt(w)) and self.viewport_h == @as(f32, @floatFromInt(h))) return;
        self.viewport_w = @floatFromInt(w);
        self.viewport_h = @floatFromInt(h);
        self.invalidateAllTargets();
    }

    /// Update font metrics. Each cached `TextBlob` bakes `placement.em` into
    /// its per-instance Transform2D, so any metrics change invalidates the
    /// entire row cache. No-op when metrics are unchanged.
    pub fn setMetrics(self: *Renderer, font_size: f32, cell_width: f32, cell_height: f32) void {
        if (self.font_size == font_size and self.cell_width == cell_width and self.cell_height == cell_height) return;
        self.font_size = font_size;
        self.cell_width = cell_width;
        self.cell_height = cell_height;
        self.row_cache.clear();
        self.invalidateAllTargets();
    }

    /// Refresh atlas snapshot. On identity change, rebind cached blobs.
    fn refreshAtlas(self: *Renderer) *const snail.TextAtlas {
        last_rebind_evicted = 0;
        var next_lease = self.atlas_ref.acquire();
        const atlas = next_lease.get();
        const identity = atlas.snapshotIdentity();
        if (identity == self.last_atlas_identity) {
            next_lease.release();
            return self.atlas_lease.get();
        }

        self.last_atlas_gen = self.atlas_ref.loadGeneration();
        self.last_atlas_identity = identity;

        // Builder is anchored to the prior snapshot; rebuild it.
        self.builder.deinit();
        self.builder = snail.TextBlobBuilder.init(self.allocator, atlas);

        var evicted_buf: [MAX_SNAPSHOT_ROWS]u64 = undefined;
        const stats = self.row_cache.rebindAllInto(atlas, identity, evicted_buf[0..]);
        last_rebind_evicted = stats.evicted;
        // Surgical per-target dirtying: rows whose blob couldn't be
        // rebound have stale pixels in *every* dmabuf that painted
        // them. Walk each target's hash table and null out the entries
        // that match an evicted content hash; future frames into that
        // dmabuf will repaint those rows. If we got truncated (more
        // evictions than fit in our scratch buffer), fall back to a
        // full invalidate.
        if (stats.evicted > evicted_buf.len) {
            self.invalidateAllTargets();
        } else if (stats.evicted > 0) {
            const evicted = evicted_buf[0..stats.evicted];
            for (&self.targets) |*t| t.clearEvicted(evicted);
        }
        if (self.debug_log_atlas) {
            std.debug.print("scrgo[gpu-renderer]: atlas snapshot {} (rebound={}, evicted={})\n", .{ identity, stats.rebound, stats.evicted });
        }
        self.atlas_lease.release();
        self.atlas_lease = next_lease;
        return atlas;
    }

    fn rowMetrics(self: *const Renderer) row_build.Metrics {
        return .{
            .cell_width = self.cell_width,
            .cell_height = self.cell_height,
            .font_size = self.font_size,
        };
    }

    /// Emit cursor geometry into the per-frame path picture. Cursor edges
    /// snap to integer pixel boundaries by computing both edges in float
    /// (cell_width is fractional) and rounding each separately — never
    /// multiplying `cell_x` by a truncated width.
    fn emitCursor(self: *const Renderer, picture: *snail.PathPictureBuilder, cursor: row_build.CursorOverlay) !void {
        const x0_f = @as(f32, @floatFromInt(cursor.cell_x)) * self.cell_width;
        const y0_f = @as(f32, @floatFromInt(cursor.cell_y)) * self.cell_height;
        const x1_f = @as(f32, @floatFromInt(cursor.cell_x + 1)) * self.cell_width;
        const y1_f = @as(f32, @floatFromInt(cursor.cell_y + 1)) * self.cell_height;
        const x0 = @round(x0_f);
        const y0 = @round(y0_f);
        const x1 = @round(x1_f);
        const y1 = @round(y1_f);
        const cw = @max(1.0, x1 - x0);
        const ch = @max(1.0, y1 - y0);
        const cc = cursor.color.toFloat4(1.0);
        const fill: snail.FillStyle = .{ .paint = .{ .solid = cc } };
        switch (cursor.style) {
            .block => try picture.addFilledRect(.{ .x = x0, .y = y0, .w = cw, .h = ch }, fill, .identity),
            .bar => try picture.addFilledRect(.{ .x = x0, .y = y0, .w = 2.0, .h = ch }, fill, .identity),
            .underline => try picture.addFilledRect(.{ .x = x0, .y = y0 + ch - 2.0, .w = cw, .h = 2.0 }, fill, .identity),
            .block_hollow => try picture.addStrokedRect(
                .{ .x = x0, .y = y0, .w = cw, .h = ch },
                .{ .paint = .{ .solid = cc }, .width = 1.5, .placement = .inside },
                .identity,
            ),
        }
    }

    fn drawState(self: *const Renderer) snail.DrawState {
        return .{
            .mvp = snail.Mat4.ortho(0, self.viewport_w, self.viewport_h, 0, -1, 1),
            .surface = .{
                .pixel_width = self.viewport_w,
                .pixel_height = self.viewport_h,
                // FBO storage is linear-format (mesa rejects sRGB dmabuf
                // imports), consumer expects sRGB bytes. The .linear resolve
                // below tells snail to render into a linear RGBA16F
                // intermediate and encode-pass the result into our linear
                // attachment.
                .encoding = .srgb_pixels_on_linear_attachment,
            },
            .raster = .{ .subpixel_order = render_config.effectiveSubpixelOrder(self.config) },
        };
    }

    pub fn drawSnapshot(self: *Renderer, snapshot: *const render_snapshot.SharedSnapshot, misses: *glyph_misses.Set) !void {
        const frame_timer = perf.Timer.now();
        var atlas = self.refreshAtlas();
        try self.ensureScratch();
        // Caller has already bound the active target's dmabuf FBO; we
        // render straight into it. Each dmabuf retains its own pixels
        // across the swap chain rotation, so backdrop=.target preserves
        // prior frames painted into the *same* dmabuf and we only have
        // to repaint rows that differ from this buffer's recorded era.
        self.scene.reset();

        var rows_buf: [MAX_SNAPSHOT_ROWS]row_build.RowDraw = undefined;
        var sel_buf: [row_build.MAX_SELECTION_SPANS]row_build.SelectionSpan = undefined;
        const row_build_t0 = perf.Timer.now();
        var built = try row_build.buildSnapshot(
            snapshot,
            self.allocator,
            self.rowMetrics(),
            &self.row_cache,
            &self.builder,
            atlas,
            self.last_atlas_identity,
            self.scratch_rects,
            rows_buf[0..],
            sel_buf[0..],
            &self.ephemeral_blobs,
            misses,
        );
        phase_row_build_ns += row_build_t0.elapsedNs();

        // Pass 1 had glyph misses; try a single sync atlas extension.
        // On success: refresh state and re-build. On miss/failure: ship
        // partial — the user sees gaps for the missing glyphs but the
        // rest of the frame paints normally.
        if (!misses.isEmpty()) {
            const result = self.atlas_ref.extend(atlas, misses.text()) catch |err| blk: {
                if (self.debug_log_atlas) std.debug.print("scrgo[gpu-renderer]: atlas extend failed: {}\n", .{err});
                break :blk .missing;
            };
            if (result == .extended) {
                self.scene.reset();
                self.ephemeral_blobs.releaseAll();
                misses.clear();
                atlas = self.refreshAtlas();
                const rebuild_t0 = perf.Timer.now();
                built = try row_build.buildSnapshot(
                    snapshot,
                    self.allocator,
                    self.rowMetrics(),
                    &self.row_cache,
                    &self.builder,
                    atlas,
                    self.last_atlas_identity,
                    self.scratch_rects,
                    rows_buf[0..],
                    sel_buf[0..],
                    &self.ephemeral_blobs,
                    misses,
                );
                phase_row_build_ns += rebuild_t0.elapsedNs();
            } else if (self.debug_log_atlas) {
                std.debug.print("scrgo[gpu-renderer]: atlas extend missing for {} bytes\n", .{misses.text().len});
            }
        }

        const dirty = self.computeDirty(built);
        self.recordDirtyStats(built, dirty);

        try self.flushDraw(built, dirty, snapshot.header.default_bg);
        self.ephemeral_blobs.releaseAll();
        frame_stats.record(frame_timer.elapsedUs());
    }

    /// Decide which rows have to be repainted onto the canvas this
    /// frame. The canvas keeps prior pixels intact, so rows whose blob
    /// pointer is unchanged from the last paint already look right and
    /// can be skipped. Cursor moves dirty both the cell-it-left and
    /// the cell-it-arrived-at. Selection changes dirty every row that
    /// was in the prior selection or is in the new one. If the canvas
    /// isn't seeded yet we just dirty everything.
    fn computeDirty(self: *Renderer, built: row_build.BuiltSnapshot) []const usize {
        const row_count = built.rows.len;
        const target = &self.targets[self.active_target];
        if (!target.seeded) {
            for (0..row_count) |i| self.dirty_rows_buf[i] = i;
            return self.dirty_rows_buf[0..row_count];
        }

        // Compare by content_hash, not blob pointer. Blob pointers can
        // be recycled by the heap allocator after the row cache evicts
        // an entry (LRU sweep), so two unrelated blobs may share an
        // address across frames — a false-negative dirty bit, with
        // stale pixels staying on screen. Content hashes are stable
        // and the values we already plumb through.
        var marked: [MAX_SNAPSHOT_ROWS]bool = [_]bool{false} ** MAX_SNAPSHOT_ROWS;
        for (built.rows, 0..) |row, i| {
            if (target.row_blobs[i] == null or target.row_hashes[i] != row.content_hash) {
                marked[i] = true;
            }
        }

        const new_cursor_id = packCursorId(built.cursor);
        if (new_cursor_id != target.cursor_id) {
            if (cursorRowFromId(target.cursor_id)) |r| {
                if (r < row_count) marked[r] = true;
            }
            if (cursorRowFromId(new_cursor_id)) |r| {
                if (r < row_count) marked[r] = true;
            }
        }

        if (built.selection_id != target.selection_id) {
            // Mark every row covered by the new selection. We also have
            // to repaint rows that were covered by the *previous*
            // selection so a stale band doesn't linger. The previous
            // spans aren't stored, so we mark them via the cached
            // row hash list: any row touched last time the selection
            // was non-zero needs a fresh paint anyway, but since
            // selection_id == 0 might be the new state too, fall back
            // to marking all painted rows when the prior selection
            // existed but we can't enumerate it.
            for (built.selection_spans) |span| {
                if (span.row < row_count) marked[span.row] = true;
            }
            if (target.selection_id != 0) {
                for (target.selection_rows[0..@min(target.selection_row_count, row_count)]) |r| {
                    if (r < row_count) marked[r] = true;
                }
            }
        }

        var n: usize = 0;
        for (marked[0..row_count], 0..) |is_dirty, i| {
            if (is_dirty) {
                self.dirty_rows_buf[n] = i;
                n += 1;
            }
        }
        return self.dirty_rows_buf[0..n];
    }

    /// Compare the built frame against the prior frame and tally how many
    /// rows would have been dirty under a canvas-preserving scheme. Pure
    /// measurement; mutates only the prev-frame snapshot fields and the
    /// global counters.
    fn recordDirtyStats(self: *Renderer, built: row_build.BuiltSnapshot, dirty: []const usize) void {
        const new_count = built.rows.len;
        const new_cursor_id = packCursorId(built.cursor);

        const is_first_frame = self.prev_row_count == 0;
        const atlas_changed = !is_first_frame and self.prev_atlas_identity != self.last_atlas_identity;
        const atlas_hard = atlas_changed and last_rebind_evicted > 0;
        if (is_first_frame) dirty_repaint_first_frame += 1;
        if (atlas_changed) dirty_repaint_atlas_changed += 1;
        if (atlas_hard) dirty_repaint_atlas_hard += 1;

        const total_dirty = dirty.len;
        dirty_frames_examined += 1;
        dirty_rows_visible_total += new_count;
        dirty_rows_content_only_total += total_dirty;
        dirty_rows_with_cursor_total += total_dirty;
        if (is_first_frame or !self.targets[self.active_target].seeded) dirty_full_repaint_frames += 1;

        if (total_dirty == 0) {
            dirty_bucket_0 += 1;
        } else if (total_dirty == 1) {
            dirty_bucket_1 += 1;
        } else if (total_dirty <= 4) {
            dirty_bucket_2_4 += 1;
        } else if (total_dirty <= 25) {
            dirty_bucket_5_25 += 1;
        } else {
            dirty_bucket_26plus += 1;
        }

        _ = new_cursor_id;
        self.prev_row_count = new_count;
        self.prev_atlas_identity = self.last_atlas_identity;
    }

    fn flushDraw(self: *Renderer, built: row_build.BuiltSnapshot, dirty: []const usize, default_bg: Rgb) !void {
        const default_bg_color = default_bg.toFloat4(1.0);
        // Cursor's row is always in `dirty` whenever the cursor changed,
        // so we can locate "cursor's dirty row" by membership: if the
        // cursor row is in `dirty`, we emit the cursor rect; otherwise
        // the existing canvas already shows it correctly.
        const cursor_row: ?usize = if (built.cursor) |c| @intCast(c.cell_y) else null;
        const cursor_in_dirty: bool = if (cursor_row) |r| containsIndex(dirty, r) else false;

        const target = &self.targets[self.active_target];

        // No-op frame: this dmabuf already shows the right pixels.
        // Skip the entire snail pass; the caller commits the buffer
        // unchanged.
        if (dirty.len == 0 and target.seeded) return;

        // Build the per-frame rect picture from the dirty rows + cursor.
        // Non-dirty rows already have their decoration rects baked into
        // the canvas from a prior frame.
        const picture_t0 = perf.Timer.now();
        var picture_builder = snail.PathPictureBuilder.init(self.allocator);
        defer picture_builder.deinit();

        // For each dirty row, paint a default-bg fill across the row's
        // full width before its cell-bg rects + glyphs. Without this,
        // a row's default-bg cells contribute no rect, so any prior
        // pixels there (most importantly a cursor that just moved off
        // this row) survive the repaint. The fill erases them.
        // Skipped when the buffer isn't seeded yet — backdrop=.clear
        // is doing the same job globally.
        const row_w = self.viewport_w;
        if (target.seeded) {
            for (dirty) |i| {
                const row_draw = built.rows[i];
                try picture_builder.addFilledRect(
                    .{ .x = 0, .y = row_draw.row_y, .w = row_w, .h = self.cell_height },
                    .{ .paint = .{ .solid = default_bg_color } },
                    .identity,
                );
            }
        }
        for (dirty) |i| {
            const row_draw = built.rows[i];
            for (row_draw.rects) |r| {
                if (r.w <= 0.0 or r.h <= 0.0) continue;
                try picture_builder.addFilledRect(
                    .{ .x = r.x, .y = r.y + row_draw.row_y, .w = r.w, .h = r.h },
                    .{ .paint = .{ .solid = r.color } },
                    .identity,
                );
            }
        }
        // Paint selection highlight on top of cell bgs but before
        // glyphs, so the band covers the cell color and the text is
        // legible over it. The dirty mask already includes every row
        // the selection touches (see computeDirty), so we don't have
        // to emit highlight rects for non-dirty rows.
        if (built.selection_spans.len > 0) {
            const sel_color = render_common.selectionFillColor(default_bg);
            for (built.selection_spans) |span| {
                if (!containsIndex(dirty, @intCast(span.row))) continue;
                const x0 = @as(f32, @floatFromInt(span.start_col)) * self.cell_width;
                const y0 = @as(f32, @floatFromInt(span.row)) * self.cell_height;
                const w = @as(f32, @floatFromInt(span.end_col - span.start_col + 1)) * self.cell_width;
                try picture_builder.addFilledRect(
                    .{ .x = x0, .y = y0, .w = w, .h = self.cell_height },
                    .{ .paint = .{ .solid = sel_color } },
                    .identity,
                );
            }
        }
        if (cursor_in_dirty) {
            if (built.cursor) |cursor| try self.emitCursor(&picture_builder, cursor);
        }

        var picture = try picture_builder.freeze(.{
            .persistent_allocator = self.allocator,
            .scratch_allocator = self.allocator,
        });
        defer picture.deinit();
        phase_picture_ns += picture_t0.elapsedNs();

        var manifest = snail.ResourceManifest.init(self.manifest_entries[0..]);
        try manifest.putPathPicture(PICTURE_KEY, &picture);

        if (picture.shapeCount() > 0) {
            try self.scene.addPath(.{ .picture = &picture, .resource_key = PICTURE_KEY });
        }

        var override_index: usize = 0;
        for (dirty) |i| {
            const row_draw = built.rows[i];
            if (row_draw.blob.glyphCount() == 0) continue;
            if (override_index >= self.overrides.len) break;
            self.overrides[override_index] = .{
                .transform = snail.Transform2D.translate(0, row_draw.row_y),
                .tint = .{ 1, 1, 1, 1 },
            };
            const slot = self.overrides[override_index .. override_index + 1];
            override_index += 1;
            try manifest.putTextBlob(TEXT_KEYS, row_draw.blob);
            try self.scene.addText(.{
                .blob = row_draw.blob,
                .resources = TEXT_KEYS,
                .instances = slot,
            });
        }
        if (cursor_in_dirty) {
            if (built.cursor) |cursor| {
                if (cursor.inverted_glyph) |blob| {
                    try manifest.putTextBlob(TEXT_KEYS, blob);
                    try self.scene.addText(.{ .blob = blob, .resources = TEXT_KEYS });
                }
            }
        }

        const upload_t0 = perf.Timer.now();
        var prepared = try self.gl_renderer.uploadResourcesBlocking(
            .{ .persistent = self.allocator, .scratch = self.allocator },
            &manifest,
        );
        defer prepared.deinit();
        phase_upload_ns += upload_t0.elapsedNs();

        const drawlist_t0 = perf.Timer.now();
        const buf_words = snail.DrawList.estimate(&self.scene);
        const seg_count = snail.DrawList.estimateSegments(&self.scene);
        try self.draw_buf.resize(self.allocator, buf_words);
        try self.seg_buf.resize(self.allocator, seg_count);
        var draw_list = snail.DrawList.init(self.draw_buf.items, self.seg_buf.items);
        try draw_list.addScene(&prepared, &self.scene);
        phase_drawlist_ns += drawlist_t0.elapsedNs();

        // Seeded buffer: preserve this dmabuf's prior pixels and paint
        // dirty rows on top. First paint into a buffer (or post-
        // invalidate): clear to the default bg so we don't sample
        // undefined dmabuf memory.
        const backdrop: snail.ResolveBackdrop = if (target.seeded)
            .target
        else
            .{ .clear = default_bg.toFloat4(1.0) };

        // Tighten the resolve region to the dirty band so snail's
        // .target backdrop only reads (and re-encodes) the rows we
        // actually touch.
        const viewport_w_u: u32 = @intFromFloat(@max(self.viewport_w, 1.0));
        const viewport_h_u: u32 = @intFromFloat(@max(self.viewport_h, 1.0));
        const region: snail.ResolveRegion = blk: {
            if (!target.seeded or dirty.len == 0) break :blk .full_target;
            var lo: usize = std.math.maxInt(usize);
            var hi: usize = 0;
            for (dirty) |i| {
                if (i < lo) lo = i;
                if (i > hi) hi = i;
            }
            const y0_f: f32 = @as(f32, @floatFromInt(lo)) * self.cell_height;
            const y1_f: f32 = @as(f32, @floatFromInt(hi + 1)) * self.cell_height;
            const y0: u32 = @intFromFloat(@max(0.0, @floor(y0_f)));
            const y1_clipped = @min(viewport_h_u, @as(u32, @intFromFloat(@ceil(y1_f))));
            if (y1_clipped <= y0) break :blk .full_target;
            break :blk .{ .pixel_rect = .{
                .x = 0,
                .y = @intCast(y0),
                .w = viewport_w_u,
                .h = y1_clipped - y0,
            } };
        };

        const pass: snail.DrawPass = .{
            .state = self.drawState(),
            .resolve = .{ .linear = .{ .backdrop = backdrop, .region = region } },
        };
        // Per-frame scene stats so we can spot "GPU went blank" cases. Counts
        // include the rect-picture shape count, the number of text blobs
        // added to the scene, and the total glyph count across all blobs.
        // If a frame goes blank but stats are non-zero, the issue is on the
        // GL side (resource-cache or context); if stats drop to zero, the
        // build/snapshot is the suspect.
        var total_glyphs: usize = 0;
        for (built.rows) |row_draw| total_glyphs += row_draw.blob.glyphCount();
        if (built.cursor) |cursor| {
            if (cursor.inverted_glyph) |blob| total_glyphs += blob.glyphCount();
        }
        const scene_shapes = picture.shapeCount();
        const scene_text_blobs = self.scene.commandCount();

        const draw_t0 = perf.Timer.now();
        try self.gl_renderer.drawPass(&prepared, &draw_list, pass);
        target.seeded = true;
        // Record what's now on this dmabuf so the *next* paint into the
        // same buffer (after the swap chain rotates back) can compute
        // its dirty set by blob-pointer comparison and so an atlas
        // rebind can correlate evicted content hashes back to row
        // indices that need re-painting.
        for (built.rows, 0..) |row, i| {
            target.row_blobs[i] = row.blob;
            target.row_hashes[i] = row.content_hash;
        }
        for (built.rows.len..MAX_SNAPSHOT_ROWS) |i| {
            target.row_blobs[i] = null;
            target.row_hashes[i] = 0;
        }
        target.cursor_id = packCursorId(built.cursor);
        target.selection_id = built.selection_id;
        target.selection_row_count = 0;
        for (built.selection_spans) |span| {
            if (target.selection_row_count >= target.selection_rows.len) break;
            target.selection_rows[target.selection_row_count] = span.row;
            target.selection_row_count += 1;
        }

        // Block on the GPU pipeline before reading back. glFlush alone is
        // fire-and-forget; for a readback we need the FBO to actually have
        // its contents before glReadPixels samples it. (The cost is paid
        // only when frame logging is on.)
        if (self.debug_log_frames) gl.glFinish() else gl.glFlush();
        phase_draw_ns += draw_t0.elapsedNs();
        phase_frame_count += 1;

        // Check for GL errors after the draw. Persistent errors after a
        // context loss / driver hiccup explain "screen went blank but our
        // pipeline thinks it's fine".
        var gl_err: gl.GLenum = gl.glGetError();
        var error_count: u32 = 0;
        while (gl_err != gl.GL_NO_ERROR and error_count < 4) {
            error_count += 1;
            if (self.debug_log_frames) {
                std.debug.print("scrgo[gpu-renderer]: GL error 0x{x} after drawPass (frame={})\n", .{ gl_err, phase_frame_count });
            }
            gl_err = gl.glGetError();
        }

        if (self.debug_log_frames) {
            // Sample 5 pixels across the FBO to see what actually landed in
            // it. If the dmabuf is all bg color (or all zero) while scene
            // stats show content, the snail/GL pipeline produced an empty
            // output despite non-empty inputs.
            const w_i: gl.GLint = @intFromFloat(@max(self.viewport_w, 1.0));
            const h_i: gl.GLint = @intFromFloat(@max(self.viewport_h, 1.0));
            const sample_xs = [_]gl.GLint{ @divTrunc(w_i, 5), @divTrunc(w_i * 2, 5), @divTrunc(w_i, 2), @divTrunc(w_i * 3, 5), @divTrunc(w_i * 4, 5) };
            const sample_y: gl.GLint = @divTrunc(h_i, 2);
            var pixels: [5][4]u8 = undefined;
            for (sample_xs, 0..) |x, i| {
                gl.glReadPixels(x, sample_y, 1, 1, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, &pixels[i]);
            }
            std.debug.print(
                "scrgo[gpu-renderer]: frame={} rects={} blobs={} glyphs={} (rows={}) px=[{x:0>2}{x:0>2}{x:0>2} {x:0>2}{x:0>2}{x:0>2} {x:0>2}{x:0>2}{x:0>2} {x:0>2}{x:0>2}{x:0>2} {x:0>2}{x:0>2}{x:0>2}]\n",
                .{
                    phase_frame_count,
                    scene_shapes,
                    scene_text_blobs,
                    total_glyphs,
                    built.rows.len,
                    pixels[0][0], pixels[0][1], pixels[0][2],
                    pixels[1][0], pixels[1][1], pixels[1][2],
                    pixels[2][0], pixels[2][1], pixels[2][2],
                    pixels[3][0], pixels[3][1], pixels[3][2],
                    pixels[4][0], pixels[4][1], pixels[4][2],
                },
            );
        }
    }
};
