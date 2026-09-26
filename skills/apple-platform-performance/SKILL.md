---
name: apple-platform-performance
description: >-
  Diagnoses and fixes performance problems in iOS / iPadOS / watchOS / macOS apps — SwiftUI and UIKit alike. Slow scrolling, dropped frames (hitches), main-thread hangs, slow app launches, ballooning view re-evaluations, expensive image decoding, off-screen rendering, CoreML/ANE inference latency, AVAudioEngine buffer starvation. Use when the developer says "the list is janky", "scroll feels laggy", "app freezes on tap", "launch is slow", "the watch app is sluggish", "TTS takes too long to start", "audio cuts out", "CoreML is slow", "Instruments shows X". Grounded in Apple's five canonical performance docs plus ML inference and audio pipeline patterns. Use for an observed performance issue or a requested performance review.
---

Diagnose the reported symptom with measurements and focused source analysis. Match the explanation and evidence to the developer's needs; the numbered references below are an organization aid, not a required report style.

You are grounded in Apple's five canonical performance docs (all linked below). When the developer asks "is this fast enough?" you check against the items. When they ask "why is it slow?" you map the symptom to the item that explains it.

You cover **both SwiftUI and UIKit** — the underlying machinery (Core Animation commit phase, main-thread queue, dyld, frame deadlines) is the same regardless of the UI framework. SwiftUI items focus on `body` cost and dependency tracking; UIKit items focus on layout passes, image decoding, and Auto Layout. Hangs, hitches, and launch-time items apply to both.

Support individuals and teams using their existing performance budgets and profiling workflow.

---

## Deployment target — inspect the project

Resolve the affected targets' actual minimum OS, selected SDK/compiler and test
destination through `xcode-project-workflow`. Check the availability of each
instrument/API used below; preserve supported fallback behavior and the existing
architecture. A newer profiling toolchain does not authorize raising the app's
deployment target.

---

## Operating principles

1. **Measure first, optimize second.** Never recommend a change without naming what to measure. "Switch to LazyVStack" is wrong; "Profile with the SwiftUI Instruments template — if you see >5ms `body` reevaluations per frame, switch to LazyVStack" is right.
2. **Diagnose the symptom class first.** A hang is not a hitch is not a slow launch. Apple separates them on purpose — different tools, different fixes.
3. **One change per measurement cycle.** Don't refactor seven things and then measure. Change one, measure, keep or revert.
4. **Indie scope.** Don't recommend custom CoreAnimation render pipelines for an app that hasn't shipped its first build. Match advice to where the developer is.

---

## The five perf symptom classes

| Symptom | What Apple calls it | Frame impact | Tool |
|---------|---------------------|--------------|------|
| App freezes briefly on tap | **Hang** (main thread blocked) | Multiple frames missed; UI unresponsive | Instruments → Time Profiler (includes the Hangs instrument), Thread Performance Checker, Xcode Organizer Hangs |
| Scrolling stutters; animations skip | **Hitch** (one frame missed its deadline) | 1+ frames at 16.67ms@60Hz or 8.33ms@120Hz | Instruments → Animation Hitches |
| App takes too long to be usable from launch | **Launch time** | Pre-main + did-finish-launching + first frame | Instruments → App Launch, Organizer Launch Time |
| `body` recomputes too often / too expensively | **SwiftUI rendering cost** | Doesn't necessarily drop frames but compounds | Instruments → SwiftUI template |
| TTS is slow to start; audio stutters or cuts out | **ML inference / audio pipeline** | Perceived latency; buffer underruns | Instruments → Time Profiler + Core ML, `os_signpost` |

Always classify the symptom before opening a tool. The rest of this skill is organized by class.

Main Thread Checker is not a hang tool: it reports calls to main-thread-only system APIs, such as UIKit and AppKit, made from another thread — a correctness bug. A hang is the main thread staying busy or blocked for too long; the Hangs instrument measures hangs, and Thread Performance Checker flags hang risks such as synchronous I/O on the main thread and priority inversions.

---

# Effective Apple Platform Performance — the items

27 numbered items grouped into 6 Parts. Each item has the same shape:

> **Item N — Rule.** Why it matters. **Do** / **Don't** with code.

Read the matching Part file under [`./`](./) before answering questions in that area:

| Part | Items | When to read |
|------|-------|--------------|
| **Part I — SwiftUI body cost & dependency tracking** | 1–6: dependency scope, `Equatable` views, `LazyVStack`, stable `ForEach` IDs, work-outside-body, SwiftUI Instruments | "Body fires 200×/frame", "list scroll feels heavy", "scope my state". [`part-1-body-cost.md`](./part-1-body-cost.md) |
| **Part II — Hangs** (main-thread blocks) | 7–10: sync I/O off main, actor locks, MainActor batching, Organizer Hangs report | "Tap freezes the app", "Save button hangs", "main thread blocked". [`part-2-hangs.md`](./part-2-hangs.md) |
| **Part III — Hitches** (dropped frames) | 11–14: async image decode, off-screen rendering, layout-during-scroll, Animation Hitches instrument | "Scroll stutters", "animation skips", "Hitch Time Ratio is bad". [`part-3-hitches.md`](./part-3-hitches.md) |
| **Part IV — Launch time** | 15–19: dylib audit, no sync network on launch, defer migrations, empty `App.init()`, App Launch instrument | "Slow cold launch", "splash takes 2s", "pre-main is heavy". [`part-4-launch.md`](./part-4-launch.md) |
| **Part V — Diagnose before users do** | 20–23: `XCTMetric` perf tests, `os_signpost`, Thread Performance Checker, MetricKit in production | "Gate perf regressions in CI", "wire MetricKit", "measure before optimizing". [`part-5-diagnose-early.md`](./part-5-diagnose-early.md) |
| **Part VI — CoreML / ANE inference & AVAudio pipeline** | 24–27: lazy model load, ANE compute units, audio pre-buffering, AVAudioSession interrupt handling | "TTS is slow to start", "audio stutters", "CoreML inference is blocking the UI", "audio cuts out after a call". [`part-6-ml-audio.md`](./part-6-ml-audio.md) |

## When the developer reports a perf issue — the triage script

1. **Classify the symptom.** "App freezes" → hang. "Scrolling stutters" → hitch. "Slow to open" → launch time. "List feels heavy" → could be SwiftUI body cost.
2. **Name the tool.** Hang → Time Profiler (Hangs instrument) + Organizer Hangs. Hitch → Animation Hitches. Launch → App Launch instrument. Body cost → SwiftUI Instruments.
3. **Collect the data.** Run the relevant available instrument (command-line recipe below) or focused measurement in the authorized app context. Request only missing access or inputs; do not hand runnable verification back to the user by default.
4. **Map to an item.** Hand them one numbered item with the code change.
5. **One change, then measure again.** Refuse to bundle five changes.

### Record and export a trace with `xctrace`

Template and instrument names change between Xcode releases; confirm them with `xcrun xctrace list templates` and `xcrun xctrace list instruments` on the selected Xcode. The names below were checked on Xcode 27.1. Prefer a physical device, ideally an older supported model — Simulator timings are not realistic — and address it by the UDID from `xcrun xctrace list devices`, not by display name. Profile a build made with the scheme's Profile configuration (Release by default, which is what Product → Profile builds; from the command line, build with `-configuration Release`), not a Debug Run build. A Debug build runs unoptimized code, and Xcode's Run action attaches LLDB and turns on Thread Performance Checker and Main Thread Checker by default, so their overhead lands in the trace.

| Symptom class | Record with | Export tables (confirm with `--toc`) |
|---|---|---|
| Hang | `--template 'Time Profiler'` (includes Hangs) | `potential-hangs`, `hang-risks`, `time-profile` |
| Hitch | `--template 'Animation Hitches'` | `hitches` |
| Launch time | `--template 'App Launch'` with `--launch` | `life-cycle-period`, `time-profile` |
| SwiftUI body cost | `--template 'SwiftUI'`; for a device on an OS without SwiftUI trace support (Part I, Item 6), `--template 'Time Profiler' --instrument 'View Body (Legacy)'` | `swiftui-updates`, `swiftui-causes`; legacy: `swiftui-body-interval` |
| ML inference / audio | `--template 'Time Profiler' --instrument 'Core ML'` | `coreml-os-signpost`, `os-signpost` with `@category="PointsOfInterest"` (more than one can match; pick the target process's table from `--toc`), `time-profile` |

```sh
UDID='<device-UDID>'   # from: xcrun xctrace list devices
xcrun xctrace record --template 'Time Profiler' --device "$UDID" \
  --time-limit 30s --no-prompt --output hang.trace \
  --launch -- '<path/to/App.app or app name>'
xcrun xctrace export --input hang.trace --toc --output hang-toc.xml
xcrun xctrace export --input hang.trace --output hangs.xml \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="potential-hangs"]'
```

Reproduce the symptom within the time limit. Use `--attach <name|pid>` instead of `--launch` for an app that is already running; if `--launch` does not resolve an app installed on the device, launch the installed app without the debugger (from the Home Screen, or `xcrun devicectl device process launch --device "$UDID" <bundle-id>`), then use `--attach`. Launch time still needs `--launch`. Report the device, OS, build configuration and trace path with the numbers, and record a new trace after each change.

---

## What you will NOT do

- Recommend a SwiftUI change without naming what to measure.
- Bundle multiple optimizations into one suggestion.
- Suggest exotic CoreAnimation work for an indie app that hasn't shipped its MVP.
- Skip the classification (hang vs hitch vs launch vs body cost — they have different fixes).
- Optimize a path no instrument has flagged.

---

## References (Apple, authoritative)

- **Understanding and improving SwiftUI performance** → https://developer.apple.com/documentation/Xcode/understanding-and-improving-swiftui-performance
- **Understanding hangs in your app** → https://developer.apple.com/documentation/xcode/understanding-hangs-in-your-app
- **Understanding hitches in your app** → https://developer.apple.com/documentation/xcode/understanding-hitches-in-your-app
- **Diagnosing performance issues early** → https://developer.apple.com/documentation/xcode/diagnosing-performance-issues-early
- **Reducing your app's launch time** → https://developer.apple.com/documentation/xcode/reducing-your-app-s-launch-time
- **MetricKit** → https://developer.apple.com/documentation/metrickit
- **XCTest metrics** → https://developer.apple.com/documentation/xctest/xctmetric

When in doubt, cite the doc. These pages are the source of truth; this skill is a digest.
