//! Bell (BEL, 0x07) handler.
//!
//! Modes (set via config):
//!   off     — drop silently
//!   visual  — invert the grey ramp for `visual_duration_ms` (default)
//!   audible — synthesize a short tone via paplay/aplay
//!   both    — visual and audible together
//!
//! Both paths are debounced/coalesced so a process spamming `\a` doesn't
//! turn into a strobe + audio stream. The visual deadline always wins
//! the latest ring (so the flash duration stays the *configured* time
//! even under spam); the audible path is rate-limited to one shot per
//! `audible_debounce_ms`.
//!
//! Audio is played by a small worker thread that owns a single spawn
//! pid. On ring() the manager pushes a token through a pipe; the worker
//! forks+execvp(paplay) / execvp(aplay) on a synthesized .wav written
//! at init() and waitpid's the spawned process before returning to its
//! park state. Failure modes (no audio, no paplay) are swallowed —
//! we'd rather drop the beep than slow down PTY drain.

const std = @import("std");

const c = @cImport({
    @cInclude("stdlib.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/wait.h");
    @cInclude("sys/stat.h");
    @cInclude("string.h");
    @cInclude("errno.h");
    @cInclude("math.h");
    @cInclude("time.h");
});

/// Bell-local monotonic clock so this module doesn't drag in
/// diagnostics.zig (which transitively pulls in the render/terminal
/// stack). Mirrors diagnostics.monotonicNowNs.
fn nowNs() u64 {
    var ts: c.struct_timespec = undefined;
    if (c.clock_gettime(c.CLOCK_MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.tv_sec)) * std.time.ns_per_s +
        @as(u64, @intCast(ts.tv_nsec));
}

pub const Mode = enum {
    off,
    visual,
    audible,
    both,
};

pub const Config = struct {
    mode: Mode = .visual,
    visual_duration_ms: u32 = 150,
    audible_debounce_ms: u32 = 200,
};

/// Process-wide pointer used by the terminal's bell callback (which
/// has no userdata channel). main installs it after constructing the
/// manager and clears it before deinit. Touched from the PTY-drain
/// thread (ring) and the audio worker thread (read of cfg only).
pub var g_manager: ?*Manager = null;

pub fn callback() void {
    if (g_manager) |m| m.ring();
}

pub const Manager = struct {
    cfg: Config = .{},

    /// Set to monotonic-ns deadline when a visual bell is in progress.
    /// Zero when no visual is active. Updated on every ring() so back-
    /// to-back rings keep the flash visible.
    visual_until_ns: u64 = 0,

    /// Anti-spam gate for the audible path. ring() refuses to enqueue a
    /// fresh tone until this deadline has passed.
    next_audible_allowed_ns: u64 = 0,

    /// Worker thread + pipe used to fire-and-forget the audio process
    /// off the hot PTY drain path. Null members when audible mode is
    /// disabled.
    audio_thread: ?std.Thread = null,
    pipe_fds: [2]c_int = .{ -1, -1 },
    /// Path of the synthesized .wav file. Owned; freed in deinit.
    /// Created lazily on the first ring so disabled-audio startup is
    /// allocation-free.
    wav_path: ?[]u8 = null,
    /// Allocator used for `wav_path`. Captured at init().
    allocator: std.mem.Allocator = undefined,
    stop_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !Manager {
        var self: Manager = .{ .cfg = cfg, .allocator = allocator };
        if (cfg.mode == .audible or cfg.mode == .both) {
            try self.startAudio();
        }
        return self;
    }

    pub fn deinit(self: *Manager) void {
        if (self.audio_thread != null) {
            self.stop_requested.store(true, .release);
            // Wake the worker if it's blocked on read().
            if (self.pipe_fds[1] >= 0) {
                const byte: u8 = 0;
                _ = c.write(self.pipe_fds[1], &byte, 1);
            }
            self.audio_thread.?.join();
            self.audio_thread = null;
        }
        if (self.pipe_fds[0] >= 0) _ = c.close(self.pipe_fds[0]);
        if (self.pipe_fds[1] >= 0) _ = c.close(self.pipe_fds[1]);
        self.pipe_fds = .{ -1, -1 };
        if (self.wav_path) |p| {
            // Best-effort cleanup; the file is in /tmp anyway.
            const path_z = self.allocator.dupeZ(u8, p) catch null;
            if (path_z) |z| {
                _ = c.unlink(z.ptr);
                self.allocator.free(z);
            }
            self.allocator.free(p);
            self.wav_path = null;
        }
    }

    /// Invoked from the terminal's bell callback. Safe to call from any
    /// thread; both paths are non-blocking.
    pub fn ring(self: *Manager) void {
        if (self.cfg.mode == .off) return;
        const now = nowNs();

        if (self.cfg.mode == .visual or self.cfg.mode == .both) {
            self.visual_until_ns = now + @as(u64, self.cfg.visual_duration_ms) * std.time.ns_per_ms;
        }

        if (self.cfg.mode == .audible or self.cfg.mode == .both) {
            if (now >= self.next_audible_allowed_ns and self.pipe_fds[1] >= 0) {
                const token: u8 = 1;
                // EAGAIN on a full pipe → drop this beep (already
                // queued plenty). Otherwise count it as fired.
                if (c.write(self.pipe_fds[1], &token, 1) == 1) {
                    self.next_audible_allowed_ns = now + @as(u64, self.cfg.audible_debounce_ms) * std.time.ns_per_ms;
                }
            }
        }
    }

    /// True if the renderer should display an inverted snapshot this
    /// frame. False once the deadline elapses.
    pub fn isVisualActive(self: *const Manager) bool {
        if (self.visual_until_ns == 0) return false;
        return nowNs() < self.visual_until_ns;
    }

    /// Time-until-redraw hint for the main loop's poll timeout. Returns
    /// null when no visual bell is active (so the loop doesn't wake on
    /// our account).
    pub fn visualTimeoutMs(self: *const Manager) ?c_int {
        if (self.visual_until_ns == 0) return null;
        const now = nowNs();
        if (now >= self.visual_until_ns) return 0;
        const delta_ms = (self.visual_until_ns - now) / std.time.ns_per_ms + 1;
        return @intCast(@min(delta_ms, @as(u64, std.math.maxInt(c_int))));
    }

    /// Clears the visual deadline once consumed. Called after the
    /// renderer has committed a non-bell frame on the trailing edge.
    pub fn clearVisualIfExpired(self: *Manager) void {
        if (self.visual_until_ns == 0) return;
        if (nowNs() >= self.visual_until_ns) {
            self.visual_until_ns = 0;
        }
    }

    fn startAudio(self: *Manager) !void {
        var fds: [2]c_int = undefined;
        if (c.pipe(&fds) != 0) return error.PipeFailed;
        // Non-blocking write so `ring()` can never stall on a full pipe.
        const flags = c.fcntl(fds[1], c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fds[1], c.F_SETFL, flags | c.O_NONBLOCK);
        self.pipe_fds = fds;

        const wav = try writeBellWav(self.allocator);
        errdefer self.allocator.free(wav);
        self.wav_path = wav;

        self.audio_thread = try std.Thread.spawn(.{}, audioMain, .{self});
    }

    fn audioMain(self: *Manager) void {
        while (!self.stop_requested.load(.acquire)) {
            var byte: u8 = 0;
            const n = c.read(self.pipe_fds[0], &byte, 1);
            if (n <= 0) {
                if (self.stop_requested.load(.acquire)) return;
                continue;
            }
            if (byte == 0) return; // shutdown sentinel
            const wav = self.wav_path orelse continue;
            playWav(wav);
        }
    }
};

// ── Audio synthesis ──
//
// 440 Hz sine, 22.05 kHz mono, 16-bit PCM, 120 ms. ~5 KB on disk. We
// write it once on init to a stable /tmp path so the audio worker can
// fork+exec `paplay` (or `aplay`) without re-synthesizing each ring.

const wav_sample_rate: u32 = 22050;
const wav_duration_ms: u32 = 120;
const wav_frequency_hz: f32 = 880.0; // close to a 'system beep'

fn writeBellWav(allocator: std.mem.Allocator) ![]u8 {
    const path = try synthPath(allocator);
    errdefer allocator.free(path);

    const sample_count: usize = (@as(usize, wav_sample_rate) * wav_duration_ms) / 1000;
    const byte_count: usize = sample_count * 2; // mono int16

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.ensureTotalCapacity(allocator, 44 + byte_count);

    // RIFF header
    try buf.appendSlice(allocator, "RIFF");
    try writeU32Le(&buf, allocator, @intCast(36 + byte_count));
    try buf.appendSlice(allocator, "WAVE");
    // fmt subchunk
    try buf.appendSlice(allocator, "fmt ");
    try writeU32Le(&buf, allocator, 16); // PCM fmt size
    try writeU16Le(&buf, allocator, 1); // PCM format
    try writeU16Le(&buf, allocator, 1); // channels
    try writeU32Le(&buf, allocator, wav_sample_rate);
    try writeU32Le(&buf, allocator, wav_sample_rate * 2); // byte rate
    try writeU16Le(&buf, allocator, 2); // block align
    try writeU16Le(&buf, allocator, 16); // bits per sample
    // data subchunk
    try buf.appendSlice(allocator, "data");
    try writeU32Le(&buf, allocator, @intCast(byte_count));

    // Sine with a short linear attack/release envelope so it sounds
    // like a beep rather than a click. 8 ms ramps, sustain in between.
    const ramp_samples: usize = (@as(usize, wav_sample_rate) * 8) / 1000;
    var i: usize = 0;
    while (i < sample_count) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(wav_sample_rate));
        const env: f32 = blk: {
            if (i < ramp_samples) break :blk @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(ramp_samples));
            if (i >= sample_count - ramp_samples) {
                const tail = sample_count - i;
                break :blk @as(f32, @floatFromInt(tail)) / @as(f32, @floatFromInt(ramp_samples));
            }
            break :blk 1.0;
        };
        const amplitude: f32 = 0.35 * env;
        const sample_f: f32 = amplitude * std.math.sin(2.0 * std.math.pi * wav_frequency_hz * t);
        const sample_i: i16 = @intFromFloat(sample_f * 32767.0);
        try buf.append(allocator, @bitCast(@as(u8, @truncate(@as(u16, @bitCast(sample_i))))));
        try buf.append(allocator, @bitCast(@as(u8, @truncate(@as(u16, @bitCast(sample_i)) >> 8))));
    }

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = c.open(path_z.ptr, c.O_WRONLY | c.O_CREAT | c.O_TRUNC, @as(c_uint, 0o600));
    if (fd < 0) return error.WavWriteFailed;
    defer _ = c.close(fd);
    if (c.write(fd, buf.items.ptr, buf.items.len) != @as(isize, @intCast(buf.items.len))) {
        return error.WavWriteFailed;
    }

    return path;
}

fn writeU16Le(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, v: u16) !void {
    try buf.append(allocator, @intCast(v & 0xff));
    try buf.append(allocator, @intCast((v >> 8) & 0xff));
}

fn writeU32Le(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, v: u32) !void {
    try buf.append(allocator, @intCast(v & 0xff));
    try buf.append(allocator, @intCast((v >> 8) & 0xff));
    try buf.append(allocator, @intCast((v >> 16) & 0xff));
    try buf.append(allocator, @intCast((v >> 24) & 0xff));
}

fn synthPath(allocator: std.mem.Allocator) ![]u8 {
    const uid = c.getuid();
    return try std.fmt.allocPrint(allocator, "/tmp/scrgo-bell-{d}.wav", .{uid});
}

// ── Playback ──
//
// We fork+execvp twice: first try `paplay` (PulseAudio / PipeWire),
// then `aplay` (ALSA). If neither is on $PATH, the bell is silent —
// matches the "do whatever is sane, don't go overboard" brief.

fn playWav(path: []const u8) void {
    const pid = c.fork();
    if (pid < 0) return;
    if (pid == 0) {
        // Child: detach stdio so paplay can't write to our terminal.
        const devnull = c.open("/dev/null", c.O_RDWR);
        if (devnull >= 0) {
            _ = c.dup2(devnull, 0);
            _ = c.dup2(devnull, 1);
            _ = c.dup2(devnull, 2);
            if (devnull > 2) _ = c.close(devnull);
        }

        var path_buf: [4096]u8 = undefined;
        const path_z = std.fmt.bufPrintZ(&path_buf, "{s}", .{path}) catch c._exit(127);
        const argv0 = "paplay";
        const argv1 = "aplay";
        const argv = [_:null]?[*:0]const u8{ undefined, path_z.ptr, null };
        // Try paplay first.
        var argv_a = argv;
        argv_a[0] = argv0;
        _ = c.execvp(argv0, @ptrCast(&argv_a));
        // Then aplay.
        var argv_b = argv;
        argv_b[0] = argv1;
        _ = c.execvp(argv1, @ptrCast(&argv_b));
        c._exit(127);
    }
    // Parent: wait for the child so we don't accumulate zombies.
    // playWav is only called from the audio worker thread, which
    // serializes rings — at most one bell process exists at a time.
    var status: c_int = 0;
    _ = c.waitpid(pid, &status, 0);
}

// ── Config parsing ──

pub fn parseMode(s: []const u8) ?Mode {
    if (std.ascii.eqlIgnoreCase(s, "off")) return .off;
    if (std.ascii.eqlIgnoreCase(s, "none")) return .off;
    if (std.ascii.eqlIgnoreCase(s, "visual")) return .visual;
    if (std.ascii.eqlIgnoreCase(s, "audible")) return .audible;
    if (std.ascii.eqlIgnoreCase(s, "both")) return .both;
    return null;
}

// ── Tests ──

test "parseMode" {
    try std.testing.expectEqual(@as(?Mode, .off), parseMode("off"));
    try std.testing.expectEqual(@as(?Mode, .visual), parseMode("VISUAL"));
    try std.testing.expectEqual(@as(?Mode, .both), parseMode("both"));
    try std.testing.expectEqual(@as(?Mode, null), parseMode("nope"));
}

test "ring is a no-op when mode=off" {
    var m: Manager = .{ .cfg = .{ .mode = .off }, .allocator = std.testing.allocator };
    m.ring();
    try std.testing.expect(!m.isVisualActive());
    try std.testing.expectEqual(@as(?c_int, null), m.visualTimeoutMs());
}

test "visual ring sets a deadline" {
    var m: Manager = .{ .cfg = .{ .mode = .visual, .visual_duration_ms = 1000 }, .allocator = std.testing.allocator };
    m.ring();
    try std.testing.expect(m.isVisualActive());
    const t = m.visualTimeoutMs() orelse return error.TestExpectedTimeout;
    try std.testing.expect(t > 0);
}
