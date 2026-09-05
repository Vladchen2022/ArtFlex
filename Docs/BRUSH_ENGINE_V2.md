# Brush Engine V2 — 2026-09-05

## Decision and references

Replace the legacy brush coverage/composition semantics behind a versioned opt-in record. Reuse the document/undo engine, arc-length sampler, pigment shader, material library, editor history and persistence. New coverage fields and the interactive preview are Metal-first; no additional dependencies.

The following official references informed behavior, not a claim of pixel-identical emulation:

- Krita opacity vs flow: https://docs.krita.org/en/reference_manual/brushes/brush_settings/opacity_and_flow.html
- Krita masked brush: https://docs.krita.org/en/reference_manual/brushes/brush_settings/masked_brush.html
- Photoshop painting tools: https://helpx.adobe.com/photoshop/using/painting-tools.html

Krita's masked brush is a mask operation; it is not automatically the same as two independently painting tips. V2 exposes those as two distinct methods. Its starter crayon is an original demonstration, not an imported or exact Krita preset.

## Contract

- No `engineV2` in a saved preset means legacy rendering. Loading does not convert it.
- Explicitly rebuild a draft, or choose a V2 starter. Save as a new preset to preserve the source.
- Flow controls paint deposited per dab. Opacity caps the current stroke once at final composition. Lifting the pen starts a fresh stroke that can deepen existing paint.
- A and B have independent arc-length dab streams, spacing, size, rotation, scatter, flow and pressure contribution.
- Each stream stores RG16F: R is deposited coverage, G is contribution-weighted coverage. Both accumulate using unweighted source deposit. Pressure mixing does not suppress the rate at which a tip builds to its intended contribution.
- Dual mode uses `min(A.G + B.G, 1)`. Complementary identical tips therefore do not become faint at the midpoint.
- Stamp-mask mode uses `A.G + (A.R - A.G) * B.G`. Heavy pressure can recover A; the other part is shaped by actual B dabs.
- Optional third range stream clips the result, and never deposits color.
- Imported grayscale has neutral contrast at 1. Edge softening does not exponentiate every source pixel.
- Variants are chosen deterministically per dab, excluding the immediately previous frame. No canvas-locked tile lattice.
- Default input calibration maps raw 0.75 to normal heavy pressure. It is user adjustable; no claim of calibration to an individual tablet.
- Default opacity pressure and flow pressure are off, so grain can change with pressure without unintentionally fading the entire stroke.
- Main and editor use the same Metal renderer and color/pigment contract. Interactive preview flushes its existing stroke; it does not replace it with a different CPU render on pen-up.
- White is the preview default. Parameter changes deliberately replay the preview. A/B channel views isolate the selected tip rather than the final composite.
- Main-interface spacing and size-random controls edit A when a V2 combination is enabled. Other shared pressure/color controls remain the same brush data.

## UI

`笔刷工作室 · V2`: 整体 / 笔尖 A / 笔尖 B / 压力 / 范围.

Pressure contribution uses six labelled numeric sliders, replacing the difficult three-handle interaction in the main workflow. Each tip can select a material and add random variants. The existing bounded material picker is reused. The left preview stays visible and has a size control, mouse pressure simulator, live pen-input indicator, clear, stable seed and test strokes.

## Validation

`BrushEngineV2Tests` covers full color at light pressure, no midpoint density dip, exact source grayscale, within-stroke flow, per-stroke opacity and lifted-stroke accumulation, real A/B contribution, mask behavior, range clipping, outside-canvas start, selection, alpha-lock premultiplication, pigment variation, quick-control consistency, archive round-trip, and byte-exact incremental vs batch rendering with varying pressure and random variants.

Related suites: BrushLibraryStateTests, CompoundBrushEditingTests, PressureInputTests, BrushInputDispatchTests, ProjectPersistenceIntegrationTests.

Final related regression run: 81 tests in 6 suites passed. Log: `/tmp/artflex-v2-complete-regressions.log`.

Computer Use validation performed against the installed Release build:

- Pressure ramp visibly transitions from grain to opaque paint; both combination methods selectable.
- A midpoint contribution edited numerically to 80%, then physically dragged to 43%, with preview update; restored afterwards.
- Preview size changed from 60 to 90 px; freehand top-left to bottom-right coordinates correct; a second lifted stroke deepens the first.
- B material library bounded to 820 × 600 within the editor; thumbnails contained; existing material selected/applied, then undone.
- Saved new preset `V2 压感蜡笔 · 0905`, without replacing `笔刷 7`. Restarted and reselected it from the library; V2 settings preserved.
- Main-canvas normal strokes and outside-to-inside strokes draw opaque paint, including a newly created second document.
- Undo removed the second stroke; redo restored it.
- Main spacing 9% → 18% reflected inside the editor; editor 18% → 9% reflected outside.
- Saved `/Users/victorcloux/Downloads/ArtFlex-V2-屏幕验收-20260905.artflex`; reopened after restart with the same two-stroke canvas.
- Saved `/Users/victorcloux/Downloads/ArtFlex-V2-新文件验收-20260905.artflex` for the second-document check.
- Screen testing exposed the old Save As sheet defaulting to replacement. Changed the default to new; final binary verified replacement toggle off, with duplicate detection still working.
- Reopened the user's pre-change saved artwork without painting on it; selected the new V2 preset and left its pressure page visible.

Installed executable UUID matches the final Release artifact: `EC5EF09D-8272-34F7-AAC2-D6EC81B2D45B`. Bundle signature verified. Mouse testing cannot certify a physical tablet's pressure hardware or driver; real pen input is supported but was not physically exercised by Computer Use.

## Safety and rollback

- Branch: `codex/brush-engine-v2`.
- Pre-existing edits checkpoint: `3d3f989`.
- Brush-library backup: `/Users/victorcloux/Downloads/ArtFlex-笔刷库重建前-20260905.json`.
- User artwork saved before restart: `/Users/victorcloux/Downloads/ArtFlex-笔刷重建前画稿-20260905.artflex`.
- Keep the V2 implementation in its own commit; revert that commit to roll back code. Never reset the entire working tree or overwrite the user's library for rollback.
- Legacy-only executables do not understand V2 semantics. Do not update V2 presets using an old executable. Keep the library backup if downgrading.
- Installed build number: `20260905.1`; visible editor title identifies V2.

## Known boundaries

This is an independently designed brush engine, not a full Krita `.kpp`/`.gih` or Photoshop `.abr` importer. Physical stylus calibration and side-by-side human drawing judgment remain required. Very large canvases/many variants need dedicated performance profiling; the new session uses three floating-point coverage surfaces, lazily initialized by touched tiles.
