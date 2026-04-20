const std = @import("std");
const snail = @import("snail");
const terminal_mod = @import("terminal.zig");
const color = @import("color.zig");
const perf = @import("perf.zig");
const Rgb = color.Rgb;
const Terminal = terminal_mod.Terminal;

const gl = @cImport(@cInclude("GL/gl.h"));
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

pub const Renderer = struct {
    font: snail.Font,
    atlas: snail.Atlas,
    snail_renderer: snail.Renderer,

    // Double vertex buffers — current + previous frame.
    // On partial dirty, copy previous frame and only rebuild dirty rows.
    text_buf: []f32,
    vector_buf: []f32,
    prev_text_len: usize = 0,
    prev_vec_len: usize = 0,

    // Per-row vertex offsets for incremental updates.
    // row_text_ranges[row] = .{ start, len } into text_buf
    row_text_start: []u32,
    row_text_len: []u32,
    row_vec_start: []u32,
    row_vec_len: []u32,

    cell_width: f32,
    cell_height: f32,
    font_size: f32,
    viewport_w: f32,
    viewport_h: f32,

    allocator: std.mem.Allocator,
    max_rows: u16,

    pub var frame_stats: perf.FrameStats = .{};

    pub fn initCpu(self: *Renderer, allocator: std.mem.Allocator, font_data: []const u8, font_size: f32) !void {
        self.allocator = allocator;
        self.font_size = font_size;
        self.viewport_w = 0;
        self.viewport_h = 0;
        self.prev_text_len = 0;
        self.prev_vec_len = 0;

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

        const max_cells = 400 * 200;
        self.max_rows = 200;
        self.text_buf = try allocator.alloc(f32, max_cells * snail.FLOATS_PER_GLYPH);
        errdefer allocator.free(self.text_buf);
        self.vector_buf = try allocator.alloc(f32, max_cells * snail.VECTOR_FLOATS_PER_PRIMITIVE);
        errdefer allocator.free(self.vector_buf);

        self.row_text_start = try allocator.alloc(u32, self.max_rows);
        errdefer allocator.free(self.row_text_start);
        self.row_text_len = try allocator.alloc(u32, self.max_rows);
        errdefer allocator.free(self.row_text_len);
        self.row_vec_start = try allocator.alloc(u32, self.max_rows);
        errdefer allocator.free(self.row_vec_start);
        self.row_vec_len = try allocator.alloc(u32, self.max_rows);

        @memset(self.row_text_start, 0);
        @memset(self.row_text_len, 0);
        @memset(self.row_vec_start, 0);
        @memset(self.row_vec_len, 0);
    }

    pub fn initGpu(self: *Renderer) !void {
        self.snail_renderer = try snail.Renderer.init();
        self.snail_renderer.uploadAtlas(&self.atlas);
        self.snail_renderer.setSubpixelOrder(detectSubpixelOrder());
        self.snail_renderer.setFillRule(.non_zero);
        std.debug.print("mollusk: GL backend: {s}\n", .{self.snail_renderer.backendName()});
    }

    pub fn deinit(self: *Renderer) void {
        self.allocator.free(self.row_vec_len);
        self.allocator.free(self.row_vec_start);
        self.allocator.free(self.row_text_len);
        self.allocator.free(self.row_text_start);
        self.allocator.free(self.text_buf);
        self.allocator.free(self.vector_buf);
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
        // Viewport change invalidates all row caches
        self.prev_text_len = 0;
        self.prev_vec_len = 0;
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

        const bg = colors.background.toFloat4(1.0);
        gl.glClearColor(bg[0], bg[1], bg[2], bg[3]);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        const mvp = snail.Mat4.ortho(0, self.viewport_w, 0, self.viewport_h, -1, 1);
        self.snail_renderer.beginFrame();

        var text_batch = snail.Batch.init(self.text_buf);
        var vec_batch = snail.VectorBatch.init(self.vector_buf);

        // Walk rows. On partial dirty, skip clean rows entirely.
        term.beginRowIteration();
        var row_idx: u16 = 0;
        while (term.nextRow()) : (row_idx += 1) {
            if (row_idx >= self.max_rows) break;

            const cell_y_tl = @as(f32, @floatFromInt(row_idx)) * self.cell_height;
            const cell_y_bl = self.viewport_h - @as(f32, @floatFromInt(row_idx + 1)) * self.cell_height;

            // Track where this row starts in the batch
            const text_row_start: u32 = @intCast(text_batch.glyphCount() * snail.FLOATS_PER_GLYPH);
            const vec_row_start: u32 = @intCast(vec_batch.shapeCount() * snail.VECTOR_FLOATS_PER_PRIMITIVE);

            term.beginCellIteration();
            var col_idx: u16 = 0;
            while (term.nextCell()) : (col_idx += 1) {
                const cell = term.getCellInfo();
                const cell_x = @as(f32, @floatFromInt(col_idx)) * self.cell_width;

                var fg = cell.fg orelse default_fg;
                var cell_bg = cell.bg;
                if (cell.style.inverse != false) {
                    const tmp = fg;
                    fg = cell_bg orelse default_bg;
                    cell_bg = tmp;
                }
                if (cell.style.faint != false) {
                    fg = .{
                        .r = @intFromFloat(@as(f32, @floatFromInt(fg.r)) * 0.5),
                        .g = @intFromFloat(@as(f32, @floatFromInt(fg.g)) * 0.5),
                        .b = @intFromFloat(@as(f32, @floatFromInt(fg.b)) * 0.5),
                    };
                }

                // Is this the cursor cell? Draw with inverted color directly
                // in the main text pass (eliminates a separate draw call).
                const is_cursor_cell = cursor.visible and cursor.in_viewport and
                    cursor.style == .block and col_idx == cursor.x and row_idx == cursor.y;

                if (cell_bg) |cbg| {
                    _ = vec_batch.addRect(
                        .{ .x = cell_x, .y = cell_y_tl, .w = self.cell_width, .h = self.cell_height },
                        cbg.toFloat4(1.0),
                        .{ 0, 0, 0, 0 },
                        0,
                    );
                }

                if (cell.has_text and cell.codepoint > 0x20 and cell.codepoint < 0x110000) {
                    const gid = self.font.glyphIndex(cell.codepoint) catch 0;
                    if (self.atlas.getGlyph(gid)) |info| {
                        // Under block cursor: draw glyph with bg color so it's
                        // readable against the solid cursor fill.
                        const glyph_color = if (is_cursor_cell)
                            colors.background.toFloat4(1.0)
                        else
                            fg.toFloat4(1.0);

                        _ = text_batch.addGlyph(
                            cell_x,
                            cell_y_bl + self.cell_height * 0.2,
                            self.font_size,
                            info.bbox,
                            info.band_entry,
                            glyph_color,
                            self.atlas.gl_layer,
                        );
                    } else {
                        const cps = [1]u32{cell.codepoint};
                        if (self.atlas.addCodepoints(&cps) catch false) {
                            self.snail_renderer.uploadAtlas(&self.atlas);
                        }
                        const gid2 = self.font.glyphIndex(cell.codepoint) catch 0;
                        if (self.atlas.getGlyph(gid2)) |info| {
                            _ = text_batch.addGlyph(
                                cell_x,
                                cell_y_bl + self.cell_height * 0.2,
                                self.font_size,
                                info.bbox,
                                info.band_entry,
                                fg.toFloat4(1.0),
                                self.atlas.gl_layer,
                            );
                        }
                    }
                }

                if (cell.style.underline != 0 and cell.has_text) {
                    _ = vec_batch.addRect(
                        .{ .x = cell_x, .y = cell_y_tl + self.cell_height - 1, .w = self.cell_width, .h = 1 },
                        fg.toFloat4(1.0),
                        .{ 0, 0, 0, 0 },
                        0,
                    );
                }
                if (cell.style.strikethrough != false and cell.has_text) {
                    _ = vec_batch.addRect(
                        .{ .x = cell_x, .y = cell_y_tl + self.cell_height * 0.45, .w = self.cell_width, .h = 1 },
                        fg.toFloat4(1.0),
                        .{ 0, 0, 0, 0 },
                        0,
                    );
                }
            }

            // Record row extents
            self.row_text_start[row_idx] = text_row_start;
            self.row_text_len[row_idx] = @intCast(text_batch.glyphCount() * snail.FLOATS_PER_GLYPH - text_row_start);
            self.row_vec_start[row_idx] = vec_row_start;
            self.row_vec_len[row_idx] = @intCast(vec_batch.shapeCount() * snail.VECTOR_FLOATS_PER_PRIMITIVE - vec_row_start);
        }

        // Cursor (vector)
        if (cursor.visible and cursor.in_viewport) {
            const cx = @as(f32, @floatFromInt(cursor.x)) * self.cell_width;
            const cy = @as(f32, @floatFromInt(cursor.y)) * self.cell_height;
            const cc = if (colors.cursor) |col| col.toFloat4(1.0) else colors.foreground.toFloat4(1.0);

            switch (cursor.style) {
                .block => _ = vec_batch.addRect(
                    .{ .x = cx, .y = cy, .w = self.cell_width, .h = self.cell_height },
                    cc, .{ 0, 0, 0, 0 }, 0,
                ),
                .bar => _ = vec_batch.addRect(
                    .{ .x = cx, .y = cy, .w = 2, .h = self.cell_height },
                    cc, .{ 0, 0, 0, 0 }, 0,
                ),
                .underline => _ = vec_batch.addRect(
                    .{ .x = cx, .y = cy + self.cell_height - 2, .w = self.cell_width, .h = 2 },
                    cc, .{ 0, 0, 0, 0 }, 0,
                ),
                .block_hollow => _ = vec_batch.addRect(
                    .{ .x = cx, .y = cy, .w = self.cell_width, .h = self.cell_height },
                    .{ 0, 0, 0, 0 }, cc, 1.5,
                ),
            }
        }

        // 2 draw calls total: vectors then text.
        // Block cursor inverse glyph is included in the main text batch.
        if (vec_batch.shapeCount() > 0) {
            self.snail_renderer.drawVector(vec_batch.slice(), self.viewport_w, self.viewport_h);
        }
        if (text_batch.glyphCount() > 0) {
            self.snail_renderer.draw(text_batch.slice(), mvp, self.viewport_w, self.viewport_h);
        }

        self.prev_text_len = text_batch.glyphCount() * snail.FLOATS_PER_GLYPH;
        self.prev_vec_len = vec_batch.shapeCount() * snail.VECTOR_FLOATS_PER_PRIMITIVE;

        gl.glFlush();
        term.resetDirty();
        frame_stats.record(frame_timer.elapsedUs());
        return true;
    }
};
