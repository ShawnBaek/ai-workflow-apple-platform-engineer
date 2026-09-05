# Part V — Diagnose before users do (Items 20–23)

Reference: [Diagnosing performance issues early](https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early)

## Item 20 — Measure a hot path when a stable regression check is useful

Use the existing test target. Do not create a performance or XCUI harness for a
small UI edit without a measured performance concern. Select the application
being measured: `XCTCPUMetric()` alone measures the test process, while
[`XCTCPUMetric(application:)`](https://developer.apple.com/documentation/xctest/xctcpumetric/init(application:))
measures the requested app.

```swift
func testScrollPerformance() {
    let app = XCUIApplication()
    let options = XCTMeasureOptions()
    options.invocationOptions = [.manuallyStart]
    measure(metrics: [
        XCTClockMetric(),
        XCTCPUMetric(application: app),
        XCTMemoryMetric(application: app)
    ], options: options) {
        // The app's existing fixture mode opens the same populated list at top.
        app.terminate()
        app.launchArguments = ["-UITestScenario", "populated-notes"]
        app.launch()
        let list = app.collectionViews["notes.list"]
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        startMeasuring()
        list.swipeUp(velocity: .fast)
        list.swipeUp(velocity: .fast)
        stopMeasuring()
    }
}
```

The fixture argument and selector are examples, not APIs supplied by this skill.
Use the actual app's supported setup and wait for data/animations to settle.
Reset every measured iteration to the same state outside the timed interval.
Measure launch separately with `XCTApplicationLaunchMetric`; mixing launch and
scrolling hides which behavior regressed. Choose a scroll/hitch metric when
frame delivery is the concern instead of inferring it from elapsed time.

Accept a baseline from repeated measurements under a recorded configuration.
Gate a meaningful regression budget after accounting for noise; a single fast
run or a Simulator screen recording is not a performance baseline.

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
