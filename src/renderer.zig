const std = @import("std");
const snail = @import("snail");
const terminal_mod = @import("terminal.zig");
const color = @import("color.zig");
const perf = @import("perf.zig");
const Rgb = color.Rgb;
const Terminal = terminal_mod.Terminal;

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
        fc.FC_RGBA_RGB => .rgb, fc.FC_RGBA_BGR => .bgr,
        fc.FC_RGBA_VRGB => .vrgb, fc.FC_RGBA_VBGR => .vbgr,
        fc.FC_RGBA_NONE => .none, else => .rgb,
    };
}

/// Pre-built vertex data for a single row. Stored in the scrollback ring.
/// No GL dependency — pure CPU data that can be replayed instantly.
const RowCache = struct {
    text: []f32, // glyph vertices (owned slice within arena)
    vec: []f32, // vector vertices (bg spans + decorations)
    row_id: u64, // ghostty row identity handle
};

pub const Renderer = struct {
    font: snail.Font,
    atlas: snail.Atlas,
    snail_renderer: snail.Renderer,

    // Scrollback ring of cached row vertex data.
    // Indexed by ghostty row ID for O(1) lookup.
    row_cache: std.AutoHashMap(u64, RowCache),

    // Frame draw buffers — contiguous, rebuilt each frame from cache.
    // Only 2 draw calls: all vectors, then all text.
    draw_text: []f32,
    draw_vec: []f32,

    // Per-row build scratch space (reused each rebuild)
    scratch_text: []f32,
    scratch_vec: []f32,

    cell_width: f32,
    cell_height: f32,
    font_size: f32,
    viewport_w: f32,
    viewport_h: f32,

    allocator: std.mem.Allocator,
    max_cols: u16,
    has_prev_frame: bool = false,

    // Previous frame's row IDs for dirty detection
    prev_row_ids: [200]u64 = [_]u64{0} ** 200,
    prev_cursor_x: u16 = 0,
    prev_cursor_y: u16 = 0,

    pub var frame_stats: perf.FrameStats = .{};

    pub fn initCpu(self: *Renderer, allocator: std.mem.Allocator, font_data: []const u8, font_size: f32) !void {
        self.allocator = allocator;
        self.font_size = font_size;
        self.viewport_w = 0;
        self.viewport_h = 0;
        self.has_prev_frame = false;
        self.prev_cursor_x = 0;
        self.prev_cursor_y = 0;
        self.prev_row_ids = [_]u64{0} ** 200;

        self.font = try snail.Font.init(font_data);
        errdefer self.font.deinit();

        self.atlas = try snail.Atlas.initAscii(allocator, &self.font, &snail.ASCII_PRINTABLE);
        errdefer self.atlas.deinit();

        const units_per_em: f32 = @floatFromInt(self.font.unitsPerEm());
        const scale = font_size / units_per_em;
        const m_gid = self.font.glyphIndex('M') catch 0;
        const m_info = self.atlas.getGlyph(m_gid);
        self.cell_width = if (m_info) |g| @ceil(@as(f32, @floatFromInt(g.advance_width)) * scale) else @ceil(font_size * 0.6);
        self.cell_height = @ceil(font_size * 1.2);

        self.max_cols = 400;
        self.row_cache = std.AutoHashMap(u64, RowCache).init(allocator);

        const max_cells: usize = 400 * 200;
        self.draw_text = try allocator.alloc(f32, max_cells * snail.FLOATS_PER_GLYPH);
        errdefer allocator.free(self.draw_text);
        self.draw_vec = try allocator.alloc(f32, max_cells * @as(usize, snail.VECTOR_FLOATS_PER_PRIMITIVE) * 3);
        errdefer allocator.free(self.draw_vec);

        // Scratch for building one row
        self.scratch_text = try allocator.alloc(f32, @as(usize, self.max_cols) * snail.FLOATS_PER_GLYPH);
        errdefer allocator.free(self.scratch_text);
        self.scratch_vec = try allocator.alloc(f32, @as(usize, self.max_cols) * @as(usize, snail.VECTOR_FLOATS_PER_PRIMITIVE) * 3);
    }

    pub fn initGpu(self: *Renderer) !void {
        self.snail_renderer = try snail.Renderer.init();
        self.snail_renderer.uploadAtlas(&self.atlas);
        self.snail_renderer.setSubpixelOrder(detectSubpixelOrder());
        self.snail_renderer.setFillRule(.non_zero);
        std.debug.print("mollusk: GL backend: {s}\n", .{self.snail_renderer.backendName()});
    }

    pub fn deinit(self: *Renderer) void {
        // Free all cached row vertex data
        var it = self.row_cache.valueIterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.text);
            self.allocator.free(entry.vec);
        }
        self.row_cache.deinit();
        self.allocator.free(self.scratch_vec);
        self.allocator.free(self.scratch_text);
        self.allocator.free(self.draw_vec);
        self.allocator.free(self.draw_text);
        self.snail_renderer.deinit();
        self.atlas.deinit();
        self.font.deinit();
    }

    pub fn computeGridSize(self: *const Renderer, pixel_w: u32, pixel_h: u32) struct { cols: u16, rows: u16 } {
        return .{
            .cols = @intFromFloat(@max(1.0, @floor(@as(f32, @floatFromInt(pixel_w)) / self.cell_width))),
            .rows = @intFromFloat(@max(1.0, @floor(@as(f32, @floatFromInt(pixel_h)) / self.cell_height))),
        };
    }

    pub fn setViewport(self: *Renderer, w: u32, h: u32) void {
        self.viewport_w = @floatFromInt(w);
        self.viewport_h = @floatFromInt(h);
        self.has_prev_frame = false;
        // Viewport change invalidates all cached rows (Y positions change)
        var cache_it = self.row_cache.valueIterator();
        while (cache_it.next()) |entry| {
            self.allocator.free(entry.text);
            self.allocator.free(entry.vec);
        }
        self.row_cache.clearRetainingCapacity();
    }

    /// Build vertex data for a row into scratch buffers.
    fn buildRow(
        self: *Renderer,
        term: *Terminal,
        row_idx: u16,
        default_fg: Rgb,
        default_bg: Rgb,
        cursor: terminal_mod.CursorInfo,
        colors: terminal_mod.RenderColors,
    ) struct { text_len: usize, vec_len: usize } {
        const cell_y_tl = @as(f32, @floatFromInt(row_idx)) * self.cell_height;
        const cell_y_bl = self.viewport_h - @as(f32, @floatFromInt(row_idx + 1)) * self.cell_height;

        var text_batch = snail.Batch.init(self.scratch_text);
        var vec_batch = snail.VectorBatch.init(self.scratch_vec);

        var bg_span_start: u16 = 0;
        var bg_span_color: ?Rgb = null;
        var bg_span_len: u16 = 0;

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

            // BG span coalescing
            const bg_matches = if (cell_bg) |cbg|
                (if (bg_span_color) |sc| sc.r == cbg.r and sc.g == cbg.g and sc.b == cbg.b else false)
            else
                false;
            if (cell_bg != null and bg_matches) {
                bg_span_len += 1;
            } else {
                if (bg_span_len > 0) {
                    if (bg_span_color) |sc| {
                        _ = vec_batch.addRect(.{
                            .x = @as(f32, @floatFromInt(bg_span_start)) * self.cell_width,
                            .y = cell_y_tl,
                            .w = @as(f32, @floatFromInt(bg_span_len)) * self.cell_width,
                            .h = self.cell_height,
                        }, sc.toFloat4(1.0), .{ 0, 0, 0, 0 }, 0);
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

            const is_cursor_cell = cursor.visible and cursor.in_viewport and
                cursor.style == .block and col_idx == cursor.x and row_idx == cursor.y;

            if (cell.has_text and cell.codepoint > 0x20 and cell.codepoint < 0x110000) {
                const gid = self.font.glyphIndex(cell.codepoint) catch 0;
                if (self.atlas.getGlyph(gid)) |info| {
                    _ = text_batch.addGlyph(
                        @as(f32, @floatFromInt(col_idx)) * self.cell_width,
                        cell_y_bl + self.cell_height * 0.2,
                        self.font_size, info.bbox, info.band_entry,
                        if (is_cursor_cell) colors.background.toFloat4(1.0) else fg.toFloat4(1.0),
                        self.atlas.gl_layer,
                    );
                } else {
                    const cps = [1]u32{cell.codepoint};
                    if (self.atlas.addCodepoints(&cps) catch false)
                        self.snail_renderer.uploadAtlas(&self.atlas);
                    const gid2 = self.font.glyphIndex(cell.codepoint) catch 0;
                    if (self.atlas.getGlyph(gid2)) |info|
                        _ = text_batch.addGlyph(
                            @as(f32, @floatFromInt(col_idx)) * self.cell_width,
                            cell_y_bl + self.cell_height * 0.2,
                            self.font_size, info.bbox, info.band_entry,
                            fg.toFloat4(1.0), self.atlas.gl_layer,
                        );
                }
                if (cell.style.underline != 0)
                    _ = vec_batch.addRect(.{
                        .x = @as(f32, @floatFromInt(col_idx)) * self.cell_width,
                        .y = cell_y_tl + self.cell_height - 1, .w = self.cell_width, .h = 1,
                    }, fg.toFloat4(1.0), .{ 0, 0, 0, 0 }, 0);
                if (cell.style.strikethrough != false)
                    _ = vec_batch.addRect(.{
                        .x = @as(f32, @floatFromInt(col_idx)) * self.cell_width,
                        .y = cell_y_tl + self.cell_height * 0.45, .w = self.cell_width, .h = 1,
                    }, fg.toFloat4(1.0), .{ 0, 0, 0, 0 }, 0);
            }
        }
        // Flush final bg span
        if (bg_span_len > 0) {
            if (bg_span_color) |sc| {
                _ = vec_batch.addRect(.{
                    .x = @as(f32, @floatFromInt(bg_span_start)) * self.cell_width,
                    .y = cell_y_tl,
                    .w = @as(f32, @floatFromInt(bg_span_len)) * self.cell_width,
                    .h = self.cell_height,
                }, sc.toFloat4(1.0), .{ 0, 0, 0, 0 }, 0);
            }
        }

        return .{
            .text_len = text_batch.glyphCount() * snail.FLOATS_PER_GLYPH,
            .vec_len = vec_batch.shapeCount() * snail.VECTOR_FLOATS_PER_PRIMITIVE,
        };
    }

    /// Cache the scratch buffer contents for a row ID.
    fn cacheRow(self: *Renderer, row_id: u64, text_len: usize, vec_len: usize) void {
        // Evict old entry if present
        if (self.row_cache.fetchRemove(row_id)) |kv| {
            self.allocator.free(kv.value.text);
            self.allocator.free(kv.value.vec);
        }

        const text = self.allocator.dupe(f32, self.scratch_text[0..text_len]) catch return;
        const vec = self.allocator.dupe(f32, self.scratch_vec[0..vec_len]) catch {
            self.allocator.free(text);
            return;
        };

        self.row_cache.put(row_id, .{ .text = text, .vec = vec, .row_id = row_id }) catch {
            self.allocator.free(text);
            self.allocator.free(vec);
        };
    }

    pub fn drawFrame(self: *Renderer, term: *Terminal) !bool {
        const frame_timer = perf.Timer.now();

        try term.updateRenderState();
        const dirty = term.getDirty();
        if (dirty == .false_) return false;

        const colors = term.getColors();
        const cursor = term.getCursor();
        const default_fg = colors.foreground;
        const default_bg = colors.background;

        // Gather visible rows' vertices into contiguous draw buffers.
        var draw_text_len: usize = 0;
        var draw_vec_len: usize = 0;

        term.beginRowIteration();
        var row_idx: u16 = 0;
        while (term.nextRow()) : (row_idx += 1) {
            if (row_idx >= 200) break;

            // Determine if this row needs rebuilding
            const needs_rebuild = dirty == .full or !self.has_prev_frame or
                term.isRowDirty() or
                (cursor.visible and cursor.in_viewport and cursor.y == row_idx) or
                (self.prev_cursor_y == row_idx);

            // Always rebuild — glClear requires all rows in draw buffer.
            // Cache is not used yet (needs position-independent vertices).
            _ = needs_rebuild;
            const lens = self.buildRow(term, row_idx, default_fg, default_bg, cursor, colors);
            if (lens.vec_len > 0) {
                @memcpy(self.draw_vec[draw_vec_len..][0..lens.vec_len], self.scratch_vec[0..lens.vec_len]);
                draw_vec_len += lens.vec_len;
            }
            if (lens.text_len > 0) {
                @memcpy(self.draw_text[draw_text_len..][0..lens.text_len], self.scratch_text[0..lens.text_len]);
                draw_text_len += lens.text_len;
            }

            self.prev_row_ids[row_idx] = term.getRowId();
        }

        self.has_prev_frame = true;
        self.prev_cursor_x = cursor.x;
        self.prev_cursor_y = cursor.y;

        // Append cursor to vec buffer
        if (cursor.visible and cursor.in_viewport) {
            const cx = @as(f32, @floatFromInt(cursor.x)) * self.cell_width;
            const cy = @as(f32, @floatFromInt(cursor.y)) * self.cell_height;
            const cc = if (colors.cursor) |col| col.toFloat4(1.0) else colors.foreground.toFloat4(1.0);

            var cbuf: [snail.VECTOR_FLOATS_PER_PRIMITIVE]f32 = undefined;
            var cb = snail.VectorBatch.init(&cbuf);
            switch (cursor.style) {
                .block => _ = cb.addRect(.{ .x = cx, .y = cy, .w = self.cell_width, .h = self.cell_height }, cc, .{ 0, 0, 0, 0 }, 0),
                .bar => _ = cb.addRect(.{ .x = cx, .y = cy, .w = 2, .h = self.cell_height }, cc, .{ 0, 0, 0, 0 }, 0),
                .underline => _ = cb.addRect(.{ .x = cx, .y = cy + self.cell_height - 2, .w = self.cell_width, .h = 2 }, cc, .{ 0, 0, 0, 0 }, 0),
                .block_hollow => _ = cb.addRect(.{ .x = cx, .y = cy, .w = self.cell_width, .h = self.cell_height }, .{ 0, 0, 0, 0 }, cc, 1.5),
            }
            const clen = cb.shapeCount() * snail.VECTOR_FLOATS_PER_PRIMITIVE;
            @memcpy(self.draw_vec[draw_vec_len..][0..clen], cb.slice());
            draw_vec_len += clen;
        }

        // Draw: clear + 2 draw calls
        const bg4 = colors.background.toFloat4(1.0);
        gl.glClearColor(bg4[0], bg4[1], bg4[2], bg4[3]);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        const mvp = snail.Mat4.ortho(0, self.viewport_w, 0, self.viewport_h, -1, 1);
        self.snail_renderer.beginFrame();

        if (draw_vec_len > 0)
            self.snail_renderer.drawVector(self.draw_vec[0..draw_vec_len], self.viewport_w, self.viewport_h);
        if (draw_text_len > 0)
            self.snail_renderer.draw(self.draw_text[0..draw_text_len], mvp, self.viewport_w, self.viewport_h);

        gl.glFlush();
        term.resetDirty();
        frame_stats.record(frame_timer.elapsedUs());
        return true;
    }
};
