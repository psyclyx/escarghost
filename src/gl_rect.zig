//! Minimal batched GL quad renderer for solid colored rectangles.
//! Replaces snail's removed VectorBatch for terminal backgrounds,
//! underlines, cursors, and other simple solid-color geometry.

const snail = @import("snail");
const row_build = @import("row_build.zig");

const gl = @cImport({
    @cDefine("GL_GLEXT_PROTOTYPES", "1");
    @cInclude("GL/gl.h");
    @cInclude("GL/glext.h");
});

pub const ColoredRect = row_build.ColoredRect;

const vert_src: [*c]const u8 =
    \\#version 330 core
    \\layout(location = 0) in vec2 a_pos;
    \\layout(location = 1) in vec4 a_color;
    \\uniform mat4 u_mvp;
    \\out vec4 v_color;
    \\void main() {
    \\    gl_Position = u_mvp * vec4(a_pos, 0.0, 1.0);
    \\    v_color = a_color;
    \\}
;

const frag_src: [*c]const u8 =
    \\#version 330 core
    \\in vec4 v_color;
    \\out vec4 frag_color;
    \\void main() {
    \\    frag_color = v_color;
    \\}
;

// 6 floats per vertex (x, y, r, g, b, a), 4 vertices per rect
const FLOATS_PER_VERTEX = 6;
const VERTICES_PER_RECT = 4;
const INDICES_PER_RECT = 6;
const MAX_RECTS = 8192;

pub const GlRectRenderer = struct {
    program: gl.GLuint = 0,
    vao: gl.GLuint = 0,
    vbo: gl.GLuint = 0,
    ebo: gl.GLuint = 0,
    mvp_loc: gl.GLint = -1,

    pub fn init() GlRectRenderer {
        var self: GlRectRenderer = .{};

        const vs = compileShader(gl.GL_VERTEX_SHADER, vert_src);
        const fs = compileShader(gl.GL_FRAGMENT_SHADER, frag_src);
        if (vs == 0 or fs == 0) return self;

        self.program = gl.glCreateProgram();
        gl.glAttachShader(self.program, vs);
        gl.glAttachShader(self.program, fs);
        gl.glLinkProgram(self.program);
        gl.glDeleteShader(vs);
        gl.glDeleteShader(fs);

        self.mvp_loc = gl.glGetUniformLocation(self.program, "u_mvp");

        gl.glGenVertexArrays(1, &self.vao);
        gl.glGenBuffers(1, &self.vbo);
        gl.glGenBuffers(1, &self.ebo);

        gl.glBindVertexArray(self.vao);

        // Vertex buffer (dynamic)
        gl.glBindBuffer(gl.GL_ARRAY_BUFFER, self.vbo);
        gl.glBufferData(gl.GL_ARRAY_BUFFER, @intCast(MAX_RECTS * VERTICES_PER_RECT * FLOATS_PER_VERTEX * @sizeOf(f32)), null, gl.GL_DYNAMIC_DRAW);

        // Position (vec2)
        gl.glEnableVertexAttribArray(0);
        gl.glVertexAttribPointer(0, 2, gl.GL_FLOAT, gl.GL_FALSE, FLOATS_PER_VERTEX * @sizeOf(f32), @ptrFromInt(0));
        // Color (vec4)
        gl.glEnableVertexAttribArray(1);
        gl.glVertexAttribPointer(1, 4, gl.GL_FLOAT, gl.GL_FALSE, FLOATS_PER_VERTEX * @sizeOf(f32), @ptrFromInt(2 * @sizeOf(f32)));

        // Index buffer (static pattern: 0,1,2, 0,2,3 per quad)
        var indices: [MAX_RECTS * INDICES_PER_RECT]u32 = undefined;
        for (0..MAX_RECTS) |i| {
            const base: u32 = @intCast(i * VERTICES_PER_RECT);
            const idx = i * INDICES_PER_RECT;
            indices[idx + 0] = base + 0;
            indices[idx + 1] = base + 1;
            indices[idx + 2] = base + 2;
            indices[idx + 3] = base + 0;
            indices[idx + 4] = base + 2;
            indices[idx + 5] = base + 3;
        }
        gl.glBindBuffer(gl.GL_ELEMENT_ARRAY_BUFFER, self.ebo);
        gl.glBufferData(gl.GL_ELEMENT_ARRAY_BUFFER, @intCast(@sizeOf(@TypeOf(indices))), &indices, gl.GL_STATIC_DRAW);

        gl.glBindVertexArray(0);
        return self;
    }

    pub fn deinit(self: *GlRectRenderer) void {
        if (self.ebo != 0) gl.glDeleteBuffers(1, &self.ebo);
        if (self.vbo != 0) gl.glDeleteBuffers(1, &self.vbo);
        if (self.vao != 0) gl.glDeleteVertexArrays(1, &self.vao);
        if (self.program != 0) gl.glDeleteProgram(self.program);
    }

    pub fn drawRects(self: *const GlRectRenderer, rects: []const ColoredRect, mvp: snail.Mat4) void {
        if (rects.len == 0 or self.program == 0) return;

        gl.glUseProgram(self.program);
        gl.glUniformMatrix4fv(self.mvp_loc, 1, gl.GL_FALSE, &mvp.data);
        gl.glBindVertexArray(self.vao);

        var offset: usize = 0;
        while (offset < rects.len) {
            const batch_size = @min(rects.len - offset, MAX_RECTS);
            const batch = rects[offset..][0..batch_size];

            var verts: [MAX_RECTS * VERTICES_PER_RECT * FLOATS_PER_VERTEX]f32 = undefined;
            for (batch, 0..) |rect, i| {
                const x0 = rect.x;
                const y0 = rect.y;
                const x1 = rect.x + rect.w;
                const y1 = rect.y + rect.h;
                const c = rect.color;
                const base = i * VERTICES_PER_RECT * FLOATS_PER_VERTEX;
                // BL
                verts[base + 0] = x0;
                verts[base + 1] = y0;
                verts[base + 2] = c[0];
                verts[base + 3] = c[1];
                verts[base + 4] = c[2];
                verts[base + 5] = c[3];
                // BR
                verts[base + 6] = x1;
                verts[base + 7] = y0;
                verts[base + 8] = c[0];
                verts[base + 9] = c[1];
                verts[base + 10] = c[2];
                verts[base + 11] = c[3];
                // TR
                verts[base + 12] = x1;
                verts[base + 13] = y1;
                verts[base + 14] = c[0];
                verts[base + 15] = c[1];
                verts[base + 16] = c[2];
                verts[base + 17] = c[3];
                // TL
                verts[base + 18] = x0;
                verts[base + 19] = y1;
                verts[base + 20] = c[0];
                verts[base + 21] = c[1];
                verts[base + 22] = c[2];
                verts[base + 23] = c[3];
            }

            gl.glBindBuffer(gl.GL_ARRAY_BUFFER, self.vbo);
            const byte_len: isize = @intCast(batch_size * VERTICES_PER_RECT * FLOATS_PER_VERTEX * @sizeOf(f32));
            gl.glBufferSubData(gl.GL_ARRAY_BUFFER, 0, byte_len, &verts);
            gl.glDrawElements(gl.GL_TRIANGLES, @intCast(batch_size * INDICES_PER_RECT), gl.GL_UNSIGNED_INT, @ptrFromInt(0));

            offset += batch_size;
        }

        gl.glBindVertexArray(0);
        gl.glUseProgram(0);
    }
};

fn compileShader(shader_type: gl.GLenum, source: [*c]const u8) gl.GLuint {
    const shader = gl.glCreateShader(shader_type);
    gl.glShaderSource(shader, 1, &source, null);
    gl.glCompileShader(shader);
    var ok: gl.GLint = 0;
    gl.glGetShaderiv(shader, gl.GL_COMPILE_STATUS, &ok);
    if (ok == 0) {
        gl.glDeleteShader(shader);
        return 0;
    }
    return shader;
}
