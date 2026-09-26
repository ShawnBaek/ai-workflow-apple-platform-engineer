# Part I — SwiftUI body cost & dependency tracking (Items 1–6)

## Item 1 — Read fast-changing state in the smallest view that displays it

When a dependency changes, SwiftUI re-runs the `body` of each view that read it. It then compares every child's new inputs with the previous ones and skips a child's `body` when they are equal, so state high in the tree does not by itself re-evaluate every descendant. The cost is the reading view's own `body` plus any child whose inputs cannot be shown equal (for example, a stored closure that captures the parent). Move a read only after the SwiftUI instrument (Item 6) shows it: the reading view's `body` re-runs far more often than most of what it builds changes, and **Show Causes** traces those updates to one property.

**Don't** (the screen's `body` re-runs on every playback tick; `ChapterList` is skipped while its input compares equal):
```swift
@Observable final class PlayerModel {
    var elapsed: Duration = .zero   // updated several times per second during playback
    var chapters: [Chapter] = []
}

struct PlayerScreen: View {
    let model: PlayerModel
    var body: some View {
        VStack {
            ChapterList(chapters: model.chapters)
            Text(model.elapsed, format: .time(pattern: .minuteSecond)) // body reads elapsed
        }
    }
}
```

**Do** (same model and output; only the leaf reads `elapsed`):
```swift
struct PlayerScreen: View {
    let model: PlayerModel
    var body: some View {
        VStack {
            ChapterList(chapters: model.chapters)
            ElapsedLabel(model: model)
        }
    }
}

private struct ElapsedLabel: View {
    let model: PlayerModel
    var body: some View {
        Text(model.elapsed, format: .time(pattern: .minuteSecond)) // only this body reads elapsed
    }
}
```

Observation tracking per property requires `@Observable` (iOS 17 / macOS 14 /
watchOS 10 or later). A view observing an `ObservableObject` updates when any
`@Published` property changes, even one it does not read; on older targets keep
the fast-changing value in a separate object that only the leaf observes.
Re-record after the change and confirm the screen's update count dropped.

## Item 2 — Make views Equatable when their inputs are stable

`EquatableView` lets SwiftUI skip a `body` call entirely when the inputs haven't changed.

**Do** (for views that take large/composite props):
```swift
struct ChartRow: View, Equatable {
    let stats: [Double]
    static func == (lhs: ChartRow, rhs: ChartRow) -> Bool {
        lhs.stats == rhs.stats
    }
    var body: some View { /* expensive chart */ }
}

// Usage:
ChartRow(stats: stats).equatable()
```

Don't `Equatable`-ize every view — it has overhead. Use it on expensive bodies whose inputs you can compare cheaply.

## Item 3 — `LazyVStack` / `LazyHStack` for long lists, not `VStack`

`VStack` realizes every child immediately. For ≥ ~20 rows or any unknown-length list, switch to lazy.

**Don't:**
```swift
ScrollView { VStack { ForEach(items) { ItemRow(item: $0) } } }
```

**Do:**
```swift
ScrollView { LazyVStack { ForEach(items) { ItemRow(item: $0) } } }
```

For grids: `LazyVGrid` / `LazyHGrid`. For tables on macOS: `Table`.

## Item 4 — Give `ForEach` stable identifiers

When IDs change between renders, SwiftUI rebuilds rows instead of updating them — wiping state and triggering layout.

**Don't:**
```swift
ForEach(0..<items.count, id: \.self) { i in ItemRow(item: items[i]) }
// breaks the moment items reorder
```

**Do:**
```swift
ForEach(items) { item in ItemRow(item: item) }      // requires Identifiable
// or:
ForEach(items, id: \.id) { item in ItemRow(item: item) }
```

## Item 5 — Don't put expensive work inside `body`

`body` is called *a lot*. Anything in it that allocates, sorts, parses, or formats compounds.

**Don't:**
```swift
var body: some View {
    let sorted = notes.sorted { $0.date > $1.date }   // sorts on every body call
    List(sorted) { NoteRow(note: $0) }
}
```

**Do** (compute once on data change):
```swift
@State private var sorted: [Note] = []
var body: some View {
    List(sorted) { NoteRow(note: $0) }
        .onChange(of: notes, initial: true) { _, new in
            sorted = new.sorted { $0.date > $1.date }
        }
}
```

This overload requires iOS 17 / macOS 14 / watchOS 10 or later. On older targets,
initialize and update the sorted value at the existing model seam. Never leave
the first render empty until an unrelated data change. Cache only after the
profile shows sorting matters; a second stored array is not automatically faster.

## Item 6 — Profile `body` with the SwiftUI Instruments template before optimizing

Choose **Product → Profile**, then the **SwiftUI** template (or record it with `xctrace`, as in [SKILL.md](./SKILL.md)). The SwiftUI track's lanes separate the problems: **Update Groups** shows how long SwiftUI stays busy, **Long View Body Updates** marks bodies over 500 µs (orange) and 1 ms (red), **Long Platform View Updates** covers hosted UIKit/AppKit views, and **Other Long Updates** covers work such as geometry and text layout. The **Summary: All Updates** detail counts updates per view; **Show Causes** on an update opens the cause-and-effect graph naming the property or event behind it. These names follow Apple's article; Xcode 27.1 labels the platform-view lane **Long Representable Updates**, adds a separate **Long Layout Updates** lane, and names the graph **Cause & Effect Graph**. For a long update, read the Time Profiler track in the same range. If a body fires 200 times per frame and you haven't measured it, you don't know which item above to apply.

These lanes depend on the profiled device as well as on Xcode. The device must run an OS release that supports recording SwiftUI traces, which means the releases introduced alongside Xcode 26 or later (WWDC25 session 306). On a device with an older OS, fall back to the older **View Body** and **View Properties** instruments. Xcode 27.1 lists them as *View Body (Legacy)* and *View Properties (Legacy)* in `xcrun xctrace list instruments`, and its SwiftUI package describes them as tracing older OS versions. For example, add `--instrument 'View Body (Legacy)'` to a Time Profiler recording. Its `swiftui-body-interval` table (confirm with `--toc`) records each `body` duration by view type, but not what caused it.

## Reference

- [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance)
