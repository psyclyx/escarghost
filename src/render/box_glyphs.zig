//! Terminal-drawn box-drawing and block-element glyphs (U+2500–259F).
//!
//! These are emitted as axis-aligned device-space rectangles (not baked atlas
//! paths) for two reasons: they are almost entirely rectangles, and their
//! stroke weight must be *device-pixel consistent* — a horizontal and a
//! vertical light line have to be the same thickness regardless of the cell's
//! aspect ratio. Computing the rects per-cell in pixel space with the live
//! cell metrics gives that for free, ties into the existing rect pipeline, and
//! stays crisp under zoom. Lines centred on the cell edges/centre tile
//! seamlessly with their neighbours.
//!
//! Coverage: light/heavy lines, corners, tees, crosses (2500–254B), the
//! dashed variants (2504–250B, 254C–254F), half-lines and light/heavy
//! transitions (2574–257F), and all blocks/shades/quadrants (2580–259F).
//! Double lines (2550–256C), rounded corners (256D–2570) and diagonals
//! (2571–2573) are left to the font for now — they need parallel-line joins /
//! arc / diagonal geometry that doesn't reduce to axis-aligned rects.
//!
//! Rects are pushed through a generic `sink` with method
//! `rect(x, y, w, h, alpha)` (alpha multiplies the glyph colour's alpha, used
//! by the shade characters); the caller supplies the colour.

const std = @import("std");

/// True for the codepoints we render ourselves. The gap 2550–2573 (double
/// lines, rounded corners, diagonals) is intentionally excluded and falls
/// through to font shaping.
pub fn isHandled(cp: u32) bool {
    return (cp >= 0x2500 and cp <= 0x254F) or
        (cp >= 0x2574 and cp <= 0x257F) or
        (cp >= 0x2580 and cp <= 0x259F);
}

// Arm weights, in order [up, down, left, right]: 0 = none, 1 = light, 2 = heavy.
const Arms = [4]u8;

/// Arm weights for the line/corner/tee/cross characters 2500–254B plus the
/// half-line and light/heavy transition characters 2574–257F. Returns null for
/// characters handled elsewhere (dashes, blocks) or not handled at all.
fn arms(cp: u32) ?Arms {
    return switch (cp) {
        // ── straight lines ──
        0x2500 => .{ 0, 0, 1, 1 }, // ─
        0x2501 => .{ 0, 0, 2, 2 }, // ━
        0x2502 => .{ 1, 1, 0, 0 }, // │
        0x2503 => .{ 2, 2, 0, 0 }, // ┃
        // ── corners (down/up + left/right) ──
        0x250C => .{ 0, 1, 0, 1 }, // ┌
        0x250D => .{ 0, 1, 0, 2 }, // ┍
        0x250E => .{ 0, 2, 0, 1 }, // ┎
        0x250F => .{ 0, 2, 0, 2 }, // ┏
        0x2510 => .{ 0, 1, 1, 0 }, // ┐
        0x2511 => .{ 0, 1, 2, 0 }, // ┑
        0x2512 => .{ 0, 2, 1, 0 }, // ┒
        0x2513 => .{ 0, 2, 2, 0 }, // ┓
        0x2514 => .{ 1, 0, 0, 1 }, // └
        0x2515 => .{ 1, 0, 0, 2 }, // ┕
        0x2516 => .{ 2, 0, 0, 1 }, // ┖
        0x2517 => .{ 2, 0, 0, 2 }, // ┗
        0x2518 => .{ 1, 0, 1, 0 }, // ┘
        0x2519 => .{ 1, 0, 2, 0 }, // ┙
        0x251A => .{ 2, 0, 1, 0 }, // ┚
        0x251B => .{ 2, 0, 2, 0 }, // ┛
        // ── vertical tees (├ family) ──
        0x251C => .{ 1, 1, 0, 1 },
        0x251D => .{ 1, 1, 0, 2 },
        0x251E => .{ 2, 1, 0, 1 },
        0x251F => .{ 1, 2, 0, 1 },
        0x2520 => .{ 2, 2, 0, 1 },
        0x2521 => .{ 2, 1, 0, 2 },
        0x2522 => .{ 1, 2, 0, 2 },
        0x2523 => .{ 2, 2, 0, 2 },
        // ── vertical tees (┤ family) ──
        0x2524 => .{ 1, 1, 1, 0 },
        0x2525 => .{ 1, 1, 2, 0 },
        0x2526 => .{ 2, 1, 1, 0 },
        0x2527 => .{ 1, 2, 1, 0 },
        0x2528 => .{ 2, 2, 1, 0 },
        0x2529 => .{ 2, 1, 2, 0 },
        0x252A => .{ 1, 2, 2, 0 },
        0x252B => .{ 2, 2, 2, 0 },
        // ── horizontal tees (┬ family) ──
        0x252C => .{ 0, 1, 1, 1 },
        0x252D => .{ 0, 1, 2, 1 },
        0x252E => .{ 0, 1, 1, 2 },
        0x252F => .{ 0, 1, 2, 2 },
        0x2530 => .{ 0, 2, 1, 1 },
        0x2531 => .{ 0, 2, 2, 1 },
        0x2532 => .{ 0, 2, 1, 2 },
        0x2533 => .{ 0, 2, 2, 2 },
        // ── horizontal tees (┴ family) ──
        0x2534 => .{ 1, 0, 1, 1 },
        0x2535 => .{ 1, 0, 2, 1 },
        0x2536 => .{ 1, 0, 1, 2 },
        0x2537 => .{ 1, 0, 2, 2 },
        0x2538 => .{ 2, 0, 1, 1 },
        0x2539 => .{ 2, 0, 2, 1 },
        0x253A => .{ 2, 0, 1, 2 },
        0x253B => .{ 2, 0, 2, 2 },
        // ── crosses (┼ family) ──
        0x253C => .{ 1, 1, 1, 1 },
        0x253D => .{ 1, 1, 2, 1 },
        0x253E => .{ 1, 1, 1, 2 },
        0x253F => .{ 1, 1, 2, 2 },
        0x2540 => .{ 2, 1, 1, 1 },
        0x2541 => .{ 1, 2, 1, 1 },
        0x2542 => .{ 2, 2, 1, 1 },
        0x2543 => .{ 2, 1, 2, 1 },
        0x2544 => .{ 2, 1, 1, 2 },
        0x2545 => .{ 1, 2, 2, 1 },
        0x2546 => .{ 1, 2, 1, 2 },
        0x2547 => .{ 2, 1, 2, 2 },
        0x2548 => .{ 1, 2, 2, 2 },
        0x2549 => .{ 2, 2, 2, 1 },
        0x254A => .{ 2, 2, 1, 2 },
        0x254B => .{ 2, 2, 2, 2 },
        // ── half lines ──
        0x2574 => .{ 0, 0, 1, 0 }, // ╴
        0x2575 => .{ 1, 0, 0, 0 }, // ╵
        0x2576 => .{ 0, 0, 0, 1 }, // ╶
        0x2577 => .{ 0, 1, 0, 0 }, // ╷
        0x2578 => .{ 0, 0, 2, 0 }, // ╸
        0x2579 => .{ 2, 0, 0, 0 }, // ╹
        0x257A => .{ 0, 0, 0, 2 }, // ╺
        0x257B => .{ 0, 2, 0, 0 }, // ╻
        // ── light/heavy transition lines ──
        0x257C => .{ 0, 0, 1, 2 }, // ╼
        0x257D => .{ 1, 2, 0, 0 }, // ╽
        0x257E => .{ 0, 0, 2, 1 }, // ╾
        0x257F => .{ 2, 1, 0, 0 }, // ╿
        else => null,
    };
}

const Dashed = struct { horizontal: bool, heavy: bool, dashes: u8 };

fn dashed(cp: u32) ?Dashed {
    return switch (cp) {
        0x2504 => .{ .horizontal = true, .heavy = false, .dashes = 3 }, // ┄
        0x2505 => .{ .horizontal = true, .heavy = true, .dashes = 3 }, // ┅
        0x2506 => .{ .horizontal = false, .heavy = false, .dashes = 3 }, // ┆
        0x2507 => .{ .horizontal = false, .heavy = true, .dashes = 3 }, // ┇
        0x2508 => .{ .horizontal = true, .heavy = false, .dashes = 4 }, // ┈
        0x2509 => .{ .horizontal = true, .heavy = true, .dashes = 4 }, // ┉
        0x250A => .{ .horizontal = false, .heavy = false, .dashes = 4 }, // ┊
        0x250B => .{ .horizontal = false, .heavy = true, .dashes = 4 }, // ┋
        0x254C => .{ .horizontal = true, .heavy = false, .dashes = 2 }, // ╌
        0x254D => .{ .horizontal = true, .heavy = true, .dashes = 2 }, // ╍
        0x254E => .{ .horizontal = false, .heavy = false, .dashes = 2 }, // ╎
        0x254F => .{ .horizontal = false, .heavy = true, .dashes = 2 }, // ╏
        else => null,
    };
}

/// Emit the rects for `cp` at cell origin (x0, y0) with size (cw, ch). No-op
/// if `cp` isn't one we draw (mirror `isHandled`).
pub fn emit(cp: u32, x0: f32, y0: f32, cw: f32, ch: f32, sink: anytype) void {
    const t_light = @max(1.0, @round(ch / 10.0));
    const t_heavy = @max(t_light + 1.0, @round(ch / 5.0));
    const thick = struct {
        fn f(w: u8, l: f32, h: f32) f32 {
            return switch (w) {
                2 => h,
                else => l,
            };
        }
    }.f;

    // Cell centre, pixel-snapped so lines land on whole pixels.
    const cx = @round(x0 + cw / 2.0);
    const cy = @round(y0 + ch / 2.0);
    const x1 = x0 + cw;
    const y1 = y0 + ch;

    if (dashed(cp)) |d| {
        const t = if (d.heavy) t_heavy else t_light;
        if (d.horizontal) {
            const y = cy - @round(t / 2.0);
            const n: f32 = @floatFromInt(d.dashes);
            const unit = cw / n;
            var i: f32 = 0;
            while (i < n) : (i += 1) {
                sink.rect(@round(x0 + i * unit), y, @round(unit * 0.7), t, 1.0);
            }
        } else {
            const x = cx - @round(t / 2.0);
            const n: f32 = @floatFromInt(d.dashes);
            const unit = ch / n;
            var i: f32 = 0;
            while (i < n) : (i += 1) {
                sink.rect(x, @round(y0 + i * unit), t, @round(unit * 0.7), 1.0);
            }
        }
        return;
    }

    if (arms(cp)) |w| {
        const tu: f32 = if (w[0] != 0) thick(w[0], t_light, t_heavy) else 0;
        const td: f32 = if (w[1] != 0) thick(w[1], t_light, t_heavy) else 0;
        const tl: f32 = if (w[2] != 0) thick(w[2], t_light, t_heavy) else 0;
        const tr: f32 = if (w[3] != 0) thick(w[3], t_light, t_heavy) else 0;

        // The rects must not overlap: overlapping path-fills cancel and leave
        // holes at the junction. So the horizontal arms run full-length
        // through the centre (bridging the vertical line), and the vertical
        // arms stop at the horizontal band's edges. For a uniform-weight
        // cross this yields a solid, seam-free '+'.
        const half_h = @round(@max(tl, tr) / 2.0);

        if (tl != 0) sink.rect(x0, cy - @round(tl / 2.0), cx - x0, tl, 1.0);
        if (tr != 0) sink.rect(cx, cy - @round(tr / 2.0), x1 - cx, tr, 1.0);
        if (tu != 0) sink.rect(cx - @round(tu / 2.0), y0, tu, (cy - half_h) - y0, 1.0);
        if (td != 0) sink.rect(cx - @round(td / 2.0), cy + half_h, td, y1 - (cy + half_h), 1.0);
        return;
    }

    emitBlock(cp, x0, y0, cw, ch, sink);
}

fn emitBlock(cp: u32, x0: f32, y0: f32, cw: f32, ch: f32, sink: anytype) void {
    const x1 = x0 + cw;
    const y1 = y0 + ch;
    const xm = @round(x0 + cw / 2.0);
    const ym = @round(y0 + ch / 2.0);

    switch (cp) {
        0x2580 => sink.rect(x0, y0, cw, ym - y0, 1.0), // ▀ upper half
        0x2588 => sink.rect(x0, y0, cw, ch, 1.0), // █ full
        0x2584 => sink.rect(x0, ym, cw, y1 - ym, 1.0), // ▄ lower half
        0x258C => sink.rect(x0, y0, xm - x0, ch, 1.0), // ▌ left half
        0x2590 => sink.rect(xm, y0, x1 - xm, ch, 1.0), // ▐ right half
        0x2594 => sink.rect(x0, y0, cw, @round(ch / 8.0), 1.0), // ▔ upper 1/8
        0x2595 => { // ▕ right 1/8
            const xe = @round(x0 + cw * 7.0 / 8.0);
            sink.rect(xe, y0, x1 - xe, ch, 1.0);
        },
        // Lower eighths ▁▂▃▄▅▆▇ (1/8 .. 7/8 of the cell, from the bottom).
        0x2581, 0x2582, 0x2583, 0x2585, 0x2586, 0x2587 => {
            const eighths: f32 = @floatFromInt(cp - 0x2580);
            const yt = @round(y1 - ch * eighths / 8.0);
            sink.rect(x0, yt, cw, y1 - yt, 1.0);
        },
        // Left blocks ▉▊▋▌▍▎▏ (7/8 .. 1/8 of the cell, from the left).
        0x2589, 0x258A, 0x258B, 0x258D, 0x258E, 0x258F => {
            const eighths: f32 = @floatFromInt(0x2590 - cp);
            const xe = @round(x0 + cw * eighths / 8.0);
            sink.rect(x0, y0, xe - x0, ch, 1.0);
        },
        // Shades ░▒▓ — the fg colour at 25% / 50% / 75% over the cell.
        0x2591 => sink.rect(x0, y0, cw, ch, 0.25),
        0x2592 => sink.rect(x0, y0, cw, ch, 0.5),
        0x2593 => sink.rect(x0, y0, cw, ch, 0.75),
        // Quadrants ▖▗▘▙▚▛▜▝▞▟ — mask over [UL=1, UR=2, LL=4, LR=8].
        0x2596...0x259F => {
            const mask: u8 = switch (cp) {
                0x2596 => 4, // ▖ lower left
                0x2597 => 8, // ▗ lower right
                0x2598 => 1, // ▘ upper left
                0x2599 => 1 | 4 | 8, // ▙
                0x259A => 1 | 8, // ▚
                0x259B => 1 | 2 | 4, // ▛
                0x259C => 1 | 2 | 8, // ▜
                0x259D => 2, // ▝ upper right
                0x259E => 2 | 4, // ▞
                0x259F => 2 | 4 | 8, // ▟
                else => 0,
            };
            if (mask & 1 != 0) sink.rect(x0, y0, xm - x0, ym - y0, 1.0);
            if (mask & 2 != 0) sink.rect(xm, y0, x1 - xm, ym - y0, 1.0);
            if (mask & 4 != 0) sink.rect(x0, ym, xm - x0, y1 - ym, 1.0);
            if (mask & 8 != 0) sink.rect(xm, ym, x1 - xm, y1 - ym, 1.0);
        },
        else => {},
    }
}
