const std = @import("std");

pub const RequestedRenderPath = enum {
    auto,
    cpu,
    gpu,
};

pub const RendererDebug = struct {
    startup: bool = false,
    renderers: bool = false,
    frames: bool = false,
    atlas: bool = false,
    pty: bool = false,
    commits: bool = false,

    pub fn anyLogs(self: RendererDebug) bool {
        return self.startup or self.renderers or self.frames or self.atlas or self.pty or self.commits;
    }

    pub fn enableAllLogs(self: *RendererDebug) void {
        self.startup = true;
        self.renderers = true;
        self.frames = true;
        self.atlas = true;
        self.pty = true;
        self.commits = true;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

pub fn parseRequestedRenderPath(value: ?[]const u8) RequestedRenderPath {
    const raw = value orelse return .auto;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return .auto;
    if (eql(trimmed, "cpu")) return .cpu;
    if (eql(trimmed, "gpu")) return .gpu;
    if (eql(trimmed, "auto")) return .auto;
    return .auto;
}

pub fn parseRendererDebug(value: ?[]const u8) RendererDebug {
    var result: RendererDebug = .{};
    const raw = value orelse return result;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return result;

    if (eql(trimmed, "0") or eql(trimmed, "false") or eql(trimmed, "off")) return result;
    if (eql(trimmed, "1") or eql(trimmed, "true") or eql(trimmed, "on") or eql(trimmed, "log") or eql(trimmed, "trace")) {
        result.enableAllLogs();
        return result;
    }
    if (eql(trimmed, "all")) {
        result.enableAllLogs();
        return result;
    }

    var it = std.mem.tokenizeAny(u8, trimmed, ", ");
    while (it.next()) |token| {
        if (eql(token, "log") or eql(token, "trace") or eql(token, "verbose")) {
            result.enableAllLogs();
        } else if (eql(token, "startup")) {
            result.startup = true;
        } else if (eql(token, "renderers") or eql(token, "renderer") or eql(token, "helper") or eql(token, "gpu") or eql(token, "ipc")) {
            result.renderers = true;
        } else if (eql(token, "frames") or eql(token, "frame") or eql(token, "render")) {
            result.frames = true;
        } else if (eql(token, "atlas")) {
            result.atlas = true;
        } else if (eql(token, "pty")) {
            result.pty = true;
        } else if (eql(token, "commits") or eql(token, "commit")) {
            result.commits = true;
        } else if (eql(token, "all")) {
            result.enableAllLogs();
        }
    }
    return result;
}

pub const RuntimeFlags = struct {
    reset_atlas_each_frame: bool = false,
};

pub fn parseRuntimeFlags(value: ?[]const u8) RuntimeFlags {
    var result: RuntimeFlags = .{};
    const raw = value orelse return result;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (trimmed.len == 0) return result;
    if (eql(trimmed, "0") or eql(trimmed, "false") or eql(trimmed, "off")) return result;

    var it = std.mem.tokenizeAny(u8, trimmed, ", ");
    while (it.next()) |token| {
        if (eql(token, "reset-atlas") or eql(token, "clear-atlas") or eql(token, "miss-glyphs")) {
            result.reset_atlas_each_frame = true;
        }
    }
    return result;
}
