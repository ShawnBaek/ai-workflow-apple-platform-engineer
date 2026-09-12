# Figma and Simulator parity

Use this after implementation when the accepted design is a node-specific Figma
frame. A successful build, subjective glance, or matching outer container is
not proof of component parity.

## Lock comparable states

For every state, record the Figma file key, node ID, frame name, natural size,
and the app route, deterministic fixture, navigation/page state, orientation,
device, OS/runtime, viewport, and safe-area insets. Compare collapsed with
collapsed and expanded with expanded. Recapture when strings, data, selected
page, keyboard, alert, or animation state makes the pair non-equivalent.

Preserve the raw Figma node export, full-resolution Simulator screenshot, UI
hierarchy from the same instant, and the exact interaction used to reach the
state. Use the latest hierarchy-derived hit region. A sheet transition is one
continuous down-hold-move-up gesture; capture only after it settles.

## Compare the right coordinate systems

Separate full-screen coordinates, safe-area-adjusted coordinates,
container-local coordinates, and responsive edge/center anchors. Do not resize
different viewports and call a pixel overlay authoritative. For a bottom surface
whose design excludes the home-indicator region, useful normalized values are:

```text
availableHeight = viewportHeight - bottomSafeArea
sheetContentHeight = visibleSheetHeight - bottomSafeArea
sheetTopRatio = sheetTop / availableHeight
sheetHeightRatio = sheetContentHeight / availableHeight
localX = componentX - containerX
localY = componentY - containerY
bottomDistance = availableHeight - componentMaxY
```

Compare fixed constraints in local points, detents as normalized height ratios,
and responsive horizontal placement by leading/trailing margin or center offset.
Use pixel diff only when both captures have the
same dimensions and coordinate space.

## Verify outside and inside

Inspect the viewport/safe areas and outer surface first, then every requested
visible component: header and controls, media, labels, separators, fixed bottom
or action blocks, pager, map controls, visibility, opacity, and hit testing in
each state. A wrapper can match while its visible child remains inset or shifted.

Use the project's accepted tolerance. If none exists, report raw deltas and mark
the threshold as requiring explicit acceptance; do not invent cross-project
point or percentage tolerances. Classify each row:

```text
component | Figma geometry | Simulator geometry | normalized/local delta | verdict
```

Verdicts are: within an accepted tolerance, responsive equivalent with a named
invariant, mismatch with the likely owning constraint, or not comparable with
the recapture or acceptance threshold needed. Allowed artwork differences never
hide a geometry or state mismatch. After a requested fix, recapture every
affected state and rerun the same table.

## Human-review artifacts

Produce the clean and annotated side-by-side captures described in
[aligned visual evidence](../screenshot/references/aligned-comparison.md): shared
horizontal guides, matching panel-local vertical guides, and signed x/y point
deltas. Connect each mismatch to the relevant layout owner when known. Preserve
raw inputs; a guide overlay never substitutes for checking actual runtime state.
