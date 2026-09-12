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

`.task` is asynchronous but can inherit main-actor isolation. It does not
automatically move synchronous work off the main actor. Prefer an asynchronous
API. For bounded legacy synchronous work, use an explicitly off-actor worker;
propagate cancellation and check it before publishing the result:
```swift
.task {
    let worker = Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        let data = try Data(contentsOf: url)
        try Task.checkCancellation()
        return try JSONDecoder().decode([Note].self, from: data)
    }
    do {
        let result = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        self.notes = result // This view's .task is main-actor isolated.
    } catch is CancellationError {
        // The screen no longer needs this result.
    } catch {
        self.loadError = error.localizedDescription
    }
}
```

`Note` must be `Sendable`; transfer immutable values across isolation boundaries.
Cancellation cannot interrupt `Data(contentsOf:)` midway. Bound file size and
keep blocking operations out of cooperative-executor hot paths. Use the
project's existing worker instead of adding a new layer for this example.

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

Window → Organizer → **Hangs** tab. Prioritize by affected users, duration,
frequency, and the interrupted task. A ranking alone does not define release risk.

For local development, enable **Edit Scheme → Run → Diagnostics → Thread Performance Checker**. It surfaces hangs in real time during dev.
