//! Bell (BEL, 0x07) handler.
//!
//! Modes (set via config):
//!   off     — drop silently
//!   visual  — invert the grey ramp for `visual_duration_ms` (default)
//!   audible — synthesize and play a short tone via libpulse-simple
//!   both    — visual and audible together
//!
//! Both paths are debounced/coalesced so a process spamming `\a` doesn't
//! turn into a strobe + audio stream. The visual deadline always tracks
//! the latest ring (so the flash duration stays the *configured* time
//! even under spam); the audible path is rate-limited to one shot per
//! `audible_debounce_ms`.
//!
//! Audio is owned by a worker thread that holds a long-lived
//! pa_simple stream to the PulseAudio (or PipeWire-compatible) server.
//! The PTY-drain thread pushes a token through a pipe; the worker
//! wakes, writes a pre-rendered sine burst to the stream, and parks.
//! If the connection fails (no server, no compatibility layer) the
//! worker just drops rings — the bell is silent, never a crash.

const std = @import("std");

const c = @cImport({
    // Disable glibc fortify: bits/fcntl2.h's variadic open/openat wrappers
    // don't survive Zig 0.16 translate-c under ReleaseSafe. Must precede any
    // header that pulls in <features.h> (which latches __USE_FORTIFY_LEVEL).
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cInclude("stdlib.h");
    @cInclude("fcntl.h");
    @cInclude("string.h");
    @cInclude("errno.h");
    @cInclude("math.h");
    @cInclude("time.h");
    @cInclude("pulse/simple.h");
    @cInclude("pulse/error.h");
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

// ── Synthesized waveform ──
//
// A gentle two-tone descending chime — G5 (~784 Hz) into E5 (~659 Hz),
// each ~110 ms with a soft exponential decay so the tail fades rather
// than cutting off. Low amplitude to avoid startling. Rendered once at
// startup into `pcm` so each ring is just a pa_simple_write.

const sample_rate: u32 = 44100;
const sample_count: usize = (@as(usize, sample_rate) * 260) / 1000; // ~260 ms total

pub const Manager = struct {
    cfg: Config = .{},
    io: std.Io = undefined,

    /// Set to monotonic-ns deadline when a visual bell is in progress.
    /// Zero when no visual is active. Updated on every ring() so back-
    /// to-back rings keep the flash visible. Atomic: ring() runs on the
    /// PTY reader thread while the main loop reads it and clears it on
    /// expiry.
    visual_until_ns: std.atomic.Value(u64) = .init(0),

    /// Anti-spam gate for the audible path. ring() refuses to enqueue a
    /// fresh tone until this deadline has passed.
    next_audible_allowed_ns: u64 = 0,

    /// Worker thread + pipe used to fire-and-forget the audio process
    /// off the hot PTY drain path. Null members when audible mode is
    /// disabled.
    audio_thread: ?std.Thread = null,
    pipe_fds: [2]c_int = .{ -1, -1 },

    /// Pre-rendered 16-bit signed PCM of the bell tone. Owned by the
    /// manager; lives for the life of the process when audio is on.
    pcm: []i16 = &.{},
    allocator: std.mem.Allocator = undefined,
    stop_requested: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, cfg: Config) !Manager {
        var self: Manager = .{ .cfg = cfg, .allocator = allocator, .io = io };
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
                const file = std.Io.File{ .handle = self.pipe_fds[1], .flags = .{ .nonblocking = false } };
                file.writeStreamingAll(self.io, &.{byte}) catch {};
            }
            self.audio_thread.?.join();
            self.audio_thread = null;
        }
        if (self.pipe_fds[0] >= 0) _ = std.c.close(self.pipe_fds[0]);
        if (self.pipe_fds[1] >= 0) _ = std.c.close(self.pipe_fds[1]);
        self.pipe_fds = .{ -1, -1 };
        if (self.pcm.len != 0) {
            self.allocator.free(self.pcm);
            self.pcm = &.{};
        }
    }

    /// Invoked from the terminal's bell callback. Safe to call from any
    /// thread; both paths are non-blocking.
    pub fn ring(self: *Manager) void {
        if (self.cfg.mode == .off) return;
        const now = nowNs();

        if (self.cfg.mode == .visual or self.cfg.mode == .both) {
            self.visual_until_ns.store(now + @as(u64, self.cfg.visual_duration_ms) * std.time.ns_per_ms, .release);
        }

        if (self.cfg.mode == .audible or self.cfg.mode == .both) {
            if (now >= self.next_audible_allowed_ns and self.pipe_fds[1] >= 0) {
                const token: u8 = 1;
                // EAGAIN on a full pipe → drop this beep (already
                // queued plenty). Otherwise count it as fired.
                const file = std.Io.File{ .handle = self.pipe_fds[1], .flags = .{ .nonblocking = true } };
                const n = file.writeStreaming(self.io, &.{}, &.{&.{token}}, 1) catch 0;
                if (n >= 1) {
                    self.next_audible_allowed_ns = now + @as(u64, self.cfg.audible_debounce_ms) * std.time.ns_per_ms;
                }
            }
        }
    }

    /// True if the renderer should display an inverted snapshot this
    /// frame. False once the deadline elapses.
    pub fn isVisualActive(self: *const Manager) bool {
        const until = self.visual_until_ns.load(.acquire);
        if (until == 0) return false;
        return nowNs() < until;
    }

    /// Linear-fade opacity for the visual flash, in [0, 1]. Returns 0
    /// when the bell isn't active so renderers can skip the overlay
    /// pass entirely.
    pub fn visualAlpha(self: *const Manager) f32 {
        const until = self.visual_until_ns.load(.acquire);
        if (until == 0) return 0;
        const now = nowNs();
        if (now >= until) return 0;
        const remaining_ns = until - now;
        const total_ns: u64 = @as(u64, self.cfg.visual_duration_ms) * std.time.ns_per_ms;
        if (total_ns == 0) return 0;
        const f = @as(f32, @floatFromInt(remaining_ns)) / @as(f32, @floatFromInt(total_ns));
        return @max(0.0, @min(1.0, f));
    }

    /// Poll-timeout hint while the bell fade is in flight. We need to
    /// wake at frame rate so the alpha steps actually paint, then once
    /// more to drop the trailing tinted frame. Cap at ~16 ms so we
    /// don't sleep past a vsync mid-fade. Returns null when no bell
    /// is active.
    pub fn visualTimeoutMs(self: *const Manager) ?c_int {
        const until = self.visual_until_ns.load(.acquire);
        if (until == 0) return null;
        const now = nowNs();
        if (now >= until) return 0;
        const remaining_ms = (until - now) / std.time.ns_per_ms + 1;
        const frame_ms: u64 = 16;
        return @intCast(@min(remaining_ms, frame_ms));
    }

    /// Clears the visual deadline once consumed. Called after the
    /// renderer has committed a non-bell frame on the trailing edge.
    pub fn clearVisualIfExpired(self: *Manager) void {
        const until = self.visual_until_ns.load(.acquire);
        if (until == 0) return;
        if (nowNs() >= until) {
            // CAS so a concurrent re-ring's fresh deadline survives.
            _ = self.visual_until_ns.cmpxchgStrong(until, 0, .acq_rel, .acquire);
        }
    }

    fn startAudio(self: *Manager) !void {
        const fds = std.Io.Threaded.pipe2(.{ .CLOEXEC = true }) catch return error.PipeFailed;
        // Non-blocking write so `ring()` can never stall on a full pipe.
        const flags = c.fcntl(fds[1], c.F_GETFL, @as(c_int, 0));
        _ = c.fcntl(fds[1], c.F_SETFL, flags | c.O_NONBLOCK);
        self.pipe_fds = fds;

        self.pcm = try renderBellPcm(self.allocator);
        errdefer self.allocator.free(self.pcm);

        self.audio_thread = try std.Thread.spawn(.{}, audioMain, .{self});
    }

    fn audioMain(self: *Manager) void {
        // Open the PulseAudio connection lazily so we don't pay the
        // setup cost (or, when no server is running, the connect-fail
        // delay) on startup. Reopen on each batch of rings if the
        // previous attempt failed — recovery comes for free when the
        // user starts a server mid-session.
        var stream: ?*c.pa_simple = null;
        defer if (stream) |s| c.pa_simple_free(s);

        while (!self.stop_requested.load(.acquire)) {
            var byte: u8 = 0;
            const file = std.Io.File{ .handle = self.pipe_fds[0], .flags = .{ .nonblocking = false } };
            const n = file.readStreaming(self.io, &.{std.mem.asBytes(&byte)}) catch {
                if (self.stop_requested.load(.acquire)) return;
                continue;
            };
            if (n == 0) {
                if (self.stop_requested.load(.acquire)) return;
                continue;
            }
            if (byte == 0) return; // shutdown sentinel

            if (stream == null) stream = openPulseStream();
            const s = stream orelse continue; // server unavailable; drop ring
            const bytes = std.mem.sliceAsBytes(self.pcm);
            var err: c_int = 0;
            if (c.pa_simple_write(s, bytes.ptr, bytes.len, &err) < 0) {
                // Connection went bad; tear it down and let the next
                // ring re-open.
                c.pa_simple_free(s);
                stream = null;
                continue;
            }
            _ = c.pa_simple_drain(s, &err);
        }
    }
};

fn openPulseStream() ?*c.pa_simple {
    var spec: c.pa_sample_spec = .{
        .format = c.PA_SAMPLE_S16NE,
        .rate = sample_rate,
        .channels = 1,
    };
    var err: c_int = 0;
    return c.pa_simple_new(
        null, // default server
        "scrgo", // application name
        c.PA_STREAM_PLAYBACK,
        null, // default device
        "bell", // stream description
        &spec,
        null, // default channel map (mono)
        null, // default buffer attrs
        &err,
    );
}

fn renderBellPcm(allocator: std.mem.Allocator) ![]i16 {
    const samples = try allocator.alloc(i16, sample_count);
    errdefer allocator.free(samples);

    // Two-tone descending chime, each tone with an exponential decay
    // (mimics a struck bar / xylophone tine — much gentler than the
    // square-edged sine burst it replaces). The faint 3rd harmonic
    // softens the timbre away from a "pure" PC-speaker sound without
    // adding harshness. Amplitudes chosen to peak well below clipping
    // and avoid feeling abrupt.
    const tone_a_hz: f32 = 783.99; // G5
    const tone_b_hz: f32 = 659.25; // E5
    const tone_samples: usize = (@as(usize, sample_rate) * 120) / 1000;
    const decay_tau: f32 = 0.08; // seconds
    const peak_amplitude: f32 = 0.18;

    var i: usize = 0;
    while (i < sample_count) : (i += 1) {
        const in_b = i >= tone_samples;
        const local_i: usize = if (in_b) i - tone_samples else i;
        const local_t = @as(f32, @floatFromInt(local_i)) / @as(f32, @floatFromInt(sample_rate));
        const freq: f32 = if (in_b) tone_b_hz else tone_a_hz;

        // 14 ms raised-cosine attack so the strike eases in rather than
        // popping. Long enough to feel deliberate, short enough that
        // the chime still sounds prompt.
        const attack_samples: f32 = @floatFromInt((@as(usize, sample_rate) * 14) / 1000);
        const attack_env: f32 = if (@as(f32, @floatFromInt(local_i)) < attack_samples)
            0.5 - 0.5 * std.math.cos(std.math.pi * @as(f32, @floatFromInt(local_i)) / attack_samples)
        else
            1.0;
        const decay_env: f32 = std.math.exp(-local_t / decay_tau);
        const env = attack_env * decay_env;

        const sample_f: f32 = peak_amplitude * env *
            (std.math.sin(2.0 * std.math.pi * freq * local_t) +
                0.15 * std.math.sin(2.0 * std.math.pi * 3.0 * freq * local_t));
        const clamped = std.math.clamp(sample_f, -1.0, 1.0);
        samples[i] = @intFromFloat(clamped * 32767.0);
    }
    return samples;
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
