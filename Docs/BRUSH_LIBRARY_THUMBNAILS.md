# Brush library: real stroke thumbnails — 2026-09-05

## Diagnosis and reuse decision

`RightInspectorView.brushStrokePreview` drew only 3–7 copies of a primary-tip
image in SwiftUI Canvas. It duplicated some pressure calculations, clamped
visible opacity, and never ran the compound/Overlay or V2 flow renderer.
Consequently, a composite crayon could look like a solid round brush.

Replace that demonstration renderer, not the brush engine. Reuse
`StageOneBrushRenderer`, its stroke sessions and pen-up flush, the existing
offscreen texture/image conversion and NSCache in
`StageOneBrushPreviewRasterizer`, and the async thumbnail view pattern already
used by texture-fill resources. No document or library schema changes.

Apple's [NSCache documentation](https://developer.apple.com/documentation/foundation/nscache)
was consulted: this is disposable derived data, with bounded memory and
cross-thread cache access. A serial Foundation DispatchQueue runs generation
off the UI thread. No new dependencies or custom cache infrastructure.

## Changes

- `Rendering/Canvas/BrushLibraryPreviewRecipe.swift`: one deterministic curved
  gesture, pressure 95% → 18%, fixed seed. Fit the visible tip diameter to a
  256 px tile, including proportionally scaling absolute-sized compound tips.
  Preserve opacity, spacing, flow, pressure curves, source masks and engine mode.
- `Rendering/Canvas/StageOneBrushPreviewRasterizer.swift`: paint the gesture
  with the same Metal engine/session as the canvas, including pen-up. Cache by
  the complete serialized brush plus thumbnail recipe version and resolution;
  changing B's mask/curve, V2 mode or flow cannot reuse a primary-only cache key.
- `Platform/macOS/UI/BrushLibraryStrokeThumbnail.swift`: generate in the
  background; discard stale UI results after cancellation. Failed rendering
  shows a warning glyph instead of inventing a round-brush result.
- `Platform/macOS/UI/RightInspectorView.swift`: replace the manual stamp loop
  and remove its duplicate pressure calculations. Enlarge the upper-left
  preview allocation from 56% to 80% of a cell. Keep the lower-right tip glyph,
  tags, shortcut numbers, selection and drag behavior.
- `Tests/ArtFlexTests/BrushLibraryThumbnailTests.swift`: engine parity,
  normalization, cache invalidation, honest opacity, spacing, bounds and optional
  real-library integration. Remove the old test that required 3–7 fake stamps.
- `Platform/macOS/Distribution/Info.plist`: build `20260905.3`.

## Validation

Focused tests pass: 5 new thumbnail tests. The actual current library's 23
presets rendered in approximately 0.4 seconds on this machine during the
background integration run. This is a local batch measurement, not a universal
startup-time guarantee. Integration reads the archive and checks it is unchanged.

Logs: `/tmp/artflex-library-thumbnail-tests.log`,
`/tmp/artflex-library-thumbnail-release.log`.

Final related regression selection (`Brush|PressureInput|ProjectPersistence|PersistenceSave|ColorStandard|Curve`):
221 tests in 30 suites passed. Both `ARTFLEX_THUMBNAIL_LIBRARY` and
`ARTFLEX_KRITA_REFERENCE` were set to the actual local resources. Log:
`/tmp/artflex-library-thumbnail-regression.log`. This is not the entire test suite.

Release build completed and the installed app passed code-signature verification.
Installed executable UUID: `6F002005-486E-34E5-B476-ACEADC7DC276`.

Computer Use checks on the installed app:

- The first rows distinguish dense, soft-edged and masking-crayon strokes; the
  latter shows its grain transition instead of the former solid primary-only bar.
- Scrolled through the middle and bottom of the library, then filtered for
  `Krita` and cleared the filter. Images remained present and the original grid
  and lower-right glyphs were retained. Left the filter empty, at the first row.
- Reopened the saved current artwork and verified all three red test strokes.
  No new marks were made on it during this thumbnail task.
- Compared the installed-run library against the pre-update backup: all 23
  presets, their order and the embedded tip assets were identical.

## Boundaries and safety

The thumbnail is white ink at normalized size on a transparent background; it
does not represent the currently selected color or actual physical brush size.
One gesture cannot demonstrate every angle, speed, repeated-stroke interaction
or tiny grain at this small display size. Low-opacity presets stay faint rather
than receiving a misleading brightness boost. Saved presets are shown, not
temporary unsaved tool edits. Press Update or save a new preset to refresh its
library thumbnail.

No brushes are migrated, deleted, reordered or overwritten. Current library
and both the previous/current saved artwork were backed up in
`/Users/victorcloux/Downloads/ArtFlex-笔刷缩略图前备份-zXpNex` before app replacement.
Branch `codex/library-stroke-thumbnails`, based on `226140e`.
