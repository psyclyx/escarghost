const std = @import("std");
const snail = @import("snail");
const terminal_mod = @import("terminal.zig");
const atlas_ref_mod = @import("atlas_ref.zig");
const render_env = @import("render_env.zig");
const render_snapshot = @import("render_snapshot.zig");
const glyph_misses = @import("glyph_misses.zig");
const render_common = @import("render_common.zig");
const gl_rect = @import("gl_rect.zig");
const color = @import("color.zig");
const perf = @import("perf.zig");
const Rgb = color.Rgb;
const Terminal = terminal_mod.Terminal;
const CursorCell = render_common.CursorCell;
const ColoredRect = gl_rect.ColoredRect;

const gl = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GL/gl.h");
    @cInclude("GL/glext.h");
});

const baseline_factor: f32 = 0.8;
const MAX_RECTS_PER_ROW: usize = 400 * 3;
const MAX_DRAW_RECTS: usize = 400 * 200 * 3 + 16;
const MAX_SNAPSHOT_ROWS: usize = render_snapshot.MaxRows;
const MAX_OVERRIDES: usize = MAX_SNAPSHOT_ROWS + 4; // rows + cursor blob
const RESOURCE_ENTRY_CAP: usize = 4;

pub const CellMetrics = struct { cell_width: f32, cell_height: f32 };

/// Compute terminal cell dimensions from the atlas's primary face.
/// Cell width comes from the 'M' advance; line height from the font's
/// hhea metrics. Both are ceiled for crisp pixel alignment.
pub fn computeCellMetrics(atlas: *const snail.TextAtlas, font_size: f32) !CellMetrics {
    const cm = try atlas.cellMetrics(.{ .em = font_size });
    return .{
        .cell_width = @ceil(cm.cell_width),
        .cell_height = @ceil(cm.line_height),
    };
}

pub fn computeGridSize(cell_width: f32, cell_height: f32, pixel_w: u32, pixel_h: u32) struct { cols: u16, rows: u16 } {
    return .{
        .cols = @intFromFloat(@max(1.0, @floor(@as(f32, @floatFromInt(pixel_w)) / cell_width))),
        .rows = @intFromFloat(@max(1.0, @floor(@as(f32, @floatFromInt(pixel_h)) / cell_height))),
    };
}

const RowCache = struct {
    blob: snail.TextBlob,
    rects: []ColoredRect,
    content_hash: u64,
    atlas_identity: u64,
    had_misses: bool,
    last_used_frame: u64,
    byte_size: usize,
};

fn hashSnapshotRow(snapshot: *const render_snapshot.SharedSnapshot, start_index: usize, cols: u16) u64 {
    var h: u64 = 0xcbf29ce484222325;
    const m: u64 = 0x100000001b3;
    var i: usize = 0;
    while (i < cols and start_index + i < snapshot.header.cell_count) : (i += 1) {
        const cell = snapshot.cells[start_index + i];
        const bytes = std.mem.asBytes(&cell);
        for (bytes) |b| h = (h ^ b) *% m;
    }
    return h;
}

/// GPU renderer state. Owned exclusively by the GPU renderer thread.
/// Reads the shared atlas (via AtlasRef, lock-free).
pub const Renderer = struct {
    allocator: std.mem.Allocator,
    atlas_ref: *atlas_ref_mod.AtlasRef,

    gl_renderer: snail.GlRenderer,
    scene: snail.Scene,
    builder: snail.TextBlobBuilder,

    prepared: ?snail.PreparedResources = null,
    prepared_atlas_identity: u64 = 0,
    last_atlas_gen: u64 = 0,
    last_atlas_identity: u64 = 0,

    rect_renderer: gl_rect.GlRectRenderer,

    row_cache: std.AutoHashMap(u64, RowCache),
    frame_counter: u64 = 0,
    cache_bytes: usize = 0,
    cache_budget: usize = 32 * 1024 * 1024,

    draw_rects: []ColoredRect = &.{},
    scratch_rects: []ColoredRect = &.{},
    overrides: [MAX_OVERRIDES]snail.Override = undefined,
    resource_entries: [RESOURCE_ENTRY_CAP]snail.ResourceSet.Entry = undefined,

    draw_buf: std.ArrayList(u32) = .empty,
    seg_buf: std.ArrayList(snail.DrawSegment) = .empty,

    // Per-frame ephemeral blob storage (cursor inversion, snapshot rebuilds).
    ephemeral_blobs: std.ArrayList(snail.TextBlob) = .empty,

    run_buf: [2048]u8 = undefined,

    cell_width: f32,
    cell_height: f32,
    font_size: f32,
    viewport_w: f32,
    viewport_h: f32,

    draw_buffers_ready: bool = false,
    framebuffer_srgb: bool = true,
    debug_log_renderers: bool = false,
    debug_log_frames: bool = false,
    debug_log_atlas: bool = false,
    debug_reset_atlas_each_frame: bool = false,

    pub var frame_stats: perf.FrameStats = .{};

    pub fn init(
        allocator: std.mem.Allocator,
        atlas_ref: *atlas_ref_mod.AtlasRef,
        font_size: f32,
        cell_width: f32,
        cell_height: f32,
    ) !Renderer {
        var gl_renderer = try snail.GlRenderer.init(allocator);
        errdefer gl_renderer.deinit();

        const atlas = atlas_ref.load();
        const builder = snail.TextBlobBuilder.init(allocator, atlas);
        var scene = snail.Scene.init(allocator);
        errdefer scene.deinit();

        const rect_renderer = gl_rect.GlRectRenderer.init();

        return .{
            .allocator = allocator,
            .atlas_ref = atlas_ref,
            .gl_renderer = gl_renderer,
            .scene = scene,
            .builder = builder,
            .last_atlas_gen = atlas_ref.loadGeneration(),
            .last_atlas_identity = atlas.snapshotIdentity(),
            .rect_renderer = rect_renderer,
            .row_cache = std.AutoHashMap(u64, RowCache).init(allocator),
            .cell_width = cell_width,
            .cell_height = cell_height,
            .font_size = font_size,
            .viewport_w = 0,
            .viewport_h = 0,
        };
    }

    pub fn deinit(self: *Renderer) void {
        self.clearCache();
        self.row_cache.deinit();
        self.releaseEphemeralBlobs();
        self.ephemeral_blobs.deinit(self.allocator);
        if (self.draw_buffers_ready) {
            self.allocator.free(self.scratch_rects);
            self.allocator.free(self.draw_rects);
        }
        self.draw_buf.deinit(self.allocator);
        self.seg_buf.deinit(self.allocator);
        self.builder.deinit();
        self.scene.deinit();
        if (self.prepared) |*p| p.deinit();
        self.rect_renderer.deinit();
        self.gl_renderer.deinit();
    }

    fn ensureDrawBuffers(self: *Renderer) !void {
        if (self.draw_buffers_ready) return;
        self.draw_rects = try self.allocator.alloc(ColoredRect, MAX_DRAW_RECTS);
        errdefer self.allocator.free(self.draw_rects);
        self.scratch_rects = try self.allocator.alloc(ColoredRect, MAX_RECTS_PER_ROW);
        self.draw_buffers_ready = true;
    }

    fn clearCache(self: *Renderer) void {
        var it = self.row_cache.valueIterator();
        while (it.next()) |e| {
            e.blob.deinit();
            self.allocator.free(e.rects);
        }
        self.row_cache.clearRetainingCapacity();
        self.cache_bytes = 0;
    }

    pub fn setDebugResetAtlas(self: *Renderer, enabled: bool) void {
        self.debug_reset_atlas_each_frame = enabled;
    }

    pub fn setDebugLogs(self: *Renderer, options: render_env.RendererDebug) void {
        self.debug_log_renderers = options.renderers;
        self.debug_log_frames = options.frames;
        self.debug_log_atlas = options.atlas;
    }

    pub fn reconfigure(
        self: *Renderer,
        w: u32,
        h: u32,
        font_size: f32,
        cell_width: f32,
        cell_height: f32,
    ) void {
        self.font_size = font_size;
        self.cell_width = cell_width;
        self.cell_height = cell_height;
        self.viewport_w = @floatFromInt(w);
        self.viewport_h = @floatFromInt(h);
        self.clearCache();
    }

    fn color4(self: *const Renderer, rgb: Rgb, alpha: f32) [4]f32 {
        return if (self.framebuffer_srgb)
            rgb.toLinearFloat4(alpha)
        else
            rgb.toFloat4(alpha);
    }

    fn baseline(self: *const Renderer) f32 {
        return self.cell_height * baseline_factor;
    }

    /// Refresh atlas snapshot. On identity change, rebind cached blobs and
    /// invalidate the prepared resources cache.
    fn refreshAtlas(self: *Renderer) *const snail.TextAtlas {
        const atlas = self.atlas_ref.load();
        const identity = atlas.snapshotIdentity();
        if (identity == self.last_atlas_identity) return atlas;

        self.last_atlas_gen = self.atlas_ref.loadGeneration();
        self.last_atlas_identity = identity;

        // Builder is anchored to the prior snapshot; rebuild it.
        self.builder.deinit();
        self.builder = snail.TextBlobBuilder.init(self.allocator, atlas);

        // Rebind cached blobs (or evict the ones that can't migrate).
        var stale: std.ArrayList(u64) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.row_cache.iterator();
        var rebound: usize = 0;
        while (it.next()) |entry| {
            const cache = entry.value_ptr;
            if (cache.had_misses) {
                stale.append(self.allocator, entry.key_ptr.*) catch {};
                continue;
            }
            cache.blob.rebind(atlas) catch {
                stale.append(self.allocator, entry.key_ptr.*) catch {};
                continue;
            };
            cache.atlas_identity = identity;
            rebound += 1;
        }
        for (stale.items) |k| self.evictRow(k);
        if (self.debug_log_atlas) {
            std.debug.print("mollusk[gpu-renderer]: atlas snapshot {} (rebound={}, evicted={})\n", .{ identity, rebound, stale.items.len });
        }
        return atlas;
    }

    fn evictRow(self: *Renderer, key: u64) void {
        if (self.row_cache.fetchRemove(key)) |kv| {
            var blob = kv.value.blob;
            blob.deinit();
            self.allocator.free(kv.value.rects);
            self.cache_bytes -= kv.value.byte_size;
        }
    }

    fn evictLru(self: *Renderer) void {
        var oldest_key: ?u64 = null;
        var oldest_frame: u64 = std.math.maxInt(u64);
        var it = self.row_cache.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.last_used_frame < oldest_frame) {
                oldest_frame = entry.value_ptr.last_used_frame;
                oldest_key = entry.key_ptr.*;
            }
        }
        if (oldest_key) |k| self.evictRow(k);
    }

    const RunResult = struct { missing: bool };

    fn flushTextRun(self: *Renderer, start_col: u16, run_byte_len: usize, fg: Rgb) !RunResult {
        const x = @as(f32, @floatFromInt(start_col)) * self.cell_width;
        const y = self.baseline();
        const text = self.run_buf[0..run_byte_len];
        const result = try self.builder.addText(.{}, text, x, y, self.font_size, self.color4(fg, 1.0));
        return .{ .missing = result.missing };
    }

    /// Build the row's TextBlob and rect set. Y coordinates are local to the
    /// row (baseline = cell_height * baseline_factor); the caller applies
    /// row_y via Override.transform when submitting.
    fn buildRowFromSnapshot(
        self: *Renderer,
        snapshot: *const render_snapshot.SharedSnapshot,
        cell_index: *usize,
        cols: u16,
        misses: *glyph_misses.Set,
    ) !struct {
        blob: snail.TextBlob,
        rects: []ColoredRect,
        had_misses: bool,
    } {
        self.builder.reset();
        var rect_count: usize = 0;
        var had_misses = false;

        const default_fg = snapshot.header.default_fg;
        const default_bg = snapshot.header.default_bg;

        var bg_span_start: u16 = 0;
        var bg_span_color: ?Rgb = null;
        var bg_span_len: u16 = 0;

        var run_start: u16 = 0;
        var run_fg: ?Rgb = null;
        var run_len: usize = 0;

        var col_idx: u16 = 0;
        while (col_idx < cols and cell_index.* < snapshot.header.cell_count) : ({
            col_idx += 1;
            cell_index.* += 1;
        }) {
            const cell = snapshot.cells[cell_index.*];
            const flags: render_snapshot.CellFlags = @bitCast(cell.flags);
            const resolved = render_common.resolveCellColors(
                default_fg,
                default_bg,
                if (flags.has_fg) cell.fg else null,
                if (flags.has_bg) cell.bg else null,
                flags.inverse,
                flags.faint,
            );
            const fg = resolved.fg;
            const cell_bg = resolved.bg;

            const bg_matches = if (cell_bg) |cbg|
                if (bg_span_color) |sc| sc.r == cbg.r and sc.g == cbg.g and sc.b == cbg.b else false
            else
                false;
            if (cell_bg != null and bg_matches) {
                bg_span_len += 1;
            } else {
                if (bg_span_len > 0) {
                    if (bg_span_color) |sc| {
                        if (rect_count < self.scratch_rects.len) {
                            self.scratch_rects[rect_count] = .{
                                .x = @as(f32, @floatFromInt(bg_span_start)) * self.cell_width,
                                .y = 0,
                                .w = @as(f32, @floatFromInt(bg_span_len)) * self.cell_width,
                                .h = self.cell_height,
                                .color = self.color4(sc, 1.0),
                            };
                            rect_count += 1;
                        }
                    }
                }
                if (cell_bg) |cbg| {
                    bg_span_start = col_idx;
                    bg_span_color = cbg;
                    bg_span_len = 1;
                } else {
                    bg_span_color = null;
                    bg_span_len = 0;
                }
            }

            const has_renderable_text = flags.has_text and cell.codepoint > 0x20 and cell.codepoint < 0x110000;
            const fg_matches = if (run_fg) |rf| rf.r == fg.r and rf.g == fg.g and rf.b == fg.b else false;

            if (!has_renderable_text or !fg_matches or flags.underline or flags.strikethrough) {
                if (run_len > 0) {
                    const result = try self.flushTextRun(run_start, run_len, run_fg.?);
                    if (result.missing) {
                        had_misses = true;
                        misses.addRun(self.run_buf[0..run_len]);
                    }
                    run_len = 0;
                    run_fg = null;
                }
            }

            if (has_renderable_text) {
                if (run_fg == null) {
                    run_start = col_idx;
                    run_fg = fg;
                    run_len = 0;
                }
                const encoded = std.unicode.utf8Encode(@intCast(cell.codepoint), self.run_buf[run_len..]) catch 0;
                if (encoded > 0) run_len += encoded;
            }

            if (flags.underline and rect_count < self.scratch_rects.len) {
                self.scratch_rects[rect_count] = .{
                    .x = @as(f32, @floatFromInt(col_idx)) * self.cell_width,
                    .y = self.cell_height - 1,
                    .w = self.cell_width,
                    .h = 1,
                    .color = self.color4(fg, 1.0),
                };
                rect_count += 1;
            }
            if (flags.strikethrough and rect_count < self.scratch_rects.len) {
                self.scratch_rects[rect_count] = .{
                    .x = @as(f32, @floatFromInt(col_idx)) * self.cell_width,
                    .y = self.cell_height * 0.45,
                    .w = self.cell_width,
                    .h = 1,
                    .color = self.color4(fg, 1.0),
                };
                rect_count += 1;
            }
        }

        if (run_len > 0) {
            const result = try self.flushTextRun(run_start, run_len, run_fg.?);
            if (result.missing) {
                had_misses = true;
                misses.addRun(self.run_buf[0..run_len]);
            }
        }

        if (bg_span_len > 0) {
            if (bg_span_color) |sc| {
                if (rect_count < self.scratch_rects.len) {
                    self.scratch_rects[rect_count] = .{
                        .x = @as(f32, @floatFromInt(bg_span_start)) * self.cell_width,
                        .y = 0,
                        .w = @as(f32, @floatFromInt(bg_span_len)) * self.cell_width,
                        .h = self.cell_height,
                        .color = self.color4(sc, 1.0),
                    };
                    rect_count += 1;
                }
            }
        }

        const blob = try self.builder.finish();
        const rects = try self.allocator.dupe(ColoredRect, self.scratch_rects[0..rect_count]);
        return .{ .blob = blob, .rects = rects, .had_misses = had_misses };
    }

    fn cacheRow(
        self: *Renderer,
        key: u64,
        blob: snail.TextBlob,
        rects: []ColoredRect,
        had_misses: bool,
    ) ?*RowCache {
        if (self.row_cache.fetchRemove(key)) |kv| {
            var prev = kv.value.blob;
            prev.deinit();
            self.allocator.free(kv.value.rects);
            self.cache_bytes -= kv.value.byte_size;
        }

        const byte_size = rects.len * @sizeOf(ColoredRect) + blob.glyphCount() * 24;
        self.row_cache.put(key, .{
            .blob = blob,
            .rects = rects,
            .content_hash = key,
            .atlas_identity = self.last_atlas_identity,
            .had_misses = had_misses,
            .last_used_frame = self.frame_counter,
            .byte_size = byte_size,
        }) catch {
            var b = blob;
            b.deinit();
            self.allocator.free(rects);
            return null;
        };
        self.cache_bytes += byte_size;

        var guard: usize = 0;
        while (self.cache_bytes > self.cache_budget and guard < 32) : (guard += 1) {
            self.evictLru();
        }
        return self.row_cache.getPtr(key);
    }

    fn allocOverrideSlot(self: *Renderer, override_index: *usize, ty: f32) ?[]const snail.Override {
        if (override_index.* >= self.overrides.len) return null;
        self.overrides[override_index.*] = .{
            .transform = snail.Transform2D.translate(0, ty),
            .tint = .{ 1, 1, 1, 1 },
        };
        const slice = self.overrides[override_index.* .. override_index.* + 1];
        override_index.* += 1;
        return slice;
    }

    fn appendCachedRowDraw(
        self: *Renderer,
        cache: *RowCache,
        row_y: f32,
        override_index: *usize,
        rect_index: *usize,
    ) !void {
        cache.last_used_frame = self.frame_counter;
        const ov = self.allocOverrideSlot(override_index, row_y) orelse return error.TooManyDraws;
        try self.scene.addText(.{ .blob = &cache.blob, .instances = ov });
        for (cache.rects) |r| {
            if (rect_index.* >= self.draw_rects.len) break;
            self.draw_rects[rect_index.*] = .{
                .x = r.x,
                .y = r.y + row_y,
                .w = r.w,
                .h = r.h,
                .color = r.color,
            };
            rect_index.* += 1;
        }
    }

    fn appendCursor(
        self: *Renderer,
        rect_index: *usize,
        x: u16,
        y: u16,
        style: terminal_mod.CursorVisualStyle,
        visible: bool,
        in_viewport: bool,
        cursor_color: ?Rgb,
        default_fg: Rgb,
        cursor_cell: ?CursorCell,
    ) !void {
        if (!visible or !in_viewport) return;

        const cx = @as(f32, @floatFromInt(x)) * self.cell_width;
        const cy = @as(f32, @floatFromInt(y)) * self.cell_height;
        const cc = self.color4(cursor_color orelse default_fg, 1.0);

        switch (style) {
            .block => self.pushRect(rect_index, cx, cy, self.cell_width, self.cell_height, cc),
            .bar => self.pushRect(rect_index, cx, cy, 2, self.cell_height, cc),
            .underline => self.pushRect(rect_index, cx, cy + self.cell_height - 2, self.cell_width, 2, cc),
            .block_hollow => {
                self.pushRect(rect_index, cx, cy, self.cell_width, 1.5, cc);
                self.pushRect(rect_index, cx, cy + self.cell_height - 1.5, self.cell_width, 1.5, cc);
                self.pushRect(rect_index, cx, cy, 1.5, self.cell_height, cc);
                self.pushRect(rect_index, cx + self.cell_width - 1.5, cy, 1.5, self.cell_height, cc);
            },
        }

        if (style != .block) return;
        const cell = cursor_cell orelse return;
        if (!cell.has_text or cell.glyph_id == 0) return;

        var inv_builder = snail.TextBlobBuilder.init(self.allocator, self.atlas_ref.load());
        defer inv_builder.deinit();
        var tmp_buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cell.codepoint), &tmp_buf) catch return;
        const result = inv_builder.addText(
            .{},
            tmp_buf[0..n],
            cx,
            cy + self.baseline(),
            self.font_size,
            self.color4(cell.bg, 1.0),
        ) catch return;
        if (result.missing) return;
        const blob = inv_builder.finish() catch return;
        const blob_ptr = self.stashEphemeralBlob(blob) orelse return;
        try self.scene.addText(.{ .blob = blob_ptr });
    }

    fn pushRect(self: *Renderer, idx: *usize, x: f32, y: f32, w: f32, h: f32, cc: [4]f32) void {
        if (idx.* >= self.draw_rects.len) return;
        self.draw_rects[idx.*] = .{ .x = x, .y = y, .w = w, .h = h, .color = cc };
        idx.* += 1;
    }

    fn stashEphemeralBlob(self: *Renderer, blob: snail.TextBlob) ?*const snail.TextBlob {
        // Reserve one slot up front so the slice pointer is stable until reset.
        self.ephemeral_blobs.ensureUnusedCapacity(self.allocator, 1) catch {
            var b = blob;
            b.deinit();
            return null;
        };
        self.ephemeral_blobs.appendAssumeCapacity(blob);
        return &self.ephemeral_blobs.items[self.ephemeral_blobs.items.len - 1];
    }

    fn releaseEphemeralBlobs(self: *Renderer) void {
        for (self.ephemeral_blobs.items) |*b| b.deinit();
        self.ephemeral_blobs.clearRetainingCapacity();
    }

    fn drawOptions(self: *const Renderer) snail.DrawOptions {
        const mvp = snail.Mat4.ortho(0, self.viewport_w, self.viewport_h, 0, -1, 1);
        return .{
            .mvp = mvp,
            .target = .{
                .pixel_width = self.viewport_w,
                .pixel_height = self.viewport_h,
                .subpixel_order = .none, // greyscale AA
            },
        };
    }

    fn refreshPrepared(self: *Renderer) !*const snail.PreparedResources {
        if (self.prepared) |*p| {
            if (self.prepared_atlas_identity == self.last_atlas_identity) return p;
            p.deinit();
            self.prepared = null;
        }
        var rs = snail.ResourceSet.init(self.resource_entries[0..]);
        try rs.addScene(&self.scene);
        self.prepared = try self.gl_renderer.uploadResourcesBlocking(self.allocator, &rs);
        self.prepared_atlas_identity = self.last_atlas_identity;
        return &self.prepared.?;
    }

    fn flushDraw(self: *Renderer, rect_count: usize, default_bg: Rgb) !void {
        const opts = self.drawOptions();
        const bg4 = self.color4(default_bg, 1.0);
        gl.glClearColor(bg4[0], bg4[1], bg4[2], bg4[3]);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        if (rect_count > 0)
            self.rect_renderer.drawRects(self.draw_rects[0..rect_count], opts.mvp);

        const prepared = try self.refreshPrepared();

        const buf_words = snail.DrawList.estimate(&self.scene, opts);
        const seg_count = snail.DrawList.estimateSegments(&self.scene, opts);
        try self.draw_buf.resize(self.allocator, buf_words);
        try self.seg_buf.resize(self.allocator, seg_count);
        var draw_list = snail.DrawList.init(self.draw_buf.items, self.seg_buf.items);
        try draw_list.addScene(prepared, &self.scene, opts);
        try self.gl_renderer.draw(prepared, draw_list.slice(), opts);

        gl.glFlush();
    }

    pub fn drawSnapshot(self: *Renderer, snapshot: *const render_snapshot.SharedSnapshot, misses: *glyph_misses.Set) !void {
        const frame_timer = perf.Timer.now();
        self.frame_counter += 1;
        _ = self.refreshAtlas();
        try self.ensureDrawBuffers();
        self.scene.reset();

        var override_index: usize = 0;
        var rect_index: usize = 0;

        const header = snapshot.header;
        const default_fg = header.default_fg;
        const default_bg = header.default_bg;
        const rows = @min(header.rows, render_snapshot.MaxRows);
        const cols = @min(header.cols, render_snapshot.MaxCols);

        var cell_index: usize = 0;
        var cursor_cell: ?CursorCell = null;

        var row_idx: u16 = 0;
        while (row_idx < rows) : (row_idx += 1) {
            const row_y = @as(f32, @floatFromInt(row_idx)) * self.cell_height;
            const row_start_index = cell_index;

            if (header.cursor_visible != 0 and header.cursor_in_viewport != 0 and row_idx == header.cursor_y) {
                const cursor_col = header.cursor_x;
                if (cursor_col < cols and row_start_index + cursor_col < header.cell_count) {
                    const cell = snapshot.cells[row_start_index + cursor_col];
                    const flags: render_snapshot.CellFlags = @bitCast(cell.flags);
                    const resolved = render_common.resolveCellColors(
                        default_fg,
                        default_bg,
                        if (flags.has_fg) cell.fg else null,
                        if (flags.has_bg) cell.bg else null,
                        flags.inverse,
                        flags.faint,
                    );
                    cursor_cell = render_common.captureCursorCell(default_bg, cell.codepoint, cell.glyph_id, flags.has_text, resolved);
                }
            }

            const content_hash = hashSnapshotRow(snapshot, row_start_index, cols);
            // Re-emit cell_index past this row regardless of whether we use the cache.
            const next_index = row_start_index + @min(@as(usize, cols), header.cell_count -| row_start_index);

            if (self.row_cache.getPtr(content_hash)) |cache| {
                if (!cache.had_misses and cache.atlas_identity == self.last_atlas_identity) {
                    try self.appendCachedRowDraw(cache, row_y, &override_index, &rect_index);
                    cell_index = next_index;
                    continue;
                }
            }

            const built = try self.buildRowFromSnapshot(snapshot, &cell_index, cols, misses);
            cell_index = next_index;
            if (self.cacheRow(content_hash, built.blob, built.rects, built.had_misses)) |cache| {
                try self.appendCachedRowDraw(cache, row_y, &override_index, &rect_index);
            }
        }

        try self.appendCursor(
            &rect_index,
            header.cursor_x,
            header.cursor_y,
            switch (header.cursor_style) {
                .bar => .bar,
                .block => .block,
                .underline => .underline,
                .block_hollow => .block_hollow,
            },
            header.cursor_visible != 0,
            header.cursor_in_viewport != 0,
            if (header.cursor_has_color != 0) header.cursor_color else null,
            default_fg,
            cursor_cell,
        );

        if (!misses.isEmpty()) {
            self.releaseEphemeralBlobs();
            return;
        }

        try self.flushDraw(rect_index, default_bg);
        self.releaseEphemeralBlobs();
        frame_stats.record(frame_timer.elapsedUs());
    }
};
