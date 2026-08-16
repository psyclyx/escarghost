//! Host PNG decoder wired into snail's color-bitmap path.
//!
//! snail 0.18 surfaces embedded emoji strikes (`Font.colorBitmap`) as *encoded*
//! bytes plus an em-space placement box — it never decodes them, so the library
//! links no codec. Decoding is a host service: this module implements
//! `snail.font.ImageDecoder` over libspng, turning the strike's PNG bytes into
//! straight-alpha sRGBA8 texels as a `snail.Image` that the atlas samples
//! through the ordinary image-paint path.
//!
//! `SPNG_FMT_RGBA8` yields exactly the texel format snail-raster expects
//! (4 bytes/texel sRGBA, straight alpha, decoded to linear per tap) and the GPU
//! backend uploads into an sRGB texture — so no color conversion happens here.
//! Emoji decode is rare (once per unique glyph+ppem, then cached in the atlas),
//! so we favour a small, safe codec over raw throughput.

const std = @import("std");
const snail = @import("snail");

const c = @cImport({
    @cInclude("spng.h");
});

const DecodeError = snail.font.color_bitmap.DecodeError;

/// A stateless decoder: libspng builds a fresh context per call, so the
/// `ImageDecoder.context` carries nothing. One shared value serves the whole
/// process.
pub const decoder: snail.font.ImageDecoder = .{
    .context = @constCast(&stateless),
    .decode = decode,
};

var stateless: u8 = 0;

fn decode(
    _: *anyopaque,
    format: snail.font.BitmapFormat,
    bytes: []const u8,
    allocator: std.mem.Allocator,
) DecodeError!snail.Image {
    // snail only surfaces PNG strikes today; anything else is a caller/library
    // contract break rather than malformed data.
    switch (format) {
        .png => {},
    }

    const ctx = c.spng_ctx_new(0) orelse return error.DecodeFailed;
    defer c.spng_ctx_free(ctx);

    if (c.spng_set_png_buffer(ctx, bytes.ptr, bytes.len) != c.SPNG_OK) return error.DecodeFailed;

    var ihdr: c.spng_ihdr = undefined;
    if (c.spng_get_ihdr(ctx, &ihdr) != c.SPNG_OK) return error.DecodeFailed;

    var out_len: usize = 0;
    if (c.spng_decoded_image_size(ctx, c.SPNG_FMT_RGBA8, &out_len) != c.SPNG_OK) return error.DecodeFailed;
    if (out_len == 0) return error.DecodeFailed;

    // Decode straight into a scratch buffer, then hand it to `Image.init`
    // (which copies). The scratch is freed on return; the Image owns its copy.
    const buf = allocator.alloc(u8, out_len) catch return error.OutOfMemory;
    defer allocator.free(buf);

    // SPNG_DECODE_TRNS applies a tRNS chunk as alpha for formats that carry
    // transparency separately; harmless when absent.
    if (c.spng_decode_image(ctx, buf.ptr, out_len, c.SPNG_FMT_RGBA8, c.SPNG_DECODE_TRNS) != c.SPNG_OK)
        return error.DecodeFailed;

    return snail.Image.init(allocator, ihdr.width, ihdr.height, buf) catch return error.DecodeFailed;
}
