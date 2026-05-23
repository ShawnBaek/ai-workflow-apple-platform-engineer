# Part II — Hangs (Items 7–10)

Apple's threshold: a **major hang** is a main-thread block that prevents UI updates. The Hang Report in Xcode Organizer surfaces these from real users.

Reference: [Understanding hangs in your app](https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app)

## Item 7 — Never do synchronous I/O on the main thread

Disk reads, file enumeration, JSON parsing of non-trivial blobs, image decoding — all can hang on slower devices or large files.

**Don't:**
```swift
.task {
    let data = try Data(contentsOf: url)                // sync I/O
    let notes = try JSONDecoder().decode([Note].self, from: data)
    self.notes = notes
}
```

**Do** (move off main; `.task` already gives you a background context, but be explicit when calling sync APIs):
```swift
.task {
    let notes: [Note] = try await Task.detached(priority: .userInitiated) {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([Note].self, from: data)
    }.value
    self.notes = notes        // back on MainActor by default
}
```

## Item 8 — Avoid locks on the main thread

A lock waiting on a background actor blocks the UI just as hard as I/O.

**Don't** wrap a shared mutable store in `NSLock` and call `.lock()` from a view.

**Do** model shared mutable state as an `actor`. Actors serialize calls without blocking the main thread.

## Item 9 — Treat `MainActor` boundaries as work — don't ping-pong

Every `await MainActor.run { … }` round-trip is a context switch. If you're updating 100 items, batch them.

**Don't:**
```swift
for item in items {
    await MainActor.run { self.items.append(item) }
}
```

**Do:**
```swift
await MainActor.run { self.items.append(contentsOf: items) }
```

## Item 10 — Read the Hang Report in Xcode Organizer weekly after launch

Window → Organizer → **Hangs** tab. Apple aggregates these from real device telemetry. Treat anything in the top 10 list as a release blocker.

For local development, enable **Edit Scheme → Run → Diagnostics → Thread Performance Checker**. It surfaces hangs in real time during dev.
