---
name: figma-golden-testing
description: >-
  Capture an Apple UI screen and compare it with a node-specific Figma frame using
  an aligned overlay, side-by-side image, pixel diff, visible-text checks, and a
  repeatable JSON report. Use for SwiftUI/UIKit visual parity and golden snapshot
  review when a Figma URL is the source of truth.
---

# Figma golden testing

Use Figma as the visual contract for UI work. A passing screenshot capture proves
that an image was produced; it does not prove design parity. Keep the Figma URL,
file key, node ID, frame size, source symbol, and capture fixture together so a
future run compares the same state.

## Workflow

1. Require a node-specific Figma URL. Record the file key, node ID, frame name,
   natural width/height, and a raw node-tree export. Download the Figma PNG at
   scale 1. Inspect the tree for every visible `TEXT` node and record its string,
   bounds, and node ID.
2. Locate the real SwiftUI view or view controller used by the route. Record a
   mapping in a checked-in `figma-map.json` (or an existing project mapping) with
   `figmaUrl`, `nodeId`, `sourcePath`, `symbol`, `fixture`, and `capturedAt`.
3. Render the screen at the Figma frame's pixel dimensions on a deterministic
   simulator/device fixture. Capture the full screen and hierarchy from the same
   settled state. Set locale, appearance, time zone, data, and status-bar state
   explicitly. Use Point-Free SnapshotTesting when the project already depends on
   it; otherwise use XCTest/XCUITest attachments and the supplied comparator.
4. Before changing production code, run the comparator:
   `python3 scripts/overlay_diff.py --figma figma.png --actual actual.png --out report`.
   It writes `overlay.png` (50% aligned blend), `diff.png` (red difference heatmap),
   `side-by-side.png`, and `metrics.json`. Images must have identical dimensions;
   never silently resize, crop, or mask them.
5. Check visible strings independently from pixels. Report missing, extra, or
   changed labels/buttons/text views with Figma node IDs and source accessibility
   identifiers when available. Pixel agreement is a review signal, not a semantic
   assertion.
6. Fix the owning view/layout, recapture, and rerun the same command until the
   agreed tolerance passes or the remaining mismatch is explicitly documented.
   Preserve each final report and both raw inputs as review evidence.

## Report

Show the Figma image and actual capture side by side, plus the overlay and diff.
Report device, OS, viewport, safe-area insets, fixture, source mapping, visible
text results, threshold, matching pixels, and percentage. Use the comparator's
`matchPercentage` only as raw pixel agreement; do not call it perceptual similarity
or acceptance by itself. Name large gaps by component and likely owning constraint.

## Failure handling

If capture or comparison fails, retain the failure log and continue the loop after
fixing the narrowest cause. Stop only for an unavailable node, unavailable
simulator/toolchain, or a state that cannot be made deterministic; report the
concrete blocker and the last artifacts.

Do not commit Figma access tokens, transient asset URLs, or generated Xcode
projects. Use the project's existing Xcode project/workspace and test conventions.

