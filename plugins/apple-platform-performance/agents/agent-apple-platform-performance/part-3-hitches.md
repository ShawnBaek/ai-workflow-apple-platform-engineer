# Part III — Hitches (Items 11–14)

A **hitch** is one frame that missed its deadline. Frame budgets:

| Display | Budget per frame |
|---------|-----------------|
| 60 Hz (most iPhones / iPads, all Watches) | **16.67 ms** |
| 120 Hz ProMotion (iPhone Pro, iPad Pro) | **8.33 ms** |

Reference: [Understanding hitches in your app](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)

## Item 11 — Decode images off the main thread

`UIImage(named:)` decodes lazily on first draw, **on the main thread**, during the frame that needs it. A large image causes one big hitch when it scrolls into view.

**Don't:**
```swift
List(photos) { photo in
    Image(uiImage: UIImage(named: photo.assetName)!)  // decodes on scroll
}
```

**Do** (pre-decode):
```swift
.task {
    decoded = await Task.detached {
        UIImage(named: photo.assetName)?.preparingForDisplay()
    }.value
}
```

For SwiftUI: `AsyncImage` decodes off main automatically. For Core Image / heavy pipelines, do the work in a `Task.detached` then assign.

## Item 12 — Avoid expensive `.shadow` and rounded corners that force off-screen rendering

Shadows on non-opaque views and corners on complex content trigger off-screen passes. The GPU has to render the view to a texture, then composite — extra work per frame.

**Don't:**
```swift
ScrollView {
    LazyVStack {
        ForEach(items) { item in
            ItemRow(item: item)
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .shadow(radius: 8)        // every row, every frame
        }
    }
}
```

**Do** — group cheaply (cast one shadow per cluster, or use `.compositingGroup()` to consolidate), or accept a smaller shadow / no shadow for list rows. Reserve big shadows for hero elements.

## Item 13 — Avoid layout work inside scroll

Anything that triggers re-measurement during scroll causes hitches. Stable row heights help; `LazyVStack` with consistent rows + fixed `.frame(height:)` per row keeps layout cheap.

## Item 14 — Profile with Instruments → Animation Hitches

Look for the **Hitch Time Ratio** metric. >5 ms/s sustained is noticeable. >10 ms/s is bad. The template highlights the offending frame and lets you drill into the Commit phase, Render Server, and GPU.

For real users post-ship: **MetricKit** → `MXMetricPayload.animationMetrics`.
