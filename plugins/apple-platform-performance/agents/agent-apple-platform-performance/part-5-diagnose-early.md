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

final class PerfReporter: NSObject, MXMetricManagerSubscriber {
    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            // p.animationMetrics — hitches
            // p.applicationLaunchMetrics — launch p99
            // p.applicationResponsivenessMetrics — hang time
        }
    }
}
```

Wire `MXMetricManager.shared.add(reporter)` at app start. Pipe payloads to your analytics. This is how you find what real users see, on devices and OS versions you don't have.
