# Part I — SwiftUI body cost & dependency tracking (Items 1–6)

## Item 1 — Keep `@State` as close to the view that mutates it as possible

Moving `@State` up the tree forces every descendant on a state change to be re-evaluated. SwiftUI's value comes from narrow invalidation — give it back by scoping state.

**Don't** (every keystroke invalidates the whole form):
```swift
struct SettingsView: View {
    @State private var displayName = ""
    @State private var email = ""
    var body: some View {
        Form {
            TextField("Name", text: $displayName)        // mutates displayName
            TextField("Email", text: $email)              // mutates email
            ExpensiveCharts(displayName: displayName)     // re-renders on email change too
        }
    }
}
```

**Do** (push state into the leaves that actually own it):
```swift
struct SettingsView: View {
    var body: some View {
        Form {
            NameField()
            EmailField()
            ExpensiveCharts()
        }
    }
}
private struct NameField: View {
    @State private var name = ""
    var body: some View { TextField("Name", text: $name) }
}
```

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
        .onChange(of: notes) { _, new in sorted = new.sorted { $0.date > $1.date } }
}
```

Or — store the sort in the model.

## Item 6 — Profile `body` with the SwiftUI Instruments template before optimizing

Open **Instruments → SwiftUI**. The **View Body** track shows you the count and self-time of every `body` call. If a body fires 200 times per frame and you haven't measured it, you don't know which item above to apply.

## Reference

- [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance)
