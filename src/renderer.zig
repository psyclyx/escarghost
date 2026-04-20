const std = @import("std");
const snail = @import("snail");
const terminal_mod = @import("terminal.zig");
const color = @import("color.zig");
const Rgb = color.Rgb;
const Terminal = terminal_mod.Terminal;

const gl = @cImport(@cInclude("GL/gl.h"));

pub const Renderer = struct {
    font: snail.Font,
    atlas: snail.Atlas,
    snail_renderer: snail.Renderer,

    text_buf: []f32,
    vector_buf: []f32,

    cell_width: f32,
    cell_height: f32,
    font_size: f32,

    viewport_w: f32,
    viewport_h: f32,

    allocator: std.mem.Allocator,

    pub fn init(self: *Renderer, allocator: std.mem.Allocator, font_data: []const u8, font_size: f32) !void {
        self.allocator = allocator;
        self.font_size = font_size;
        self.viewport_w = 0;
        self.viewport_h = 0;

        self.font = try snail.Font.init(font_data);
        errdefer self.font.deinit();

        // Atlas takes &self.font — pointer is stable since self is caller-owned
        self.atlas = try snail.Atlas.initAscii(allocator, &self.font, &snail.ASCII_PRINTABLE);
        errdefer self.atlas.deinit();

        self.snail_renderer = try snail.Renderer.init();
        errdefer self.snail_renderer.deinit();

        self.snail_renderer.uploadAtlas(&self.atlas);

        // Compute cell metrics from font
        const units_per_em: f32 = @floatFromInt(self.font.unitsPerEm());
        const scale = font_size / units_per_em;

        const m_gid = self.font.glyphIndex('M') catch 0;
        const m_info = self.atlas.getGlyph(m_gid);
        self.cell_width = if (m_info) |g| @ceil(@as(f32, @floatFromInt(g.advance_width)) * scale) else @ceil(font_size * 0.6);
        self.cell_height = @ceil(font_size * 1.2);

        const max_glyphs = 400 * 120;
        self.text_buf = try allocator.alloc(f32, max_glyphs * snail.FLOATS_PER_GLYPH);
        errdefer allocator.free(self.text_buf);

        self.vector_buf = try allocator.alloc(f32, max_glyphs * snail.VECTOR_FLOATS_PER_PRIMITIVE);
    }

    pub fn deinit(self: *Renderer) void {
        self.allocator.free(self.text_buf);
        self.allocator.free(self.vector_buf);
        self.snail_renderer.deinit();
        self.atlas.deinit();
        self.font.deinit();
    }

    pub fn computeGridSize(self: *const Renderer, pixel_w: u32, pixel_h: u32) struct { cols: u16, rows: u16 } {
        const c: u16 = @intFromFloat(@max(1.0, @floor(@as(f32, @floatFromInt(pixel_w)) / self.cell_width)));
        const r: u16 = @intFromFloat(@max(1.0, @floor(@as(f32, @floatFromInt(pixel_h)) / self.cell_height)));
        return .{ .cols = c, .rows = r };
    }

    pub fn setViewport(self: *Renderer, w: u32, h: u32) void {
        self.viewport_w = @floatFromInt(w);
        self.viewport_h = @floatFromInt(h);
    }

    pub fn drawFrame(self: *Renderer, term: *Terminal) !void {
        try term.updateRenderState();

        const colors = term.getColors();
        const cursor = term.getCursor();

        // Clear with background color
        const bg = colors.background.toFloat4(1.0);
        gl.glClearColor(bg[0], bg[1], bg[2], bg[3]);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        // Orthographic projection: pixel coords, bottom-left origin (for text pipeline)
        const mvp = snail.Mat4.ortho(0, self.viewport_w, 0, self.viewport_h, -1, 1);

        self.snail_renderer.beginFrame();

        var text_batch = snail.Batch.init(self.text_buf);
        var vec_batch = snail.VectorBatch.init(self.vector_buf);

        const default_fg = colors.foreground;
        const default_bg = colors.background;

        // First pass: collect any missing codepoints for the atlas
        var needs_atlas_update = false;
        term.beginRowIteration();
        while (term.nextRow()) {
            term.beginCellIteration();
            while (term.nextCell()) {
                const cell = term.getCellInfo();
                if (cell.has_text and cell.codepoint > 0x20 and cell.codepoint < 0x110000) {
                    const cps = [1]u32{cell.codepoint};
                    if (self.atlas.addCodepoints(&cps) catch false) {
                        needs_atlas_update = true;
                    }
                }
            }
        }
        if (needs_atlas_update) {
            self.snail_renderer.uploadAtlas(&self.atlas);
        }

        // Second pass: build vertex batches
        term.beginRowIteration();
        var row_idx: u16 = 0;
        while (term.nextRow()) : (row_idx += 1) {
            term.beginCellIteration();
            var col_idx: u16 = 0;
            while (term.nextCell()) : (col_idx += 1) {
                const cell = term.getCellInfo();

                const cell_x = @as(f32, @floatFromInt(col_idx)) * self.cell_width;
                // Vector pipeline: top-left origin (shader flips y)
                const cell_y_tl = @as(f32, @floatFromInt(row_idx)) * self.cell_height;
                // Text pipeline: bottom-left origin (standard GL via MVP)
                const cell_y_bl = self.viewport_h - @as(f32, @floatFromInt(row_idx + 1)) * self.cell_height;

                // Resolve colors
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

                // Background rect
                if (cell_bg) |cbg| {
                    _ = vec_batch.addRect(
                        .{ .x = cell_x, .y = cell_y_tl, .w = self.cell_width, .h = self.cell_height },
                        cbg.toFloat4(1.0),
                        .{ 0, 0, 0, 0 },
                        0,
                    );
                }

                // Text
                if (cell.has_text and cell.codepoint > 0x20 and cell.codepoint < 0x110000) {
                    var utf8_buf: [4]u8 = undefined;
                    const utf8_len = std.unicode.utf8Encode(
                        @intCast(cell.codepoint),
                        &utf8_buf,
                    ) catch 0;

                    if (utf8_len > 0) {
                        const text_y = cell_y_bl + self.cell_height * 0.2;
                        _ = text_batch.addString(
                            &self.atlas,
                            &self.font,
                            utf8_buf[0..utf8_len],
                            cell_x,
                            text_y,
                            self.font_size,
                            fg.toFloat4(1.0),
                        );
                    }
                }

                // Underline
                if (cell.style.underline != 0 and cell.has_text) {
                    _ = vec_batch.addRect(
                        .{ .x = cell_x, .y = cell_y_tl + self.cell_height - 1, .w = self.cell_width, .h = 1 },
                        fg.toFloat4(1.0),
                        .{ 0, 0, 0, 0 },
                        0,
                    );
                }

                // Strikethrough
                if (cell.style.strikethrough != false and cell.has_text) {
                    _ = vec_batch.addRect(
                        .{ .x = cell_x, .y = cell_y_tl + self.cell_height * 0.45, .w = self.cell_width, .h = 1 },
                        fg.toFloat4(1.0),
                        .{ 0, 0, 0, 0 },
                        0,
                    );
                }
            }
        }

        // Cursor (vector pipeline = top-left origin)
        if (cursor.visible and cursor.in_viewport) {
            const cx = @as(f32, @floatFromInt(cursor.x)) * self.cell_width;
            const cy = @as(f32, @floatFromInt(cursor.y)) * self.cell_height;
            const cursor_color = colors.foreground.toFloat4(1.0);

            switch (cursor.style) {
                .block => _ = vec_batch.addRect(
                    .{ .x = cx, .y = cy, .w = self.cell_width, .h = self.cell_height },
                    .{ cursor_color[0], cursor_color[1], cursor_color[2], 0.5 },
                    .{ 0, 0, 0, 0 },
                    0,
                ),
                .bar => _ = vec_batch.addRect(
                    .{ .x = cx, .y = cy, .w = 2, .h = self.cell_height },
                    cursor_color,
                    .{ 0, 0, 0, 0 },
                    0,
                ),
                .underline => _ = vec_batch.addRect(
                    .{ .x = cx, .y = cy + self.cell_height - 2, .w = self.cell_width, .h = 2 },
                    cursor_color,
                    .{ 0, 0, 0, 0 },
                    0,
                ),
                .block_hollow => _ = vec_batch.addRect(
                    .{ .x = cx, .y = cy, .w = self.cell_width, .h = self.cell_height },
                    .{ 0, 0, 0, 0 },
                    cursor_color,
                    1,
                ),
            }
        }

        // Draw vectors (backgrounds + decorations + cursor)
        if (vec_batch.shapeCount() > 0) {
            self.snail_renderer.drawVector(vec_batch.slice(), self.viewport_w, self.viewport_h);
        }

        // Draw text
        if (text_batch.glyphCount() > 0) {
            self.snail_renderer.draw(text_batch.slice(), mvp, self.viewport_w, self.viewport_h);
        }

        term.resetDirty();
    }
};
