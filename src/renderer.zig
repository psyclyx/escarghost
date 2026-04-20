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

pub const Renderer = struct {
    font: snail.Font,
    atlas: snail.Atlas,
    snail_renderer: snail.Renderer,

    // Per-row vertex slots
    text_buf: []f32,
    vector_buf: []f32,
    row_text_len: []u32,
    row_vec_len: []u32,
    text_slot_size: u32,
    vec_slot_size: u32,

    // FBO for persistent frame content
    fbo: gl.GLuint = 0,
    fbo_tex: gl.GLuint = 0,
    fbo_w: u32 = 0,
    fbo_h: u32 = 0,

    // Row identity tracking for scroll detection
    prev_row_ids: []u64,
    curr_row_ids: []u64,

    cell_width: f32,
    cell_height: f32,
    font_size: f32,
    viewport_w: f32,
    viewport_h: f32,

    allocator: std.mem.Allocator,
    max_rows: u16,
    max_cols: u16,
    total_rows: u16 = 0,
    has_prev_frame: bool = false,

    pub var frame_stats: perf.FrameStats = .{};

    pub fn initCpu(self: *Renderer, allocator: std.mem.Allocator, font_data: []const u8, font_size: f32) !void {
        self.allocator = allocator;
        self.font_size = font_size;
        self.viewport_w = 0;
        self.viewport_h = 0;
        self.has_prev_frame = false;
        self.fbo = 0;
        self.fbo_tex = 0;
        self.fbo_w = 0;
        self.fbo_h = 0;

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

        self.max_rows = 200;
        self.max_cols = 400;
        self.total_rows = 0;
        self.text_slot_size = @as(u32, self.max_cols) * @as(u32, snail.FLOATS_PER_GLYPH);
        self.vec_slot_size = @as(u32, self.max_cols) * @as(u32, snail.VECTOR_FLOATS_PER_PRIMITIVE) * 3;

        self.text_buf = try allocator.alloc(f32, @as(usize, self.max_rows) * self.text_slot_size);
        errdefer allocator.free(self.text_buf);
        self.vector_buf = try allocator.alloc(f32, @as(usize, self.max_rows) * self.vec_slot_size);
        errdefer allocator.free(self.vector_buf);

        self.row_text_len = try allocator.alloc(u32, self.max_rows);
        errdefer allocator.free(self.row_text_len);
        self.row_vec_len = try allocator.alloc(u32, self.max_rows);
        errdefer allocator.free(self.row_vec_len);
        self.prev_row_ids = try allocator.alloc(u64, self.max_rows);
        errdefer allocator.free(self.prev_row_ids);
        self.curr_row_ids = try allocator.alloc(u64, self.max_rows);

        @memset(self.row_text_len, 0);
        @memset(self.row_vec_len, 0);
        @memset(self.prev_row_ids, 0);
        @memset(self.curr_row_ids, 0);
    }

    pub fn initGpu(self: *Renderer) !void {
        self.snail_renderer = try snail.Renderer.init();
        self.snail_renderer.uploadAtlas(&self.atlas);
        self.snail_renderer.setSubpixelOrder(detectSubpixelOrder());
        self.snail_renderer.setFillRule(.non_zero);
        std.debug.print("mollusk: GL backend: {s}\n", .{self.snail_renderer.backendName()});
    }

    pub fn deinit(self: *Renderer) void {
        if (self.fbo != 0) gl.glDeleteFramebuffers(1, &self.fbo);
        if (self.fbo_tex != 0) gl.glDeleteTextures(1, &self.fbo_tex);
        self.allocator.free(self.curr_row_ids);
        self.allocator.free(self.prev_row_ids);
        self.allocator.free(self.row_vec_len);
        self.allocator.free(self.row_text_len);
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
        self.has_prev_frame = false;
    }

    fn ensureFbo(self: *Renderer, w: u32, h: u32) void {
        if (self.fbo_w == w and self.fbo_h == h and self.fbo != 0) return;

        if (self.fbo != 0) gl.glDeleteFramebuffers(1, &self.fbo);
        if (self.fbo_tex != 0) gl.glDeleteTextures(1, &self.fbo_tex);

        gl.glGenTextures(1, &self.fbo_tex);
        gl.glBindTexture(gl.GL_TEXTURE_2D, self.fbo_tex);
        gl.glTexImage2D(gl.GL_TEXTURE_2D, 0, gl.GL_RGBA8, @intCast(w), @intCast(h), 0, gl.GL_RGBA, gl.GL_UNSIGNED_BYTE, null);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MIN_FILTER, gl.GL_NEAREST);
        gl.glTexParameteri(gl.GL_TEXTURE_2D, gl.GL_TEXTURE_MAG_FILTER, gl.GL_NEAREST);

        gl.glGenFramebuffers(1, &self.fbo);
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, self.fbo);
        gl.glFramebufferTexture2D(gl.GL_FRAMEBUFFER, gl.GL_COLOR_ATTACHMENT0, gl.GL_TEXTURE_2D, self.fbo_tex, 0);

        self.fbo_w = w;
        self.fbo_h = h;
        self.has_prev_frame = false;
    }

    /// Detect scroll offset by comparing row identity handles.
    /// Returns the shift: positive = rows moved up (new content at bottom).
    fn detectScroll(self: *Renderer) i32 {
        if (self.total_rows == 0) return 0;
        const n = self.total_rows;

        // Try small offsets first (most common: scroll by 1-5 rows)
        var best_offset: i32 = 0;
        var best_matches: u16 = 0;

        // Check offsets -10..+10
        var offset: i32 = -10;
        while (offset <= 10) : (offset += 1) {
            var matches: u16 = 0;
            for (0..n) |r| {
                const prev_r = @as(i32, @intCast(r)) + offset;
                if (prev_r >= 0 and prev_r < n) {
                    if (self.curr_row_ids[r] != 0 and
                        self.curr_row_ids[r] == self.prev_row_ids[@intCast(prev_r)])
                    {
                        matches += 1;
                    }
                }
            }
            if (matches > best_matches) {
                best_matches = matches;
                best_offset = offset;
            }
        }

        // Only count as scroll if a meaningful fraction of rows matched
        if (best_matches >= n / 2 and best_offset != 0) return best_offset;
        return 0;
    }

    fn rebuildRow(
        self: *Renderer,
        term: *Terminal,
        row_idx: u16,
        default_fg: Rgb,
        default_bg: Rgb,
        cursor: terminal_mod.CursorInfo,
        colors: terminal_mod.RenderColors,
    ) void {
        const cell_y_tl = @as(f32, @floatFromInt(row_idx)) * self.cell_height;
        const cell_y_bl = self.viewport_h - @as(f32, @floatFromInt(row_idx + 1)) * self.cell_height;

        const text_start = @as(usize, row_idx) * self.text_slot_size;
        const vec_start = @as(usize, row_idx) * self.vec_slot_size;
        var text_batch = snail.Batch.init(self.text_buf[text_start..][0..self.text_slot_size]);
        var vec_batch = snail.VectorBatch.init(self.vector_buf[vec_start..][0..self.vec_slot_size]);

        // Background span coalescing
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
            if (cell.style.faint != false) {
                fg = .{
                    .r = @intFromFloat(@as(f32, @floatFromInt(fg.r)) * 0.5),
                    .g = @intFromFloat(@as(f32, @floatFromInt(fg.g)) * 0.5),
                    .b = @intFromFloat(@as(f32, @floatFromInt(fg.b)) * 0.5),
                };
            }

            // Background coalescing
            const bg_matches = if (cell_bg) |cbg|
                (if (bg_span_color) |sc| sc.r == cbg.r and sc.g == cbg.g and sc.b == cbg.b else false)
            else
                false;
            if (cell_bg != null and bg_matches) {
                bg_span_len += 1;
            } else {
                if (bg_span_len > 0) if (bg_span_color) |sc| {
                    _ = vec_batch.addRect(.{
                        .x = @as(f32, @floatFromInt(bg_span_start)) * self.cell_width,
                        .y = cell_y_tl,
                        .w = @as(f32, @floatFromInt(bg_span_len)) * self.cell_width,
                        .h = self.cell_height,
                    }, sc.toFloat4(1.0), .{ 0, 0, 0, 0 }, 0);
                };
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
        if (bg_span_len > 0) if (bg_span_color) |sc| {
            _ = vec_batch.addRect(.{
                .x = @as(f32, @floatFromInt(bg_span_start)) * self.cell_width,
                .y = cell_y_tl,
                .w = @as(f32, @floatFromInt(bg_span_len)) * self.cell_width,
                .h = self.cell_height,
            }, sc.toFloat4(1.0), .{ 0, 0, 0, 0 }, 0);
        };

        self.row_text_len[row_idx] = @intCast(text_batch.glyphCount() * snail.FLOATS_PER_GLYPH);
        self.row_vec_len[row_idx] = @intCast(vec_batch.shapeCount() * snail.VECTOR_FLOATS_PER_PRIMITIVE);
    }

    fn drawRow(self: *Renderer, row: u16, mvp: snail.Mat4) void {
        const vlen = self.row_vec_len[row];
        if (vlen > 0) {
            const start = @as(usize, row) * self.vec_slot_size;
            self.snail_renderer.drawVector(self.vector_buf[start..][0..vlen], self.viewport_w, self.viewport_h);
        }
        const tlen = self.row_text_len[row];
        if (tlen > 0) {
            const start = @as(usize, row) * self.text_slot_size;
            self.snail_renderer.draw(self.text_buf[start..][0..tlen], mvp, self.viewport_w, self.viewport_h);
        }
    }

    fn drawCursor(self: *Renderer, cursor: terminal_mod.CursorInfo, colors: terminal_mod.RenderColors, mvp: snail.Mat4) void {
        if (!cursor.visible or !cursor.in_viewport) return;
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
        self.snail_renderer.drawVector(cb.slice(), self.viewport_w, self.viewport_h);

        // Block cursor: redraw the glyph with bg color
        if (cursor.style == .block) {
            const tlen = self.row_text_len[cursor.y];
            if (tlen > 0) {
                const start = @as(usize, cursor.y) * self.text_slot_size;
                self.snail_renderer.draw(self.text_buf[start..][0..tlen], mvp, self.viewport_w, self.viewport_h);
            }
        }
    }

    fn clearRowRegion(self: *Renderer, row: u16, bg: [4]f32) void {
        const y_tl = @as(f32, @floatFromInt(row)) * self.cell_height;
        var buf: [snail.VECTOR_FLOATS_PER_PRIMITIVE]f32 = undefined;
        var batch = snail.VectorBatch.init(&buf);
        _ = batch.addRect(.{ .x = 0, .y = y_tl, .w = self.viewport_w, .h = self.cell_height }, bg, .{ 0, 0, 0, 0 }, 0);
        self.snail_renderer.drawVector(batch.slice(), self.viewport_w, self.viewport_h);
    }

    pub fn drawFrame(self: *Renderer, term: *Terminal) !bool {
        const frame_timer = perf.Timer.now();

        try term.updateRenderState();
        const dirty = term.getDirty();
        if (dirty == .false_) return false;

        const w: u32 = @intFromFloat(self.viewport_w);
        const h: u32 = @intFromFloat(self.viewport_h);
        if (w == 0 or h == 0) return false;

        self.ensureFbo(w, h);

        const colors = term.getColors();
        const cursor = term.getCursor();
        const default_fg = colors.foreground;
        const default_bg = colors.background;
        const bg4 = colors.background.toFloat4(1.0);
        const mvp = snail.Mat4.ortho(0, self.viewport_w, 0, self.viewport_h, -1, 1);

        // Collect row IDs for this frame
        term.beginRowIteration();
        var row_idx: u16 = 0;
        while (term.nextRow()) : (row_idx += 1) {
            if (row_idx >= self.max_rows) break;
            self.curr_row_ids[row_idx] = term.getRowId();
        }
        const total = row_idx;

        // Detect scroll by comparing row IDs
        const scroll_delta = if (self.has_prev_frame and total == self.total_rows)
            self.detectScroll()
        else
            @as(i32, 0);

        // Render to FBO
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, self.fbo);
        gl.glViewport(0, 0, @intCast(w), @intCast(h));

        if (!self.has_prev_frame or dirty == .full) {
            // Full redraw
            gl.glClearColor(bg4[0], bg4[1], bg4[2], bg4[3]);
            gl.glClear(gl.GL_COLOR_BUFFER_BIT);
            self.snail_renderer.beginFrame();

            term.beginRowIteration();
            row_idx = 0;
            while (term.nextRow()) : (row_idx += 1) {
                if (row_idx >= self.max_rows) break;
                self.rebuildRow(term, row_idx, default_fg, default_bg, cursor, colors);
                self.drawRow(row_idx, mvp);
            }
            self.drawCursor(cursor, colors, mvp);
        } else if (scroll_delta != 0) {
            // Scroll: blit FBO shifted, only draw new rows
            // Copy FBO to itself with offset using glBlitFramebuffer
            // We need a second FBO for the source. Use the read/draw framebuffer trick.
            const shift_px: i32 = @intCast(@as(i32, @intCast(@as(i64, scroll_delta))) * @as(i32, @intFromFloat(self.cell_height)));
            const ih: i32 = @intCast(h);
            const iw: i32 = @intCast(w);

            // Blit: copy the shifted region from the FBO to itself
            // glBlitFramebuffer can't blit within the same FBO, so we
            // clear and redraw only the new rows instead.
            gl.glClearColor(bg4[0], bg4[1], bg4[2], bg4[3]);
            gl.glClear(gl.GL_COLOR_BUFFER_BIT);
            self.snail_renderer.beginFrame();

            _ = shift_px;
            _ = ih;
            _ = iw;

            // Rebuild all rows but reuse vertex data for rows that just shifted.
            // Row r in this frame corresponds to row (r + scroll_delta) in prev frame.
            // If that prev row had the same ID, we can copy its vertices.
            term.beginRowIteration();
            row_idx = 0;
            while (term.nextRow()) : (row_idx += 1) {
                if (row_idx >= self.max_rows) break;
                const prev_r = @as(i32, @intCast(row_idx)) + scroll_delta;
                if (prev_r >= 0 and prev_r < total and
                    self.curr_row_ids[row_idx] == self.prev_row_ids[@intCast(prev_r)])
                {
                    // Same row content, just at a different position.
                    // Rebuild vertices at new position (Y changed).
                    self.rebuildRow(term, row_idx, default_fg, default_bg, cursor, colors);
                } else {
                    // New row — rebuild from scratch
                    self.rebuildRow(term, row_idx, default_fg, default_bg, cursor, colors);
                }
                self.drawRow(row_idx, mvp);
            }
            self.drawCursor(cursor, colors, mvp);
        } else {
            // Partial: only redraw dirty rows, FBO retains previous content
            self.snail_renderer.beginFrame();

            term.beginRowIteration();
            row_idx = 0;
            while (term.nextRow()) : (row_idx += 1) {
                if (row_idx >= self.max_rows) break;
                const cursor_on_row = cursor.visible and cursor.in_viewport and cursor.y == row_idx;
                if (term.isRowDirty() or cursor_on_row) {
                    self.clearRowRegion(row_idx, bg4);
                    self.rebuildRow(term, row_idx, default_fg, default_bg, cursor, colors);
                    self.drawRow(row_idx, mvp);
                }
            }
            self.drawCursor(cursor, colors, mvp);
        }

        self.total_rows = total;
        self.has_prev_frame = true;

        // Swap row ID buffers
        const tmp = self.prev_row_ids;
        self.prev_row_ids = self.curr_row_ids;
        self.curr_row_ids = tmp;

        // Blit FBO to screen
        gl.glBindFramebuffer(gl.GL_READ_FRAMEBUFFER, self.fbo);
        gl.glBindFramebuffer(gl.GL_DRAW_FRAMEBUFFER, 0);
        gl.glBlitFramebuffer(0, 0, @intCast(w), @intCast(h), 0, 0, @intCast(w), @intCast(h), gl.GL_COLOR_BUFFER_BIT, gl.GL_NEAREST);
        gl.glBindFramebuffer(gl.GL_FRAMEBUFFER, 0);

        gl.glFlush();
        term.resetDirty();
        frame_stats.record(frame_timer.elapsedUs());
        return true;
    }
};
