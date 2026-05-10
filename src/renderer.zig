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
const fc = @cImport(@cInclude("fontconfig/fontconfig.h"));

fn detectSubpixelOrder() snail.SubpixelOrder {
    const pattern = fc.FcNameParse(":") orelse return .rgb;
    defer fc.FcPatternDestroy(pattern);
    _ = fc.FcConfigSubstitute(null, pattern, fc.FcMatchPattern);
    fc.FcDefaultSubstitute(pattern);
    var rgba: c_int = undefined;
    if (fc.FcPatternGetInteger(pattern, fc.FC_RGBA, 0, &rgba) != fc.FcResultMatch) return .rgb;
    return switch (rgba) {
        fc.FC_RGBA_RGB => .rgb,
        fc.FC_RGBA_BGR => .bgr,
        fc.FC_RGBA_VRGB => .vrgb,
        fc.FC_RGBA_VBGR => .vbgr,
        fc.FC_RGBA_NONE => .none,
        else => .rgb,
    };
}

fn hashColors(colors: terminal_mod.RenderColors) u64 {
    var h: u64 = 0xcbf29ce484222325;
    const m: u64 = 0x100000001b3;
    inline for (.{ colors.foreground, colors.background }) |c| {
        h = (h ^ c.r) *% m;
        h = (h ^ c.g) *% m;
        h = (h ^ c.b) *% m;
    }
    if (colors.cursor) |c| {
        h = (h ^ c.r) *% m;
        h = (h ^ c.g) *% m;
        h = (h ^ c.b) *% m;
    }
    for (&colors.palette) |c| {
        h = (h ^ c.r) *% m;
        h = (h ^ c.g) *% m;
        h = (h ^ c.b) *% m;
    }
    return h;
}

const CacheEntry = struct {
    text: []f32,
    rects: []ColoredRect,
    generation: u64,
    byte_size: usize,
};

// Snail vertex layout constants for Y-patching.
// Text: 4 vertices * 20 floats. Y is at offset 1 within each vertex.
const TEXT_VERTEX_STRIDE = 20;
const TEXT_Y_OFFSETS = [4]usize{ 1, 21, 41, 61 };
const empty_f32_slice: []f32 = @constCast((&[_]f32{})[0..]);
const empty_rect_slice: []ColoredRect = @constCast((&[_]ColoredRect{})[0..]);

/// Patch Y coordinates in text vertex data by adding delta.
fn patchTextY(data: []f32, delta: f32) void {
    const floats_per_glyph = TEXT_VERTEX_STRIDE * 4;
    var i: usize = 0;
    while (i + floats_per_glyph <= data.len) : (i += floats_per_glyph) {
        inline for (TEXT_Y_OFFSETS) |off| {
            data[i + off] += delta;
        }
    }
}

/// Patch Y coordinates in ColoredRect array by adding delta.
fn patchRectY(rects: []ColoredRect, delta: f32) void {
    for (rects) |*r| r.y += delta;
}

/// Compute font cell metrics from font tables alone (no atlas needed).
pub fn computeCellMetrics(font: *const snail.Font, font_size: f32) struct { cell_width: f32, cell_height: f32 } {
    const units_per_em: f32 = @floatFromInt(font.unitsPerEm());
    const scale = font_size / units_per_em;
    const m_gid = font.glyphIndex('M') catch 0;
    const advance = if (m_gid != 0) (font.advanceWidth(m_gid) catch null) else null;
    return .{
        .cell_width = if (advance) |a| @ceil(@as(f32, @floatFromInt(a)) * scale) else @ceil(font_size * 0.6),
        .cell_height = @ceil(font_size * 1.2),
    };
}

/// Compute grid dimensions from cell metrics and pixel size.
pub fn computeGridSize(cell_width: f32, cell_height: f32, pixel_w: u32, pixel_h: u32) struct { cols: u16, rows: u16 } {
    return .{
        .cols = @intFromFloat(@max(1.0, @floor(@as(f32, @floatFromInt(pixel_w)) / cell_width))),
        .rows = @intFromFloat(@max(1.0, @floor(@as(f32, @floatFromInt(pixel_h)) / cell_height))),
    };
}

// Max rects per row: backgrounds + underlines + strikethrough = 3 * max_cols
const MAX_RECTS_PER_ROW = 400 * 3;
const MAX_DRAW_RECTS = 400 * 200 * 3 + 16; // all rows + cursor etc.

/// GPU renderer state. Owned exclusively by the GPU renderer thread.
/// Reads the shared font (immutable) and atlas (via AtlasRef, lock-free).
pub const Renderer = struct {
    // Shared references (not owned)
    font: *const snail.Font,
    atlas_ref: *atlas_ref_mod.AtlasRef,

    // GPU-private state
    snail_renderer: snail.Renderer,
    atlas_handle: snail.AtlasHandle = .{ .atlas = undefined, .layer_base = 0 },
    atlas_generation: u64 = 0,

    rect_renderer: gl_rect.GlRectRenderer,

    row_cache: std.AutoHashMap(u64, CacheEntry),
    generation: u64 = 0,
    color_hash: u64 = 0,
    cache_bytes: usize = 0,
    cache_budget: usize = 32 * 1024 * 1024,

    draw_text: []f32,
    scratch_text: []f32,
    draw_rects: []ColoredRect,
    scratch_rects: []ColoredRect,

    // Scratch buffer for building UTF-8 text runs
    run_buf: [2048]u8 = undefined,

    cell_width: f32,
    cell_height: f32,
    font_size: f32,
    viewport_w: f32,
    viewport_h: f32,

    allocator: std.mem.Allocator,
    max_cols: u16,
    draw_buffers_ready: bool = false,
    framebuffer_srgb: bool = true,
    debug_log_renderers: bool = false,
    debug_log_frames: bool = false,
    debug_log_atlas: bool = false,
    debug_reset_atlas_each_frame: bool = false,
    has_prev_frame: bool = false,
    prev_cursor_x: u16 = 0,
    prev_cursor_y: u16 = 0,
    prev_cursor_style: terminal_mod.CursorVisualStyle = .block,
    prev_cursor_visible: bool = false,
    prev_cursor_in_viewport: bool = false,

    pub var frame_stats: perf.FrameStats = .{};

    /// Initialize the GPU renderer. Requires an active EGL/GL context.
    pub fn init(
        allocator: std.mem.Allocator,
        font: *const snail.Font,
        atlas_ref: *atlas_ref_mod.AtlasRef,
        font_size: f32,
        cell_width: f32,
        cell_height: f32,
    ) !Renderer {
        var snail_renderer = try snail.Renderer.init();
        errdefer snail_renderer.deinit();

        const atlas = atlas_ref.load();
        const atlas_handle = snail_renderer.uploadAtlas(atlas);
        snail_renderer.setSubpixelOrder(detectSubpixelOrder());
        snail_renderer.setFillRule(.non_zero);

        const rect_renderer = gl_rect.GlRectRenderer.init();

        return .{
            .font = font,
            .atlas_ref = atlas_ref,
            .snail_renderer = snail_renderer,
            .atlas_handle = atlas_handle,
            .atlas_generation = atlas_ref.loadGeneration(),
            .rect_renderer = rect_renderer,
            .row_cache = std.AutoHashMap(u64, CacheEntry).init(allocator),
            .draw_text = empty_f32_slice,
            .scratch_text = empty_f32_slice,
            .draw_rects = empty_rect_slice,
            .scratch_rects = empty_rect_slice,
            .cell_width = cell_width,
            .cell_height = cell_height,
            .font_size = font_size,
            .viewport_w = 0,
            .viewport_h = 0,
            .allocator = allocator,
            .max_cols = 400,
        };
    }

    /// Load the current atlas from AtlasRef. Re-upload to GPU if generation changed.
    fn refreshAtlas(self: *Renderer) *const snail.Atlas {
        const gen = self.atlas_ref.loadGeneration();
        const atlas = self.atlas_ref.load();
        if (gen != self.atlas_generation) {
            self.atlas_handle = self.snail_renderer.uploadAtlas(atlas);
            self.atlas_generation = gen;
            self.generation += 1;
            self.has_prev_frame = false;
            self.prev_cursor_visible = false;
            self.prev_cursor_in_viewport = false;
            self.clearCache();
            if (self.debug_log_atlas) {
                std.debug.print("mollusk[gpu-renderer]: atlas re-uploaded gen={}\n", .{gen});
            }
        }
        return atlas;
    }

    fn color4(self: *const Renderer, rgb: Rgb, alpha: f32) [4]f32 {
        return if (self.framebuffer_srgb)
            rgb.toLinearFloat4(alpha)
        else
            rgb.toFloat4(alpha);
    }

    pub fn deinit(self: *Renderer) void {
        self.clearCache();
        self.row_cache.deinit();
        if (self.draw_buffers_ready) {
            self.allocator.free(self.scratch_rects);
            self.allocator.free(self.scratch_text);
            self.allocator.free(self.draw_rects);
            self.allocator.free(self.draw_text);
        }
        self.rect_renderer.deinit();
        self.snail_renderer.deinit();
    }

    pub fn ensureDrawBuffers(self: *Renderer) !void {
        if (self.draw_buffers_ready) return;
        const max_cells: usize = 400 * 200;
        self.draw_text = try self.allocator.alloc(f32, max_cells * snail.TEXT_FLOATS_PER_GLYPH);
        errdefer self.allocator.free(self.draw_text);
        self.draw_rects = try self.allocator.alloc(ColoredRect, MAX_DRAW_RECTS);
        errdefer self.allocator.free(self.draw_rects);
        self.scratch_text = try self.allocator.alloc(f32, @as(usize, self.max_cols) * snail.TEXT_FLOATS_PER_GLYPH);
        errdefer self.allocator.free(self.scratch_text);
        self.scratch_rects = try self.allocator.alloc(ColoredRect, MAX_RECTS_PER_ROW);
        self.draw_buffers_ready = true;
    }

    pub fn clearCache(self: *Renderer) void {
        var it = self.row_cache.valueIterator();
        while (it.next()) |e| {
            self.allocator.free(e.text);
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
        self.has_prev_frame = false;
        self.prev_cursor_visible = false;
        self.prev_cursor_in_viewport = false;
        self.generation += 1;
        self.clearCache();
    }

    fn snapshotCursorStyle(style: render_snapshot.CursorStyle) terminal_mod.CursorVisualStyle {
        return switch (style) {
            .bar => .bar,
            .block => .block,
            .underline => .underline,
            .block_hollow => .block_hollow,
        };
    }

    fn appendCursorOverlay(
        self: *Renderer,
        atlas: *const snail.Atlas,
        draw_text_len: *usize,
        draw_rect_len: *usize,
        x: u16,
        y: u16,
        style: terminal_mod.CursorVisualStyle,
        visible: bool,
        in_viewport: bool,
        cursor_color: ?Rgb,
        default_fg: Rgb,
        default_bg: Rgb,
        cursor_cell: ?CursorCell,
    ) void {
        if (!visible or !in_viewport) return;

        const cx = @as(f32, @floatFromInt(x)) * self.cell_width;
        const cy = @as(f32, @floatFromInt(y)) * self.cell_height;
        const cc = self.color4(cursor_color orelse default_fg, 1.0);

        switch (style) {
            .block => self.draw_rects[draw_rect_len.*] = .{ .x = cx, .y = cy, .w = self.cell_width, .h = self.cell_height, .color = cc },
            .bar => self.draw_rects[draw_rect_len.*] = .{ .x = cx, .y = cy, .w = 2, .h = self.cell_height, .color = cc },
            .underline => self.draw_rects[draw_rect_len.*] = .{ .x = cx, .y = cy + self.cell_height - 2, .w = self.cell_width, .h = 2, .color = cc },
            .block_hollow => {
                // Draw 4 edges for hollow cursor
                self.draw_rects[draw_rect_len.*] = .{ .x = cx, .y = cy, .w = self.cell_width, .h = 1.5, .color = cc };
                draw_rect_len.* += 1;
                self.draw_rects[draw_rect_len.*] = .{ .x = cx, .y = cy + self.cell_height - 1.5, .w = self.cell_width, .h = 1.5, .color = cc };
                draw_rect_len.* += 1;
                self.draw_rects[draw_rect_len.*] = .{ .x = cx, .y = cy, .w = 1.5, .h = self.cell_height, .color = cc };
                draw_rect_len.* += 1;
                self.draw_rects[draw_rect_len.*] = .{ .x = cx + self.cell_width - 1.5, .y = cy, .w = 1.5, .h = self.cell_height, .color = cc };
            },
        }
        draw_rect_len.* += 1;

        if (style != .block) return;
        const cell = cursor_cell orelse return;
        if (!cell.has_text or cell.glyph_id == 0) return;
        const info = atlas.getGlyph(cell.glyph_id) orelse return;
        const cursor_text_y = @as(f32, @floatFromInt(y)) * self.cell_height + self.cell_height * 0.8;
        var inv_buf: [snail.TEXT_FLOATS_PER_GLYPH]f32 = undefined;
        var inv_batch = snail.TextBatch.init(&inv_buf);
        _ = inv_batch.addGlyph(
            cx,
            cursor_text_y,
            self.font_size,
            info.bbox,
            info.band_entry,
            self.color4(cell.bg, 1.0),
            self.atlas_handle.glyphLayer(info.page_index),
        );
        @memcpy(self.draw_text[draw_text_len.*..][0..snail.TEXT_FLOATS_PER_GLYPH], inv_batch.slice());
        draw_text_len.* += snail.TEXT_FLOATS_PER_GLYPH;
        _ = default_bg;
    }

    /// Build row vertices into scratch buffers at Y=0 (position-independent).
    /// Uses TextBatch.addText for shaped text runs with ligatures.
    fn buildRow(
        self: *Renderer,
        term: *Terminal,
        default_fg: Rgb,
        default_bg: Rgb,
        misses: *glyph_misses.Set,
    ) struct { text_len: usize, rect_len: usize } {
        const cell_y: f32 = 0;

        var text_batch = snail.TextBatch.init(self.scratch_text);
        var rect_count: usize = 0;

        var bg_span_start: u16 = 0;
        var bg_span_color: ?Rgb = null;
        var bg_span_len: u16 = 0;

        // Text run state: collect consecutive cells with same fg color
        var run_start: u16 = 0;
        var run_fg: ?Rgb = null;
        var run_len: usize = 0;

        term.beginCellIteration();
        var col_idx: u16 = 0;
        while (term.nextCell()) : (col_idx += 1) {
            const cell = term.getCellInfo();

            var fg = cell.fg orelse default_fg;
            var cell_bg = cell.bg;
            if (cell.style.inverse != false) {
                const tmp = fg;
                fg = cell_bg orelse default_bg;
                cell_bg = tmp;
            }
            if (cell.style.faint != false) fg = .{
                .r = @intFromFloat(@as(f32, @floatFromInt(fg.r)) * 0.5),
                .g = @intFromFloat(@as(f32, @floatFromInt(fg.g)) * 0.5),
                .b = @intFromFloat(@as(f32, @floatFromInt(fg.b)) * 0.5),
            };

            // BG coalescing
            const bg_matches = if (cell_bg) |cbg|
                (if (bg_span_color) |sc| sc.r == cbg.r and sc.g == cbg.g and sc.b == cbg.b else false)
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
                                .y = cell_y,
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

            // Check if this cell breaks the current text run (color change or non-text)
            const has_renderable_text = cell.has_text and cell.codepoint > 0x20 and cell.codepoint < 0x110000;
            const fg_matches = if (run_fg) |rf| rf.r == fg.r and rf.g == fg.g and rf.b == fg.b else false;

            if (!has_renderable_text or !fg_matches or cell.style.underline != 0 or cell.style.strikethrough != false) {
                // Flush current text run
                if (run_len > 0) {
                    self.flushTextRun(&text_batch, run_start, run_len, cell_y, run_fg.?, misses);
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
                // Encode codepoint to run_buf
                const encoded = std.unicode.utf8Encode(@intCast(cell.codepoint), self.run_buf[run_len..]) catch 0;
                if (encoded > 0) {
                    run_len += encoded;
                } else {
                    // Encoding failed, flush and skip
                    if (run_len > 0) {
                        self.flushTextRun(&text_batch, run_start, run_len, cell_y, run_fg.?, misses);
                        run_len = 0;
                        run_fg = null;
                    }
                }

                if (cell.style.underline != 0) {
                    if (rect_count < self.scratch_rects.len) {
                        self.scratch_rects[rect_count] = .{
                            .x = @as(f32, @floatFromInt(col_idx)) * self.cell_width,
                            .y = cell_y + self.cell_height - 1,
                            .w = self.cell_width,
                            .h = 1,
                            .color = self.color4(fg, 1.0),
                        };
                        rect_count += 1;
                    }
                }
                if (cell.style.strikethrough != false) {
                    if (rect_count < self.scratch_rects.len) {
                        self.scratch_rects[rect_count] = .{
                            .x = @as(f32, @floatFromInt(col_idx)) * self.cell_width,
                            .y = cell_y + self.cell_height * 0.45,
                            .w = self.cell_width,
                            .h = 1,
                            .color = self.color4(fg, 1.0),
                        };
                        rect_count += 1;
                    }
                }
            }
        }

        // Flush final text run
        if (run_len > 0) {
            self.flushTextRun(&text_batch, run_start, run_len, cell_y, run_fg.?, misses);
        }

        // Flush final bg span
        if (bg_span_len > 0) {
            if (bg_span_color) |sc| {
                if (rect_count < self.scratch_rects.len) {
                    self.scratch_rects[rect_count] = .{
                        .x = @as(f32, @floatFromInt(bg_span_start)) * self.cell_width,
                        .y = cell_y,
                        .w = @as(f32, @floatFromInt(bg_span_len)) * self.cell_width,
                        .h = self.cell_height,
                        .color = self.color4(sc, 1.0),
                    };
                    rect_count += 1;
                }
            }
        }

        return .{
            .text_len = text_batch.glyphCount() * snail.TEXT_FLOATS_PER_GLYPH,
            .rect_len = rect_count,
        };
    }

    fn flushTextRun(
        self: *Renderer,
        batch: *snail.TextBatch,
        start_col: u16,
        run_byte_len: usize,
        y_base: f32,
        fg: Rgb,
        misses: *glyph_misses.Set,
    ) void {
        const x = @as(f32, @floatFromInt(start_col)) * self.cell_width;
        const y = y_base + self.cell_height * 0.8;
        const text = self.run_buf[0..run_byte_len];
        const glyphs_before = batch.glyphCount();
        _ = batch.addText(&self.atlas_handle, self.font, text, x, y, self.font_size, self.color4(fg, 1.0));
        if (batch.glyphCount() == glyphs_before) {
            // addText emitted nothing — glyphs are missing. Send the
            // text to the atlas thread so extendText can discover them
            // (including ligature substitutions via HarfBuzz).
            misses.addRun(text);
        }
    }

    fn cacheRow(self: *Renderer, row_id: u64, text_len: usize, rect_len: usize) void {
        if (self.row_cache.fetchRemove(row_id)) |kv| {
            self.cache_bytes -= kv.value.byte_size;
            self.allocator.free(kv.value.text);
            self.allocator.free(kv.value.rects);
        }

        const text = self.allocator.dupe(f32, self.scratch_text[0..text_len]) catch return;
        const rects = self.allocator.dupe(ColoredRect, self.scratch_rects[0..rect_len]) catch {
            self.allocator.free(text);
            return;
        };
        const byte_size = text_len * @sizeOf(f32) + rect_len * @sizeOf(ColoredRect);
        self.row_cache.put(row_id, .{
            .text = text,
            .rects = rects,
            .generation = self.generation,
            .byte_size = byte_size,
        }) catch {
            self.allocator.free(text);
            self.allocator.free(rects);
            return;
        };
        self.cache_bytes += byte_size;

        while (self.cache_bytes > self.cache_budget) {
            var evict_it = self.row_cache.iterator();
            if (evict_it.next()) |entry| {
                self.cache_bytes -= entry.value_ptr.byte_size;
                self.allocator.free(entry.value_ptr.text);
                self.allocator.free(entry.value_ptr.rects);
                self.row_cache.removeByPtr(entry.key_ptr);
            } else break;
        }
    }

    /// Copy cached vertex data into draw buffers, applying Y offset.
    fn appendCached(
        self: *Renderer,
        entry: CacheEntry,
        text_y_delta: f32,
        rect_y_delta: f32,
        draw_text_len: *usize,
        draw_rect_len: *usize,
    ) void {
        if (entry.rects.len > 0) {
            const dst = self.draw_rects[draw_rect_len.*..][0..entry.rects.len];
            @memcpy(dst, entry.rects);
            patchRectY(dst, rect_y_delta);
            draw_rect_len.* += entry.rects.len;
        }
        if (entry.text.len > 0) {
            @memcpy(self.draw_text[draw_text_len.*..][0..entry.text.len], entry.text);
            patchTextY(self.draw_text[draw_text_len.*..][0..entry.text.len], text_y_delta);
            draw_text_len.* += entry.text.len;
        }
    }

    pub fn drawFrame(self: *Renderer, term: *Terminal) !bool {
        return try self.drawFrameInner(term);
    }

    fn drawFrameInner(self: *Renderer, term: *Terminal) !bool {
        const frame_timer = perf.Timer.now();
        const atlas = self.refreshAtlas();
        try self.ensureDrawBuffers();

        try term.updateRenderState();
        const dirty = term.getDirty();
        const cursor = term.getCursor();
        const colors = term.getColors();

        const cursor_changed = cursor.x != self.prev_cursor_x or
            cursor.y != self.prev_cursor_y or
            @intFromEnum(cursor.style) != @intFromEnum(self.prev_cursor_style) or
            cursor.visible != self.prev_cursor_visible or
            cursor.in_viewport != self.prev_cursor_in_viewport;

        const new_hash = hashColors(colors);
        const colors_changed = new_hash != self.color_hash;
        if (dirty == .false_ and !cursor_changed and !colors_changed) return false;

        const default_fg = colors.foreground;
        const default_bg = colors.background;

        if (colors_changed) {
            self.generation += 1;
            self.color_hash = new_hash;
        }

        var draw_text_len: usize = 0;
        var draw_rect_len: usize = 0;
        var cursor_cell: ?CursorCell = null;
        var misses: glyph_misses.Set = .{};

        term.beginRowIteration();
        var row_idx: u16 = 0;
        while (term.nextRow()) : (row_idx += 1) {
            if (row_idx >= 200) break;
            const row_id = term.getRowId();

            const row_y = @as(f32, @floatFromInt(row_idx)) * self.cell_height;

            const needs_rebuild = dirty == .full or !self.has_prev_frame or
                term.isRowDirty();

            if (!needs_rebuild) {
                if (self.row_cache.get(row_id)) |entry| {
                    if (entry.generation == self.generation) {
                        if (cursor.visible and cursor.in_viewport and row_idx == cursor.y) {
                            term.beginCellIteration();
                            if (term.selectCell(cursor.x)) {
                                const cell = term.getCellInfo();
                                const resolved = render_common.resolveCellColors(
                                    default_fg,
                                    default_bg,
                                    cell.fg,
                                    cell.bg,
                                    cell.style.inverse != false,
                                    cell.style.faint != false,
                                );
                                const glyph_id: u16 = if (cell.has_text and render_common.isRenderableCodepoint(cell.codepoint))
                                    (self.font.glyphIndex(cell.codepoint) catch 0)
                                else
                                    0;
                                cursor_cell = render_common.captureCursorCell(default_bg, cell.codepoint, glyph_id, cell.has_text, resolved);
                            }
                        }
                        self.appendCached(entry, row_y, row_y, &draw_text_len, &draw_rect_len);
                        continue;
                    }
                }
            }

            const lens = self.buildRow(term, default_fg, default_bg, &misses);

            self.cacheRow(row_id, lens.text_len, lens.rect_len);

            if (cursor.visible and cursor.in_viewport and row_idx == cursor.y) {
                term.beginCellIteration();
                if (term.selectCell(cursor.x)) {
                    const cell = term.getCellInfo();
                    const resolved = render_common.resolveCellColors(
                        default_fg,
                        default_bg,
                        cell.fg,
                        cell.bg,
                        cell.style.inverse != false,
                        cell.style.faint != false,
                    );
                    const glyph_id: u16 = if (cell.has_text and render_common.isRenderableCodepoint(cell.codepoint))
                        (self.font.glyphIndex(cell.codepoint) catch 0)
                    else
                        0;
                    cursor_cell = render_common.captureCursorCell(default_bg, cell.codepoint, glyph_id, cell.has_text, resolved);
                }
            }

            if (lens.rect_len > 0) {
                const dst = self.draw_rects[draw_rect_len..][0..lens.rect_len];
                @memcpy(dst, self.scratch_rects[0..lens.rect_len]);
                patchRectY(dst, row_y);
                draw_rect_len += lens.rect_len;
            }
            if (lens.text_len > 0) {
                @memcpy(self.draw_text[draw_text_len..][0..lens.text_len], self.scratch_text[0..lens.text_len]);
                patchTextY(self.draw_text[draw_text_len..][0..lens.text_len], row_y);
                draw_text_len += lens.text_len;
            }
        }

        self.has_prev_frame = true;
        self.prev_cursor_x = cursor.x;
        self.prev_cursor_y = cursor.y;
        self.prev_cursor_style = cursor.style;
        self.prev_cursor_visible = cursor.visible;
        self.prev_cursor_in_viewport = cursor.in_viewport;
        self.appendCursorOverlay(
            atlas,
            &draw_text_len,
            &draw_rect_len,
            cursor.x,
            cursor.y,
            cursor.style,
            cursor.visible,
            cursor.in_viewport,
            colors.cursor,
            default_fg,
            default_bg,
            cursor_cell,
        );

        if (draw_text_len == 0 and draw_rect_len == 0) {
            if (self.debug_log_frames) {
                std.debug.print("mollusk: skipped blank frame (rows={}, dirty={}, has_prev={})\n", .{ row_idx, @intFromEnum(dirty), self.has_prev_frame });
            }
            return false;
        }

        // Draw
        const bg4 = self.color4(colors.background, 1.0);
        gl.glClearColor(bg4[0], bg4[1], bg4[2], bg4[3]);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        // Unified Y-down (top-left origin) MVP for both rects and text (snail v0.2.0)
        const mvp = snail.Mat4.ortho(0, self.viewport_w, self.viewport_h, 0, -1, 1);

        if (draw_rect_len > 0)
            self.rect_renderer.drawRects(self.draw_rects[0..draw_rect_len], mvp);

        self.snail_renderer.beginFrame();
        if (draw_text_len > 0)
            self.snail_renderer.drawText(self.draw_text[0..draw_text_len], mvp, self.viewport_w, self.viewport_h);

        gl.glFlush();
        term.resetDirty();
        frame_stats.record(frame_timer.elapsedUs());
        return true;
    }

    pub fn drawSnapshot(self: *Renderer, snapshot: *const render_snapshot.SharedSnapshot, misses: *glyph_misses.Set) !void {
        const atlas = self.refreshAtlas();
        try self.ensureDrawBuffers();
        const header = snapshot.header;
        const default_fg = header.default_fg;
        const default_bg = header.default_bg;

        var draw_text_len: usize = 0;
        var draw_rect_len: usize = 0;
        var cell_index: usize = 0;
        var cursor_cell: ?CursorCell = null;

        const rows = @min(header.rows, render_snapshot.MaxRows);
        const cols = @min(header.cols, render_snapshot.MaxCols);

        var row_idx: u16 = 0;
        while (row_idx < rows) : (row_idx += 1) {
            const cell_y = @as(f32, @floatFromInt(row_idx)) * self.cell_height;

            var text_batch = snail.TextBatch.init(self.draw_text[draw_text_len..]);
            var rect_count: usize = 0;

            var bg_span_start: u16 = 0;
            var bg_span_color: ?Rgb = null;
            var bg_span_len: u16 = 0;

            // Text run state for this row
            var run_start: u16 = 0;
            var run_fg: ?Rgb = null;
            var run_len: usize = 0;

            var col_idx: u16 = 0;
            while (col_idx < cols and cell_index < header.cell_count) : ({
                col_idx += 1;
                cell_index += 1;
            }) {
                const cell = snapshot.cells[cell_index];
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
                if (header.cursor_visible != 0 and header.cursor_in_viewport != 0 and
                    row_idx == header.cursor_y and col_idx == header.cursor_x)
                {
                    cursor_cell = render_common.captureCursorCell(default_bg, cell.codepoint, cell.glyph_id, flags.has_text, resolved);
                }

                // BG coalescing
                const bg_matches = if (cell_bg) |cbg|
                    if (bg_span_color) |sc| sc.r == cbg.r and sc.g == cbg.g and sc.b == cbg.b else false
                else
                    false;

                if (cell_bg != null and bg_matches) {
                    bg_span_len += 1;
                } else {
                    if (bg_span_len > 0) {
                        if (bg_span_color) |sc| {
                            if (draw_rect_len + rect_count < self.draw_rects.len) {
                                self.draw_rects[draw_rect_len + rect_count] = .{
                                    .x = @as(f32, @floatFromInt(bg_span_start)) * self.cell_width,
                                    .y = cell_y,
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

                // Check if this cell breaks the text run
                const has_renderable_text = flags.has_text and cell.codepoint > 0x20 and cell.codepoint < 0x110000;
                const fg_matches_run = if (run_fg) |rf| rf.r == fg.r and rf.g == fg.g and rf.b == fg.b else false;

                if (!has_renderable_text or !fg_matches_run or flags.underline or flags.strikethrough) {
                    // Flush text run
                    if (run_len > 0) {
                        const run_text = self.run_buf[0..run_len];
                        const x = @as(f32, @floatFromInt(run_start)) * self.cell_width;
                        const y = cell_y + self.cell_height * 0.8;
                        const before = text_batch.glyphCount();
                        _ = text_batch.addText(&self.atlas_handle, self.font, run_text, x, y, self.font_size, self.color4(run_fg.?, 1.0));
                        if (text_batch.glyphCount() == before) misses.addRun(run_text);
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
                    if (encoded > 0) {
                        run_len += encoded;
                    }
                }

                if (flags.underline) {
                    if (draw_rect_len + rect_count < self.draw_rects.len) {
                        self.draw_rects[draw_rect_len + rect_count] = .{
                            .x = @as(f32, @floatFromInt(col_idx)) * self.cell_width,
                            .y = cell_y + self.cell_height - 1,
                            .w = self.cell_width,
                            .h = 1,
                            .color = self.color4(fg, 1.0),
                        };
                        rect_count += 1;
                    }
                }
                if (flags.strikethrough) {
                    if (draw_rect_len + rect_count < self.draw_rects.len) {
                        self.draw_rects[draw_rect_len + rect_count] = .{
                            .x = @as(f32, @floatFromInt(col_idx)) * self.cell_width,
                            .y = cell_y + self.cell_height * 0.45,
                            .w = self.cell_width,
                            .h = 1,
                            .color = self.color4(fg, 1.0),
                        };
                        rect_count += 1;
                    }
                }
            }

            // Flush final text run for this row
            if (run_len > 0) {
                const run_text = self.run_buf[0..run_len];
                const x = @as(f32, @floatFromInt(run_start)) * self.cell_width;
                const y = cell_y + self.cell_height * 0.8;
                const before = text_batch.glyphCount();
                _ = text_batch.addText(&self.atlas_handle, self.font, run_text, x, y, self.font_size, self.color4(run_fg.?, 1.0));
                if (text_batch.glyphCount() == before) misses.addRun(run_text);
            }

            // Flush final bg span
            if (bg_span_len > 0) {
                if (bg_span_color) |sc| {
                    if (draw_rect_len + rect_count < self.draw_rects.len) {
                        self.draw_rects[draw_rect_len + rect_count] = .{
                            .x = @as(f32, @floatFromInt(bg_span_start)) * self.cell_width,
                            .y = cell_y,
                            .w = @as(f32, @floatFromInt(bg_span_len)) * self.cell_width,
                            .h = self.cell_height,
                            .color = self.color4(sc, 1.0),
                        };
                        rect_count += 1;
                    }
                }
            }

            draw_text_len += text_batch.glyphCount() * snail.TEXT_FLOATS_PER_GLYPH;
            draw_rect_len += rect_count;
        }

        self.appendCursorOverlay(
            atlas,
            &draw_text_len,
            &draw_rect_len,
            header.cursor_x,
            header.cursor_y,
            snapshotCursorStyle(header.cursor_style),
            header.cursor_visible != 0,
            header.cursor_in_viewport != 0,
            if (header.cursor_has_color != 0) header.cursor_color else null,
            default_fg,
            default_bg,
            cursor_cell,
        );

        if (!misses.isEmpty()) return;

        const bg4 = self.color4(default_bg, 1.0);
        gl.glClearColor(bg4[0], bg4[1], bg4[2], bg4[3]);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        const mvp = snail.Mat4.ortho(0, self.viewport_w, self.viewport_h, 0, -1, 1);

        if (draw_rect_len > 0)
            self.rect_renderer.drawRects(self.draw_rects[0..draw_rect_len], mvp);

        self.snail_renderer.beginFrame();
        if (draw_text_len > 0)
            self.snail_renderer.drawText(self.draw_text[0..draw_text_len], mvp, self.viewport_w, self.viewport_h);

        gl.glFlush();
    }
};
