# apple-platform-performance

**Effective Apple Platform Performance** — a numbered Do/Don't field guide for indie iOS / macOS / watchOS developers, grounded in Apple's five canonical performance docs.

Covers **both SwiftUI and UIKit** — image decoding, off-screen rendering, layout, async work patterns — because the underlying causes (Core Animation commit phase, main-thread blocks, frame budget) are the same regardless of the UI framework.

Inspired by *Effective Java*, *Effective Modern C++*. Each item is one rule with code on both sides of the line.

## What it does

Diagnoses and fixes four distinct performance symptom classes — because the tool, the cause, and the fix are different for each:

| Symptom | Apple's name | When you notice it |
|---------|--------------|---------------------|
| Brief UI freeze | **Hang** | Tap → nothing happens for 200ms+ |
| Stuttery scrolling/animations | **Hitch** | Scroll velocity drops, animations skip a beat |
| Slow open from cold | **Launch time** | Splash → blank → finally usable |
| Heavy view re-renders | **SwiftUI body cost** | No frame drop yet, but it compounds |

Then walks you through 23 numbered items:

- **Part I (Items 1–6):** SwiftUI body cost & dependency tracking — `@State` placement, `Equatable` views, `LazyVStack`, stable `ForEach` IDs, work-outside-body, the SwiftUI Instruments template.
- **Part II (Items 7–10):** Hangs — sync I/O off main, actor-based locks, MainActor batching, the Xcode Organizer Hangs report.
- **Part III (Items 11–14):** Hitches — async image decode, off-screen rendering from shadows/corners, layout-during-scroll, Instruments Animation Hitches.
- **Part IV (Items 15–19):** Launch time — dylib audit, no sync network/migrations on launch, empty `App.init()`, App Launch instrument.
- **Part V (Items 20–23):** Diagnose-before-users — `XCTMetric` perf tests in CI, `os_signpost`, Thread Performance Checker, MetricKit in production.

## What it deliberately doesn't do

- Recommend a change without naming what to measure first.
- Bundle multiple optimizations into one suggestion ("change these 5 things").
- Suggest exotic Core Animation work for an indie app pre-MVP.
- Skip the symptom classification — hang ≠ hitch ≠ launch ≠ body cost; the fixes are different.
- Optimize a path no instrument has flagged.

## The triage script

When you report "the app feels slow":

1. **Classify the symptom** — hang / hitch / launch / body cost.
2. **Name the tool** — Time Profiler / Animation Hitches / App Launch / SwiftUI template.
3. **Ask for the data** — don't optimize on guesses.
4. **Map to an item** — exactly one numbered item with the code change.
5. **One change, measure again** — refuses to bundle.

## When to use

- "The list is janky when I scroll fast."
- "App freezes for a second after I tap Save."
- "Launch on the iPhone SE takes forever."
- "Instruments shows 200 `body` invocations per frame — what do I do?"
- "I want to add a perf test before this regresses."
- Before shipping any non-trivial feature.

## Prerequisites

- Xcode (any version with Instruments).
- A device for real measurement — Simulator perf is **not representative**.
- For CI gating: an Xcode Cloud workflow or other CI that runs `xcodebuild test`.

## Install

```bash
npx claude-plugins install @shawnbaek/agent-design/apple-platform-performance
```

Requires Claude Code v2.0.12+. Or interactively inside Claude Code:

```text
/plugin marketplace add shawnbaek/agent-design
/plugin install apple-platform-performance@indie-native-app
```

## References (Apple, authoritative)

- [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance)
- [Understanding hangs in your app](https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app)
- [Understanding hitches in your app](https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app)
- [Diagnosing performance issues early](https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early)
- [Reducing your app's launch time](https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time)
- [MetricKit](https://developer.apple.com/documentation/metrickit)
- [XCTest metrics](https://developer.apple.com/documentation/xctest/xctmetric)

## Companion agents in this marketplace

- [`apple-platform-ui`](../apple-platform-ui/README.md) — produces the SwiftUI code this agent reviews.
- [`xcodebuild`](../xcodebuild/README.md) — runs the Instruments traces and XCTest perf tests.
- [`commit-message`](../commit-message/README.md) — writes the `perf:` commits when you've actually made things faster.
