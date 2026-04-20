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
    if (fc.FcPatternGetInteger(pattern, fc.FC_RGBA, 0, &rgba) != fc.FcResultMatch)
        return .rgb;

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

    text_buf: []f32,
    vector_buf: []f32,

    cell_width: f32,
    cell_height: f32,
    font_size: f32,

    viewport_w: f32,
    viewport_h: f32,

    allocator: std.mem.Allocator,

    // Perf tracking
    pub var frame_stats: perf.FrameStats = .{};

    /// Phase 1: CPU-side init — font parse, atlas build, cell metrics.
    /// No GL needed. Can run on a background thread.
    pub fn initCpu(self: *Renderer, allocator: std.mem.Allocator, font_data: []const u8, font_size: f32) !void {
        self.allocator = allocator;
        self.font_size = font_size;
        self.viewport_w = 0;
        self.viewport_h = 0;

        self.font = try snail.Font.init(font_data);
        errdefer self.font.deinit();

        self.atlas = try snail.Atlas.initAscii(allocator, &self.font, &snail.ASCII_PRINTABLE);
        errdefer self.atlas.deinit();

        // Cell metrics (no GL needed)
        const units_per_em: f32 = @floatFromInt(self.font.unitsPerEm());
        const scale = font_size / units_per_em;
        const m_gid = self.font.glyphIndex('M') catch 0;
        const m_info = self.atlas.getGlyph(m_gid);
        self.cell_width = if (m_info) |g| @ceil(@as(f32, @floatFromInt(g.advance_width)) * scale) else @ceil(font_size * 0.6);
        self.cell_height = @ceil(font_size * 1.2);

        // Vertex buffers
        const max_cells = 400 * 150;
        self.text_buf = try allocator.alloc(f32, max_cells * snail.FLOATS_PER_GLYPH);
        errdefer allocator.free(self.text_buf);
        self.vector_buf = try allocator.alloc(f32, max_cells * snail.VECTOR_FLOATS_PER_PRIMITIVE);
    }

    /// Phase 2: GPU-side init — shader compile, texture upload.
    /// Must be called on the GL thread after initCpu and after EGL context is current.
    pub fn initGpu(self: *Renderer) !void {
        self.snail_renderer = try snail.Renderer.init();
        self.snail_renderer.uploadAtlas(&self.atlas);
        self.snail_renderer.setSubpixelOrder(detectSubpixelOrder());
        self.snail_renderer.setFillRule(.non_zero);
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

    /// Returns true if a frame was actually drawn (dirty content existed).
    pub fn drawFrame(self: *Renderer, term: *Terminal) !bool {
        const frame_timer = perf.Timer.now();

        try term.updateRenderState();
        if (term.getDirty() == .false_) return false;

        const colors = term.getColors();
        const cursor = term.getCursor();

        const bg = colors.background.toFloat4(1.0);
        gl.glClearColor(bg[0], bg[1], bg[2], bg[3]);
        gl.glClear(gl.GL_COLOR_BUFFER_BIT);

        const mvp = snail.Mat4.ortho(0, self.viewport_w, 0, self.viewport_h, -1, 1);

        self.snail_renderer.beginFrame();

        var text_batch = snail.Batch.init(self.text_buf);
        var vec_batch = snail.VectorBatch.init(self.vector_buf);

        const default_fg = colors.foreground;
        const default_bg = colors.background;

        // Single pass: build vertex batches. Atlas misses handled inline
        // (rare — only on first encounter of a new codepoint).
        term.beginRowIteration();
        var row_idx: u16 = 0;
        while (term.nextRow()) : (row_idx += 1) {
            const cell_y_tl = @as(f32, @floatFromInt(row_idx)) * self.cell_height;
            const cell_y_bl = self.viewport_h - @as(f32, @floatFromInt(row_idx + 1)) * self.cell_height;

            term.beginCellIteration();
            var col_idx: u16 = 0;
            while (term.nextCell()) : (col_idx += 1) {
                const cell = term.getCellInfo();
                const cell_x = @as(f32, @floatFromInt(col_idx)) * self.cell_width;

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

                // Background
                if (cell_bg) |cbg| {
                    _ = vec_batch.addRect(
                        .{ .x = cell_x, .y = cell_y_tl, .w = self.cell_width, .h = self.cell_height },
                        cbg.toFloat4(1.0),
                        .{ 0, 0, 0, 0 },
                        0,
                    );
                }

                // Text — direct glyph vertex generation, no HarfBuzz/layout overhead
                if (cell.has_text and cell.codepoint > 0x20 and cell.codepoint < 0x110000) {
                    const gid = self.font.glyphIndex(cell.codepoint) catch 0;
                    if (self.atlas.getGlyph(gid)) |info| {
                        _ = text_batch.addGlyph(
                            cell_x,
                            cell_y_bl + self.cell_height * 0.2,
                            self.font_size,
                            info.bbox,
                            info.band_entry,
                            fg.toFloat4(1.0),
                            self.atlas.gl_layer,
                        );
                    } else {
                        // Atlas miss — add codepoint and re-upload (rare)
                        const cps = [1]u32{cell.codepoint};
                        if (self.atlas.addCodepoints(&cps) catch false) {
                            self.snail_renderer.uploadAtlas(&self.atlas);
                        }
                        // Retry after upload
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

        // Cursor
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

        // Draw
        if (vec_batch.shapeCount() > 0) {
            self.snail_renderer.drawVector(vec_batch.slice(), self.viewport_w, self.viewport_h);
        }
        if (text_batch.glyphCount() > 0) {
            self.snail_renderer.draw(text_batch.slice(), mvp, self.viewport_w, self.viewport_h);
        }

        // Block cursor: re-draw glyph with inverted color
        if (cursor.visible and cursor.in_viewport and cursor.style == .block) {
            // Use select() to jump directly to the cursor cell instead of iterating
            term.beginRowIteration();
            var sr: u16 = 0;
            while (term.nextRow()) : (sr += 1) {
                if (sr == cursor.y) {
                    term.beginCellIteration();
                    if (term.selectCell(cursor.x)) {
                        const cell = term.getCellInfo();
                        if (cell.has_text and cell.codepoint > 0x20 and cell.codepoint < 0x110000) {
                            const gid = self.font.glyphIndex(cell.codepoint) catch 0;
                            if (self.atlas.getGlyph(gid)) |info| {
                                const cy_bl = self.viewport_h - @as(f32, @floatFromInt(cursor.y + 1)) * self.cell_height;
                                var inv_batch = snail.Batch.init(self.text_buf);
                                _ = inv_batch.addGlyph(
                                    @as(f32, @floatFromInt(cursor.x)) * self.cell_width,
                                    cy_bl + self.cell_height * 0.2,
                                    self.font_size,
                                    info.bbox,
                                    info.band_entry,
                                    colors.background.toFloat4(1.0),
                                    self.atlas.gl_layer,
                                );
                                if (inv_batch.glyphCount() > 0) {
                                    self.snail_renderer.draw(inv_batch.slice(), mvp, self.viewport_w, self.viewport_h);
                                }
                            }
                        }
                    }
                    break;
                }
            }
        }

        term.resetDirty();

        frame_stats.record(frame_timer.elapsedUs());
        return true;
    }
};
