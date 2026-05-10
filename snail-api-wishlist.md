# Snail API wishlist for mollusk's two-pass rendering

## Problem

Mollusk renders terminal frames on a GPU thread. The atlas may not have all
needed glyphs on the first pass (new characters, ligature glyphs). Currently
the frame is discarded and re-rendered from scratch after atlas extension.

We want: render what we have, extend the atlas, fill in the gaps, present.
Never show an incomplete frame.

## What we need

### 1. `TextBatch.addText` should report what it couldn't render

Currently `addText` silently skips missing glyphs. We detect misses by
comparing `glyphCount()` before/after, but that's coarse — we can't tell
*which* glyphs are missing, or re-emit just the gaps.

**Ideal:** `addText` returns a struct with:
- `advance`: f32 (already returned)
- `complete`: bool — true if all shaped glyphs were in the atlas
- (optional) `missing_glyph_ids`: a small bounded slice of glyph IDs that
  were skipped, so the caller can extend the atlas precisely

Or: a variant like `addTextPartial` that emits what it can and returns an
opaque "continuation" token. After atlas extension + re-upload, calling
`continueText(token)` emits just the previously-missing glyphs into the
same batch at the correct positions.

### 2. Incremental atlas re-upload

After `atlas.extendText(text)` produces a new atlas, `renderer.uploadAtlas()`
currently re-uploads the entire texture array. For a two-pass frame, we're
extending mid-frame and only need the new pages.

**Ideal:** `renderer.uploadAtlas()` is smart enough to only upload new/changed
pages (or there's an `uploadAtlasIncremental` that takes old + new atlas and
diffs). This matters because the re-upload happens between pass 1 and pass 2
within the same frame.

### 3. `atlas.extendText` is the right primitive

This already exists and does exactly what we need — takes UTF-8 text, uses
HarfBuzz to discover all required glyph IDs (including ligatures), and
returns a new atlas. No changes needed here.

## Proposed rendering flow

```
// Pass 1: draw everything we can
clear framebuffer
draw rects (backgrounds, cursor, decorations)
for each text run:
    result = batch.addText(atlas_handle, font, text, ...)
    if !result.complete:
        missed_runs.append({text, x, y, color})

draw text batch → GPU

if missed_runs.empty:
    present  // fast path, no misses
    return

// Atlas extension (inline on GPU thread)
new_atlas = atlas.extendText(missed_text)
publish new atlas
re-upload atlas → GPU

// Pass 2: fill in the gaps
for each missed run:
    batch2.addText(new_atlas_handle, font, text, ...)
draw batch2 → GPU  // blends on top of pass 1

present  // complete frame
```

## Minimal viable version (no snail changes)

Without API changes, we can approximate this:
1. Build all vertices, draw backgrounds + text (pass 1)
2. If misses detected (glyphCount didn't increase for some runs):
   - Extend atlas inline: `atlas.extendText(misses.text())`
   - Re-upload atlas
   - Rebuild ALL text vertices from scratch (re-shape everything)
   - Draw text again (overwrites pass 1 text — that's fine)
3. Present

This wastes the pass-1 text vertex build but avoids presenting incomplete
frames. The double-shape cost only happens on frames with new glyphs.
