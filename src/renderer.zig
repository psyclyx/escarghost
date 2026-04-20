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

fn hashColors(colors: terminal_mod.RenderColors) u64 {
    var h: u64 = 0xcbf29ce484222325; // FNV offset basis
    const m: u64 = 0x100000001b3; // FNV prime
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
    vec: []f32,
    generation: u64,
    byte_size: usize,
};

// Snail vertex layout constants for Y-patching.
// Text: 4 vertices * 20 floats. Y is at offset 1 within each vertex.
const TEXT_VERTEX_STRIDE = 20;
const TEXT_Y_OFFSETS = [4]usize{ 1, 21, 41, 61 };
// Vector: 6 vertices * 18 floats. rect.y is at offset 3 within each vertex.
const VEC_VERTEX_STRIDE = 18;
const VEC_FLOATS_PER_PRIM = VEC_VERTEX_STRIDE * 6;
const VEC_Y_OFFSETS = [6]usize{ 3, 21, 39, 57, 75, 93 };

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

/// Patch Y coordinates in vector vertex data by adding delta.
fn patchVecY(data: []f32, delta: f32) void {
    var i: usize = 0;
    while (i + VEC_FLOATS_PER_PRIM <= data.len) : (i += VEC_FLOATS_PER_PRIM) {
        inline for (VEC_Y_OFFSETS) |off| {
            data[i + off] += delta;
        }
    }
}

pub const Renderer = struct {
    font: snail.Font,
    atlas: snail.Atlas,
    snail_renderer: snail.Renderer,

    row_cache: std.AutoHashMap(u64, CacheEntry),
    generation: u64 = 0,
    color_hash: u64 = 0,
    cache_bytes: usize = 0,
    cache_budget: usize = 32 * 1024 * 1024,

    draw_text: []f32,
    draw_vec: []f32,
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
    prev_cursor_x: u16 = 0,
    prev_cursor_y: u16 = 0,
    prev_cursor_style: terminal_mod.CursorVisualStyle = .block,
    prev_cursor_visible: bool = false,

    pub var frame_stats: perf.FrameStats = .{};

    pub fn initCpu(self: *Renderer, allocator: std.mem.Allocator, font_data: []const u8, font_size: f32) !void {
        self.allocator = allocator;
        self.font_size = font_size;
        self.viewport_w = 0;
        self.viewport_h = 0;
        self.has_prev_frame = false;
        self.generation = 0;
        self.color_hash = 0;
        self.cache_bytes = 0;
        self.prev_cursor_x = 0;
        self.prev_cursor_y = 0;

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
        self.row_cache = std.AutoHashMap(u64, CacheEntry).init(allocator);

        const max_cells: usize = 400 * 200;
        self.draw_text = try allocator.alloc(f32, max_cells * snail.FLOATS_PER_GLYPH);
        errdefer allocator.free(self.draw_text);
        self.draw_vec = try allocator.alloc(f32, max_cells * @as(usize, snail.VECTOR_FLOATS_PER_PRIMITIVE) * 3);
        errdefer allocator.free(self.draw_vec);
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
        self.clearCache();
        self.row_cache.deinit();
        self.allocator.free(self.scratch_vec);
        self.allocator.free(self.scratch_text);
        self.allocator.free(self.draw_vec);
        self.allocator.free(self.draw_text);
        self.snail_renderer.deinit();
        self.atlas.deinit();
        self.font.deinit();
    }

    pub fn clearCache(self: *Renderer) void {
        var it = self.row_cache.valueIterator();
        while (it.next()) |e| {
            self.allocator.free(e.text);
            self.allocator.free(e.vec);
        }
        self.row_cache.clearRetainingCapacity();
        self.cache_bytes = 0;
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
        self.generation += 1;
        self.clearCache();
    }

    /// Build row vertices into scratch buffers at Y=0 (position-independent).
    /// NO cursor baked in — cursor is drawn as overlay.
    fn buildRow(
        self: *Renderer,
        term: *Terminal,
        default_fg: Rgb,
        default_bg: Rgb,
    ) struct { text_len: usize, vec_len: usize } {
        // Y=0 origin for both pipelines. Actual Y applied via patchTextY/patchVecY.
        const cell_y_tl: f32 = 0;
        const cell_y_bl: f32 = 0; // text baseline offset added below

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
                        _ = vec_batch.addRect(.{
                            .x = @as(f32, @floatFromInt(bg_span_start)) * self.cell_width,
                            .y = cell_y_tl,
                            .w = @as(f32, @floatFromInt(bg_span_len)) * self.cell_width,
                            .h = self.cell_height,
                        }, sc.toLinearFloat4(1.0), .{ 0, 0, 0, 0 }, 0);
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

            if (cell.has_text and cell.codepoint > 0x20 and cell.codepoint < 0x110000) {
                const gid = self.font.glyphIndex(cell.codepoint) catch 0;
                if (self.atlas.getGlyph(gid)) |info| {
                    _ = text_batch.addGlyph(
                        @as(f32, @floatFromInt(col_idx)) * self.cell_width,
                        cell_y_bl + self.cell_height * 0.2,
                        self.font_size, info.bbox, info.band_entry,
                        fg.toLinearFloat4(1.0), self.atlas.gl_layer,
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
                            fg.toLinearFloat4(1.0), self.atlas.gl_layer,
                        );
                }
                if (cell.style.underline != 0)
                    _ = vec_batch.addRect(.{
                        .x = @as(f32, @floatFromInt(col_idx)) * self.cell_width,
                        .y = cell_y_tl + self.cell_height - 1, .w = self.cell_width, .h = 1,
                    }, fg.toLinearFloat4(1.0), .{ 0, 0, 0, 0 }, 0);
                if (cell.style.strikethrough != false)
                    _ = vec_batch.addRect(.{
                        .x = @as(f32, @floatFromInt(col_idx)) * self.cell_width,
                        .y = cell_y_tl + self.cell_height * 0.45, .w = self.cell_width, .h = 1,
                    }, fg.toLinearFloat4(1.0), .{ 0, 0, 0, 0 }, 0);
            }
        }
        if (bg_span_len > 0) {
            if (bg_span_color) |sc| {
                _ = vec_batch.addRect(.{
                    .x = @as(f32, @floatFromInt(bg_span_start)) * self.cell_width,
                    .y = cell_y_tl,
                    .w = @as(f32, @floatFromInt(bg_span_len)) * self.cell_width,
                    .h = self.cell_height,
                }, sc.toLinearFloat4(1.0), .{ 0, 0, 0, 0 }, 0);
            }
        }

        return .{
            .text_len = text_batch.glyphCount() * snail.FLOATS_PER_GLYPH,
            .vec_len = vec_batch.shapeCount() * snail.VECTOR_FLOATS_PER_PRIMITIVE,
        };
    }

    fn cacheRow(self: *Renderer, row_id: u64, text_len: usize, vec_len: usize) void {
        if (self.row_cache.fetchRemove(row_id)) |kv| {
            self.cache_bytes -= kv.value.byte_size;
            self.allocator.free(kv.value.text);
            self.allocator.free(kv.value.vec);
        }

        const text = self.allocator.dupe(f32, self.scratch_text[0..text_len]) catch return;
        const vec = self.allocator.dupe(f32, self.scratch_vec[0..vec_len]) catch {
            self.allocator.free(text);
            return;
        };
        const byte_size = (text_len + vec_len) * @sizeOf(f32);
        self.row_cache.put(row_id, .{
            .text = text, .vec = vec,
            .generation = self.generation,
            .byte_size = byte_size,
        }) catch {
            self.allocator.free(text);
            self.allocator.free(vec);
            return;
        };
        self.cache_bytes += byte_size;

        // Lazy eviction when over budget — remove oldest entries
        // (HashMap iteration order is arbitrary, which approximates random eviction.
        // Good enough; a proper LRU is a future refinement.)
        while (self.cache_bytes > self.cache_budget) {
            var evict_it = self.row_cache.iterator();
            if (evict_it.next()) |entry| {
                self.cache_bytes -= entry.value_ptr.byte_size;
                self.allocator.free(entry.value_ptr.text);
                self.allocator.free(entry.value_ptr.vec);
                self.row_cache.removeByPtr(entry.key_ptr);
            } else break;
        }
    }

    /// Copy cached vertex data into draw buffers, applying Y offset.
    fn appendCached(
        self: *Renderer,
        entry: CacheEntry,
        text_y_delta: f32,
        vec_y_delta: f32,
        draw_text_len: *usize,
        draw_vec_len: *usize,
    ) void {
        if (entry.vec.len > 0) {
            @memcpy(self.draw_vec[draw_vec_len.*..][0..entry.vec.len], entry.vec);
            patchVecY(self.draw_vec[draw_vec_len.*..][0..entry.vec.len], vec_y_delta);
            draw_vec_len.* += entry.vec.len;
        }
        if (entry.text.len > 0) {
            @memcpy(self.draw_text[draw_text_len.*..][0..entry.text.len], entry.text);
            patchTextY(self.draw_text[draw_text_len.*..][0..entry.text.len], text_y_delta);
            draw_text_len.* += entry.text.len;
        }
    }

    pub fn drawFrame(self: *Renderer, term: *Terminal) !bool {
        const frame_timer = perf.Timer.now();

        try term.updateRenderState();
        const dirty = term.getDirty();
        const cursor = term.getCursor();

        // Cursor changes need a redraw even if ghostty says cells aren't dirty
        const cursor_changed = cursor.x != self.prev_cursor_x or
            cursor.y != self.prev_cursor_y or
            @intFromEnum(cursor.style) != @intFromEnum(self.prev_cursor_style) or
            cursor.visible != self.prev_cursor_visible;
        if (dirty == .false_ and !cursor_changed) return false;

        const colors = term.getColors();
        const default_fg = colors.foreground;
        const default_bg = colors.background;

        // Check for generation bump
        const new_hash = hashColors(colors);
        if (new_hash != self.color_hash) {
            self.generation += 1;
            self.color_hash = new_hash;
        }

        var draw_text_len: usize = 0;
        var draw_vec_len: usize = 0;

        term.beginRowIteration();
        var row_idx: u16 = 0;
        while (term.nextRow()) : (row_idx += 1) {
            if (row_idx >= 200) break;
            const row_id = term.getRowId();

            // Y offsets for this row position
            const vec_y = @as(f32, @floatFromInt(row_idx)) * self.cell_height;
            const text_y = self.viewport_h - @as(f32, @floatFromInt(row_idx + 1)) * self.cell_height;

            // Check for cache hit with valid generation
            const needs_rebuild = dirty == .full or !self.has_prev_frame or
                term.isRowDirty();

            if (!needs_rebuild) {
                if (self.row_cache.get(row_id)) |entry| {
                    if (entry.generation == self.generation) {
                        // Cache hit — copy + Y-patch
                        self.appendCached(entry, text_y, vec_y, &draw_text_len, &draw_vec_len);
                        continue;
                    }
                }
            }

            // Cache miss or dirty — rebuild at Y=0, cache, then copy + Y-patch
            const lens = self.buildRow(term, default_fg, default_bg);
            self.cacheRow(row_id, lens.text_len, lens.vec_len);

            if (lens.vec_len > 0) {
                @memcpy(self.draw_vec[draw_vec_len..][0..lens.vec_len], self.scratch_vec[0..lens.vec_len]);
                patchVecY(self.draw_vec[draw_vec_len..][0..lens.vec_len], vec_y);
                draw_vec_len += lens.vec_len;
            }
            if (lens.text_len > 0) {
                @memcpy(self.draw_text[draw_text_len..][0..lens.text_len], self.scratch_text[0..lens.text_len]);
                patchTextY(self.draw_text[draw_text_len..][0..lens.text_len], text_y);
                draw_text_len += lens.text_len;
            }
        }

        self.has_prev_frame = true;
        self.prev_cursor_x = cursor.x;
        self.prev_cursor_y = cursor.y;
        self.prev_cursor_style = cursor.style;
        self.prev_cursor_visible = cursor.visible;

        // Cursor overlay (never baked into cache)
        if (cursor.visible and cursor.in_viewport) {
            const cx = @as(f32, @floatFromInt(cursor.x)) * self.cell_width;
            const cy = @as(f32, @floatFromInt(cursor.y)) * self.cell_height;
            const cc = if (colors.cursor) |col| col.toLinearFloat4(1.0) else colors.foreground.toLinearFloat4(1.0);

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

            // Block cursor: re-draw glyph with bg color on top of cursor rect
            if (cursor.style == .block) {
                if (term.selectCell(cursor.x)) {
                    const cell = term.getCellInfo();
                    if (cell.has_text and cell.codepoint > 0x20 and cell.codepoint < 0x110000) {
                        const gid = self.font.glyphIndex(cell.codepoint) catch 0;
                        if (self.atlas.getGlyph(gid)) |info| {
                            const cursor_text_y = self.viewport_h - @as(f32, @floatFromInt(cursor.y + 1)) * self.cell_height + self.cell_height * 0.2;
                            var inv_buf: [snail.FLOATS_PER_GLYPH]f32 = undefined;
                            var inv_batch = snail.Batch.init(&inv_buf);
                            _ = inv_batch.addGlyph(
                                cx, cursor_text_y, self.font_size,
                                info.bbox, info.band_entry,
                                colors.background.toLinearFloat4(1.0),
                                self.atlas.gl_layer,
                            );
                            @memcpy(self.draw_text[draw_text_len..][0..snail.FLOATS_PER_GLYPH], inv_batch.slice());
                            draw_text_len += snail.FLOATS_PER_GLYPH;
                        }
                    }
                }
            }
        }

        // Draw
        const bg4 = colors.background.toLinearFloat4(1.0);
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
