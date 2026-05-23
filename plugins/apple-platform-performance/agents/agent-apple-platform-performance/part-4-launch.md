# Part IV — Launch time (Items 15–19)

Apple's launch phases (in order):

1. **Pre-main** (dyld + ObjC class registration + static initializers)
2. **`application(_:didFinishLaunchingWithOptions:)`**
3. **First frame render** (SwiftUI's first `body` call → first commit)

Launch types:
- **Cold:** fresh boot, app not in disk cache. Slowest.
- **Warm:** recently terminated, code/data still in disk cache.
- **Resumed:** suspended in background, no real "launch."

Target: < ~400 ms cold launch on the slowest supported device.

Reference: [Reducing your app's launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)

## Item 15 — Don't link frameworks you don't need at launch

Each dylib adds dyld linking time. Audit the **Frameworks, Libraries, and Embedded Content** list. If something is only used 5 minutes in, make it a separate framework you load on demand, or check whether you actually need it at all.

## Item 16 — No synchronous network on launch

A 200 ms ping at launch = 200 ms before the user sees anything. Defer network until the first frame is on screen.

**Don't:**
```swift
@main
struct MyApp: App {
    init() { ServerConfig.fetchSync() }   // blocks launch
}
```

**Do:**
```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .task { await ServerConfig.fetch() }   // after first frame
        }
    }
}
```

## Item 17 — Defer database migrations until after first frame

Core Data / SwiftData / SQLite migrations on launch are a classic launch-killer. Show the UI first, run migration in the background, gate the screens that need it.

## Item 18 — Keep `init()` of `App` and root views empty

Anything in `App.init()` runs before the window is on screen. SwiftData stores, `@Environment` setup, AppDelegate boilerplate — fine. Heavy work — bad.

## Item 19 — Profile with Instruments → App Launch

Choose **App Launch** template, set the scheme to **Wait for Executable Launch**, launch. The trace shows you each phase budget. Look for big bars in dyld (too many frameworks) or in `didFinishLaunchingWithOptions` (work to defer).

Real-user launch metrics: **Organizer → Launch Time**, and **MetricKit → `MXAppLaunchMetric`**.
