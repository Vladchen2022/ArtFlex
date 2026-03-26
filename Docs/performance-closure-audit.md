# Performance Closure Audit

Date: 2026-03-26

This document closes the current performance optimization track and defines the repository baseline for future work.

## Scope Closed

Resolved and closed in this track:

- dirty history mainline
- `brush.commit`
- `eraser.commit`
- `applyPixelOperation`
- `fillAtPoint`
- symmetric dirty `currentEntryCapture` for `undo` / `redo`
- transactional failure protection for history restore
- largest `smudge` full-size copy/allocation pitfall
- serializer / queue / staging consolidation

Deferred and intentionally not pursued in this track:

- PNG export CPU BGRA -> white-background RGBA transform
- `fillAtPoint` intrinsic algorithm / implementation cost
- deeper `smudge` optimization
- generic partial history
- `trim` / restore model changes

## Stop Line

This optimization track is closed.

Unless future feature work introduces a new P0 or P1 regression:

- do not reopen this broad performance project
- do not expand dirty history further
- do not revisit `trim` or restore semantics
- do not restart broad history / brush / serializer optimization work

If a future regression appears:

- compare against this baseline first
- do a targeted fix only
- do not return to wide-scope optimization mode without a fresh explicit decision

## Main Call Paths

### `brush.commit` / `eraser.commit`

Call path:

- `/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift`
  - `drainPendingBrushCommitsIfNeeded(resetLiveSession:)`
  - `captureBrushCommitCheckpoint(for:)`
- `/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift`
  - `captureCheckpoint(...)`
  - `undo()`
  - `redo()`
  - `currentEntryCaptureMode(for:)`
  - `restore(entry:)`
  - `restoreInPlaceChangedLayers(...)`

Key locations:

- [/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5134](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5134)
- [/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L97](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L97)
- [/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L121](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L121)
- [/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L141](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L141)
- [/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L313](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L313)

### `applyPixelOperation`

Call path:

- `/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift`
  - `fillSelectionContents()`
  - `fillLassoContents()`
  - `eraseLassoContents()`
  - `applyPixelOperation(...)`
  - `checkpointHistoryIfPossible(...)`
- `/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift`
  - `captureCheckpoint(...)`
  - `undo()`
  - `redo()`

Key locations:

- [/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5266](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5266)
- [/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5048](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5048)
- [/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L97](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L97)

### `fillAtPoint`

Call path:

- `/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift`
  - `fillAtPoint(_:)`
  - `checkpointHistoryIfPossible(...)`
- `/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift`
  - `captureCheckpoint(...)`
  - `undo()`
  - `redo()`

Key locations:

- [/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L1168](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L1168)
- [/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5048](/Users/victorcloux/Desktop/ArtFlex/Platform/macOS/App/WorkspaceViewModel.swift#L5048)
- [/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L97](/Users/victorcloux/Desktop/ArtFlex/Core/Application/HistoryController.swift#L97)

## Baseline Tables

All timings are the before/after values established by the closed pilot measurements.

### `brush.commit`

| Case | captureCheckpoint before | captureCheckpoint after | undo before | undo after | redo before | redo after | entryBytes before | entryBytes after | retained before | retained after |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 4096² / 4 layers | 227.413 ms | 59.495 ms | 268.689 ms | 67.585 ms | 258.418 ms | 61.808 ms | 268,435,456 | 67,108,864 | 2 | 8 |
| 4096² / 8 layers | 462.339 ms | 59.713 ms | 530.408 ms | 68.715 ms | 522.674 ms | 62.945 ms | 536,870,912 | 67,108,864 | 1 | 8 |
| 8192² / 4 layers | 970.821 ms | 242.517 ms | 1179.638 ms | 279.816 ms | 1173.597 ms | 283.778 ms | 1,073,741,824 | 268,435,456 | 1 | 2 |
| 8192² / 8 layers | 1965.081 ms | 245.005 ms | 2393.669 ms | 287.331 ms | 2400.897 ms | 294.341 ms | 2,147,483,648 | 268,435,456 | 1 | 2 |

### `eraser.commit`

| Case | captureCheckpoint before | captureCheckpoint after | undo before | undo after | redo before | redo after | entryBytes before | entryBytes after | retained before | retained after |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 4096² / 4 layers | 230.516 ms | 61.196 ms | 260.441 ms | 67.187 ms | 256.925 ms | 66.696 ms | 268,435,456 | 67,108,864 | 2 | 8 |
| 4096² / 8 layers | 458.728 ms | 60.195 ms | 531.318 ms | 66.241 ms | 514.530 ms | 60.368 ms | 536,870,912 | 67,108,864 | 1 | 8 |
| 8192² / 4 layers | 984.331 ms | 253.289 ms | 1166.440 ms | 286.592 ms | 1213.618 ms | 294.155 ms | 1,073,741,824 | 268,435,456 | 1 | 2 |
| 8192² / 8 layers | 1951.775 ms | 246.709 ms | 2427.180 ms | 291.710 ms | 2382.271 ms | 293.046 ms | 2,147,483,648 | 268,435,456 | 1 | 2 |

### `applyPixelOperation`

| Case | captureCheckpoint before | captureCheckpoint after | undo before | undo after | redo before | redo after | entryBytes before | entryBytes after | retained before | retained after |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 4096² / 4 layers | 496.502 ms | 305.955 ms | 313.351 ms | 73.265 ms | 332.131 ms | 73.643 ms | 268,435,456 | 67,108,864 | 2 | 8 |
| 4096² / 8 layers | 959.670 ms | 528.794 ms | 624.123 ms | 81.933 ms | 629.115 ms | 74.366 ms | 536,870,912 | 67,108,864 | 1 | 8 |
| 8192² / 4 layers | 2130.133 ms | 1331.186 ms | 1251.724 ms | 303.355 ms | 1229.668 ms | 306.618 ms | 1,073,741,824 | 268,435,456 | 1 | 2 |
| 8192² / 8 layers | 4260.337 ms | 2385.667 ms | 2506.428 ms | 345.025 ms | 2497.342 ms | 344.767 ms | 2,147,483,648 | 268,435,456 | 1 | 2 |

### `fillAtPoint`

| Case | captureCheckpoint before | captureCheckpoint after | undo before | undo after | redo before | redo after | entryBytes before | entryBytes after | retained before | retained after |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 4096² / 4 layers | 12796.628 ms | 12576.971 ms | 277.703 ms | 65.268 ms | 292.962 ms | 72.488 ms | 268,435,456 | 67,108,864 | 2 | 8 |
| 4096² / 8 layers | 13542.583 ms | 12829.137 ms | 569.558 ms | 65.296 ms | 559.462 ms | 66.963 ms | 536,870,912 | 67,108,864 | 1 | 8 |
| 8192² / 4 layers | 62833.810 ms | 62677.412 ms | 1261.345 ms | 292.034 ms | 1243.375 ms | 287.790 ms | 1,073,741,824 | 268,435,456 | 1 | 2 |
| 8192² / 8 layers | 59532.909 ms | 57475.248 ms | 2497.719 ms | 292.915 ms | 2426.741 ms | 283.340 ms | 2,147,483,648 | 268,435,456 | 1 | 2 |

## Key Tests

### History integrity and transactional safety

- [/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/HistoryControllerTests.swift#L192](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/HistoryControllerTests.swift#L192) `historySupportsUndoRedoForTwoStrokesOnSameLayer()`
- [/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/HistoryControllerTests.swift#L473](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/HistoryControllerTests.swift#L473) `eraserHistorySupportsUndoRedoForTwoStrokesOnSameLayer()`
- [/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/HistoryControllerTests.swift#L708](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/HistoryControllerTests.swift#L708) `dirtyRestoreTopologyMismatchLeavesWorkspaceAndStacksUnchanged()`

### Pixel history paths

- [/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift#L8](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift#L8) `fillAtPointSupportsUndoRedo()`
- [/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift#L24](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift#L24) `fillAtPointMixedWithSelectionOperationsKeepsUndoRedoOrder()`
- [/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift#L252](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/WorkspaceViewModelPixelHistoryTests.swift#L252) `fillAtPointTopologyFenceKeepsUndoRedoChainCorrect()`

### Audit / baseline measurement

- [/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/PerformanceAuditFactTests.swift#L14](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/PerformanceAuditFactTests.swift#L14) `performanceAuditMeasurementRun()`
- [/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/PerformanceAuditFactTests.swift#L171](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/PerformanceAuditFactTests.swift#L171) `fillAtPointDirtyPilot4096x4096_4Layers()`
- [/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/PerformanceAuditFactTests.swift#L201](/Users/victorcloux/Desktop/ArtFlex/Tests/ArtFlexTests/PerformanceAuditFactTests.swift#L201) `fillAtPointDirtyPilot8192x8192_8Layers()`

## Validation Status

Validated during closure:

- `swift build`
- `swift test --filter HistoryControllerTests`
- `swift test --filter WorkspaceViewModelPixelHistoryTests`
- `swift test --filter fillAtPointDirtyPilot4096x4096_4Layers`
- `swift test --filter fillAtPointDirtyPilot4096x4096_8Layers`
- `swift test --filter fillAtPointDirtyPilot8192x8192_4Layers`
- `swift test --filter fillAtPointDirtyPilot8192x8192_8Layers`
- `swift test`

## Deferred Items

Explicitly deferred:

- PNG export CPU transform
- `fillAtPoint` intrinsic algorithm / implementation performance
- deeper `smudge` optimization
- generic partial history
- `trim` / restore model adjustments

These items are not part of the closed baseline and should not be reopened implicitly.
