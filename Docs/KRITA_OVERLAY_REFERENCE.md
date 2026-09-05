# Krita Overlay masked brush — 2026-09-05

## Evidence and decision

The previous V2 procedural crayon was not an adequate reference match. Its functional tests did not establish visual similarity. This change adds a distinct, opt-in masked-brush operation; it does not reinterpret saved pressure-blend or stamp-mask presets.

Inspected Krita 5.3.3's active **06-01-蜡笔**, the editor's main and masking tip, opacity, flow, rotation and paint-mode pages, and the matching local KPP in `Odzuki - Odzuki 3.2.bundle_modified/paintoppresets/b) Odzuki-塑造-炭笔刻画.0003.kpp`. The document was already modified. Principal editor settings agreed with the saved preset, except current size was 154 px rather than the saved 33 px; this is not a claim that every unsaved option was identical.

| Setting | Main tip | Masking tip |
| --- | --- | --- |
| Embedded image | Odzuki-Oil Pastel Large 1_1.png, 36 × 25 | Odzuki-Chalk 60 pixels 3_2.png, 90 × 90 |
| Spacing | 6% | 75% |
| Relative size | 1 | 1.545454545 |
| Opacity pressure | Linear (0,0) → (1,1) | (0,0.492462) → (0.253695,1), then plateau |
| Flow | 100%, no pressure | 100%, no pressure |
| Size pressure | Off | Off |
| Rotation | Fixed; direction following off | Fuzzy + pressure |

Combination: **Overlay**. Painting mode: **Wash**. No enabled canvas-tiled texture. Having a stored size curve does not mean size pressure is enabled. The older legacy `makePressureGrainCrayon` preset is not a faithful import of this active preset.

Exact sources consulted:

- [Krita masked brush manual](https://docs.krita.org/en/reference_manual/brushes/brush_settings/masked_brush.html)
- [Mask composite operations](https://github.com/KDE/krita/blob/c4917d3481c5fe24a37ec803604d2f9d4a557b0e/libs/ui/tool/strokes/KisMaskingBrushCompositeOp.h)
- [Mask operation factory](https://github.com/KDE/krita/blob/c4917d3481c5fe24a37ec803604d2f9d4a557b0e/libs/ui/tool/strokes/KisMaskingBrushCompositeOpFactory.cpp)
- [Mask renderer](https://github.com/KDE/krita/blob/c4917d3481c5fe24a37ec803604d2f9d4a557b0e/libs/ui/tool/strokes/KisMaskingBrushRenderer.cpp)
- [Alpha darken accumulation](https://github.com/KDE/krita/blob/c4917d3481c5fe24a37ec803604d2f9d4a557b0e/libs/pigment/compositeops/KoCompositeOpAlphaDarken.h)
- [Creamy opacity parameters](https://github.com/KDE/krita/blob/c4917d3481c5fe24a37ec803604d2f9d4a557b0e/libs/pigment/compositeops/KoAlphaDarkenParamsWrapper.h)
- [Dab rendering queue](https://github.com/KDE/krita/blob/c4917d3481c5fe24a37ec803604d2f9d4a557b0e/plugins/paintops/defaultpaintops/brush/KisDabRenderingQueue.cpp)
- [Apple NSView clipsToBounds](https://developer.apple.com/documentation/appkit/nsview/clipstobounds), consulted after the visible curve editor painted over adjacent controls. On macOS 14 and later the default is false.

These source references are a pinned upstream master revision, not a verified 5.3.3 source tag.

## Implementation

Reuse existing arc-length dab streams, Metal stroke surfaces, preview, document/undo, material picker and AppKit curve editor. Foundation XML, ImageIO and system zlib handle bounded KPP metadata/image decoding; no dependency added. There is no native Apple two-tip painting API. A small Metal compute operation is appropriate here; porting Krita's CPU paint-device architecture would violate the project's rendering contract.

Each tip accumulates separately using pressure-defined wash opacity and flow. The opacity running average rises immediately and decays by 10% per dab. Lowering pressure does not erase existing deposited paint. Intermediate values are persisted at RG16F precision after every dab, making event batching deterministic.

For accumulated coverages A and B:

```
A <= 0.5: 2 * A * B
A >  0.5: 1 - 2 * (1 - A) * (1 - B)
```

An opaque A remains opaque even in holes of B. A faint A exposes B's stamped structure. This is not a weighted A/B crossfade. Main color is composed using the existing linear, premultiplied BGRA8 sRGB contract; no compensating global gamma change was introduced.

The importer accepts only the explicitly supported pixel/Wash/Overlay combination with embedded PNG mask tips, constant flow and two-point pressure opacity curves. It rejects unsupported enabled modules instead of replacing missing resources with circles. It preserves curve endpoints such as x=0.253695 and reads enable flags. Actual resource bytes remain in the user's saved preset, not application/repository assets.

The editor exposes main and mask concentration curves, draggable handles and numeric node controls. Endpoint hit-testing includes the part of the handle outside the graph border. A complete drag is one undoable edit. The native curve view clips to its bounds rather than filling an expanded dirty rectangle over sibling controls. Generated preview paths reserve space for endpoint dabs when brush size changes; freehand coordinates remain unchanged. The previous procedural starter is labelled as a legacy random-grain example.

## Validation and boundaries

- 217 related tests in 29 suites passed on the final code, including the actual local reference KPP, Metal pipeline compilation, heavy coverage, light grain, reduced-pressure overlap, exact incremental/batch equality, JSON round-trip, malformed/unsupported import rejection, colors, persistence, curve clipping and editing callbacks.
- Final test log: `/tmp/artflex-overlay-verified-tests.log`. Filter: `Brush|PressureInput|ProjectPersistence|PersistenceSave|ColorStandard|Curve`. This was a related regression selection, not the entire repository test suite.
- Actual-reference integration tests require `ARTFLEX_KRITA_REFERENCE` pointing to the user's KPP. That path was set during this run; no proprietary tip fixtures are committed.
- Random sequences, image interpolation, rotation-sensor approximation and linear versus Krita's document compositing can still differ. This is not a general KPP importer or a pixel-identical Krita implementation.
- Computer Use mouse testing cannot certify physical tablet pressure or driver behavior.
- Long strokes and very large brushes need additional performance profiling. Compute dispatch is bounded to touched stamp batches; the established full-size stroke surfaces remain.

### Visible Computer Use checks

- Imported the actual local KPP through the editor's file picker, then saved a new preset named **06-01 蜡笔 · Krita叠加蒙版**. Original presets were not replaced. Restarted the final installed app and selected this preset from the library again.
- Painted two red 154 px strokes on an independent main-canvas test document: main concentration 100% produced a solid interior; 50% showed irregular stamped grain. Verified canvas undo/redo, saved, restarted and reopened the document; both strokes remained. The lower stroke uses a temporarily adjusted opacity setting, not physical stylus pressure.
- Saved test document: `/Users/victorcloux/Downloads/ArtFlex-叠加蒙版-屏幕对照-20260905.artflex`.
- On the final build, dragged the main curve endpoint from (100%,100%) to (80%,79%). One Undo restored (100%,100%); Redo restored (80%,79%); then undid the experiment. Dragged the masking endpoint from (25%,100%) to (42%,81%), then undid it successfully.
- In the visible scratchpad, changed brush size from 154 to 60 px; the generated pressure ramp showed faint texture progressing to filled color. Drew three downward mouse strokes at approximately 22%, 50% and 85% simulated pressure. They stayed at the pointer's coordinates and showed increasing coverage with distinct middle-pressure grain. Cancelled this editor experiment, preserving the saved 154 px preset.
- Inspected Krita's editor and scratchpad without painting on the user's document. A full-pressure scratchpad stroke painted solid; the attempted half-opacity scratchpad comparison did not produce a reliable full line, so no controlled Krita 50% comparison is claimed. Restored Krita's main opacity value to 100% and did not save its preset.

## Safety

Branch: `codex/krita-overlay-brush`, based on `8956c26`. Revert the resulting change commit to roll back code; do not reset the whole repository or overwrite the user's library. Earlier binaries do not understand the new enum case, so do not use them to rewrite a library containing new Overlay presets.

Before restarting, preserved the brush library, the previous saved artwork, and the latest saved artwork in `/Users/victorcloux/Downloads/ArtFlex-Overlay前备份-rwp5Bj`. The user's current named artwork remains at `/Users/victorcloux/Downloads/ArtFlex-笔刷重建前画稿-20260905.artflex`. Krita's artwork and original preset were not changed.

After validation, reopened the original ArtFlex artwork and selected the newly saved brush without painting on that artwork. A byte comparison against the latest-artwork backup found only three changed bytes inside the `savedAt` timestamp; all image and brush payload bytes were unchanged.

Build identifier: `20260905.2`; visible editor title: `笔刷工作室 · 0905.2`. Release and installed executable UUID: `9DCF9DC1-1D88-3F9D-9E80-D8AE978E22BB`. Installed bundle: `.build/ArtFlex.app`. Release build log: `/tmp/artflex-overlay-verified-release.log`.
