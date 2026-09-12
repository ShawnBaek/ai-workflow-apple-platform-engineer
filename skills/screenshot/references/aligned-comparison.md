# Aligned visual evidence

Use an exact Figma node export or an approved code Preview as the reference.
Capture the corresponding integrated app state through the existing authorized
Xcode/Simulator path. Label the panels **Reference** and **Actual**, including
whether each is Figma, Preview, Simulator, or physical device. A synthetic helper
fixture is a tool test, not evidence that a real app matches Figma.

## Make the states comparable

Record design node/version or Preview identity, reviewed source revision, device,
OS, viewport in points, safe areas, raster scale, appearance, Dynamic Type,
locale, fixture, scroll position, keyboard, and settled interaction state where
relevant. Match the content and state before comparing geometry. Preserve raw
captures and their hashes. If cropping or masking is necessary, keep an
unmodified original and record the exact transform and excluded area.

Do not stretch unequal viewports, move a component, snap a marker, or choose an
arbitrary tolerance to make an image appear correct. Different raster scales
can be resampled uniformly to a common points-based viewport for review; this
is not raw pixel identity. Different aspect ratios require a documented crop or
a fresh capture, not independent x/y scaling.

## Check both axes

- Draw a horizontal reference guide across **both panels** at each selected
  top edge, baseline, center, separator, or bottom anchor. Mark the actual y
  separately so its vertical offset remains visible.
- Repeat the reference x guide at the corresponding **panel-local x** in both
  panels. Mark actual x separately, for example with a dashed guide. The right
  panel's canvas origin is not an app-coordinate difference.
- Report `deltaX = actualX - referenceX` and
  `deltaY = actualY - referenceY` in points with a top-left origin: positive x
  is right, positive y is down. Compare local container coordinates or responsive
  edge/center invariants when those are the accepted layout contract.

Choose only the anchors relevant to the changed design. Start with viewport and
safe areas, then the affected internal components. Keep a clean side-by-side
image beside the annotated image so guides do not hide clipping or typography.
The helper cannot infer a text baseline from a screenshot: supply measured
landmarks from the design and view/hierarchy geometry, and record their origin.

The Swift command `apple-verify compare --manifest comparison.json --output-dir
comparison` writes a clean PNG, an annotated PNG, and a JSON report into a **new**
directory whose parent exists. See [verification commands](../../../docs/verification.md).
A manifest uses one common upright viewport; paths are relative to the manifest:

```json
{
  "referencePath": "figma.png",
  "actualPath": "simulator.png",
  "viewportWidthPoints": 393,
  "viewportHeightPoints": 852,
  "outputScale": 2,
  "landmarks": [
    {"name": "title baseline", "referenceX": 24, "referenceY": 104,
     "actualX": 24, "actualY": 106}
  ]
}
```

The report contains raw signed deltas and source/output scale transforms, with
no automatic UI-parity verdict. Apply the task's accepted tolerance if one
exists. Otherwise report the mismatch or responsive invariant directly and
resolve only material uncertainty with the user. Recheck affected states after a
layout fix; avoid a complete screenshot matrix for a one-component adjustment.

## Motion and performance

A screenshot verifies a state, not animation. Record the relevant trigger,
intermediate movement, interruption/reversal when changed, and settled outcome.
Use the [Preview and motion contract](../../xcode-preview-design/references/preview-and-motion-contract.md)
for Apple guidance, selective Disney principles, and Reduce Motion. Explain the
purpose of a custom animation; system transitions are usually the starting point.

For frame delivery, launch latency, CPU, memory, or energy claims, attach a scoped
Instruments/XCTest measurement with the device and configuration. Capture FPS or
video duration is not a rendering-performance measurement. Use Swift with
ImageIO/CoreGraphics for image inspection and AVFoundation for frame extraction
or trimming when a custom evidence helper is needed.

See the [synthetic Swift example](../../../docs/evidence/README.md) for a reproducible proof of the comparison tool itself.
