# Part V — Diagnose before users do (Items 20–23)

Reference: [Diagnosing performance issues early](https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early)

## Item 20 — Write `XCTMetric` perf tests for hot paths and gate them in CI

```swift
final class NotesListPerfTests: XCTestCase {
    func testScrollPerformance() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-UITestMode", "YES"]

        measure(metrics: [
            XCTClockMetric(),
            XCTCPUMetric(),
            XCTMemoryMetric(application: app),
            XCTOSSignpostMetric.applicationLaunch
        ]) {
            app.launch()
            app.swipeUp(velocity: .fast)
            app.swipeUp(velocity: .fast)
        }
    }
}
```

Available metrics — use what fits:
- `XCTClockMetric` — wall-clock time
- `XCTCPUMetric` — CPU time + cycles
- `XCTMemoryMetric` — peak physical memory
- `XCTStorageMetric` — disk writes
- `XCTApplicationLaunchMetric` — full launch profile
- `XCTOSSignpostMetric` — duration between matching `os_signpost` events you placed in code

**Set baselines.** Run, capture, accept baseline. From then on, regressions fail the test. Gate in Xcode Cloud or your CI.

## Item 21 — Mark expensive code regions with `os_signpost`

```swift
import os
let log = OSLog(subsystem: "app.notes", category: .pointsOfInterest)

func loadNotes() async throws -> [Note] {
    let id = OSSignpostID(log: log)
    os_signpost(.begin, log: log, name: "loadNotes", signpostID: id)
    defer { os_signpost(.end, log: log, name: "loadNotes", signpostID: id) }
    // … work …
}
```

Then in Instruments, the Points of Interest track shows you exactly how long `loadNotes` took on any trace.

## Item 22 — Enable Thread Performance Checker during dev

Edit Scheme → Run → Diagnostics → **Thread Performance Checker**. Surfaces hangs and priority inversions while you develop, before they ship.

## Item 23 — Watch MetricKit in production

```swift
import MetricKit
import os

@MainActor
final class PerfReporter: NSObject, MXMetricManagerSubscriber {
    static let shared = PerfReporter()

    func start() { MXMetricManager.shared.add(self) }

    // Apple's MXMetricManagerSubscriber doesn't carry MainActor isolation,
    // so under Swift 6 strict concurrency the @MainActor singleton can't
    // satisfy the protocol without these `nonisolated` overrides. The
    // payloads themselves are sendable; the logger is created locally to
    // avoid capturing self-isolated state.
    nonisolated func didReceive(_ payloads: [MXMetricPayload]) {
        let log = Logger(subsystem: "com.myapp", category: "metrics")
        for p in payloads {
            // p.animationMetrics — hitches
            // p.applicationLaunchMetrics — launch p99
            // p.applicationResponsivenessMetrics — hang time
            log.notice("MXMetricPayload: \(p.jsonRepresentation(), privacy: .public)")
        }
    }

    nonisolated func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let log = Logger(subsystem: "com.myapp", category: "metrics")
        for p in payloads {
            // Symbolicated crash, hang, CPU, disk-write exceptions.
            log.error("MXDiagnosticPayload: \(p.jsonRepresentation(), privacy: .public)")
        }
    }
}
```

Wire `PerfReporter.shared.start()` from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`. Apple delivers one payload per day per install — subscribe early or you miss the first one.

**Swift 6 strict-concurrency gotcha.** A `static let shared` without an actor declaration trips the "not concurrency-safe because non-Sendable type may have shared mutable state" diagnostic. The standard fix for UIKit-touching singletons (TTSPlayer, NoteRepository, PerfReporter) is `@MainActor` on the class **plus** `nonisolated` on any protocol callback the framework delivers from a non-isolated context (MetricKit, WCSession, AVAudioPlayerNode completion handlers, NotificationCenter selectors are common cases). The macCatalyst build is strictest about this — if it builds clean, iOS will too.

**Reading the unified log.** During development: `xcrun simctl spawn booted log stream --predicate 'subsystem == "com.myapp" && category == "metrics"'`. On a TestFlight build: Console.app → connected device → filter by subsystem.

Pipe payloads to your crash reporter or analytics once you have one. Until then, the unified log is enough to spot regressions when you run a TestFlight build against your own device.
