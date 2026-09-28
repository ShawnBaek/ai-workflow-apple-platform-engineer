# Review checklist by change type

Use only the sections that match the diff; each item says what to check and what evidence settles it. Details stay with the owning skill. Project conventions and accepted ADRs take precedence over these defaults. When a change deviates from a default, report the deviation and its concrete consequence under the [evidence standard](../SKILL.md#evidence-standard); do not silently force the default or demand a rewrite the change does not need.

## UI

Owners: [apple-platform-ui](../../apple-platform-ui/SKILL.md), [xcode-preview-design](../../xcode-preview-design/SKILL.md), [apple-platform-performance](../../apple-platform-performance/SKILL.md).

- **Main actor and threading.** UI state and UIKit/AppKit objects change only on the main actor (`@MainActor` isolation or the project's established pattern). Decoding, I/O and parsing stay off it, and callbacks delivered from non-isolated contexts return to it before touching UI. Evidence: isolation at the changed types, the thread path of each callback, strict-concurrency diagnostics from the build. Reference: [MainActor](https://developer.apple.com/documentation/swift/mainactor).
- **Retain cycles and lifetime.** Closures, tasks, sinks, timers, observers and delegates held by a view, controller or ViewModel do not strongly capture their owner, or are cancelled or invalidated when it ends. Evidence: capture lists and ownership in the diff; for a claimed leak, a deinit check or [Debug Memory Graph](https://developer.apple.com/documentation/xcode/gathering-information-about-memory-use) observation. Reference: [strong reference cycles for closures](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/automaticreferencecounting/#Strong-Reference-Cycles-for-Closures).
- **Performance.** No expensive work in `body`, layout passes, cell configuration or scroll callbacks; stable list identity; large images downsampled and decoded off the main thread. Evidence: the source path; a claimed regression or improvement needs a before/after measurement per the performance skill.
- **Reuse.** Search for an existing component, design-system view, style, cell, modifier or formatter before accepting a new one. A near-duplicate is a finding that names the existing symbol and path. Evidence: the search and what it found.
- **Construction.** A storyboard/XIB screen keeps its new views, constraints and connections in Interface Builder. Programmatic views bolted onto a nib-backed screen for convenience are a finding unless the feature is already an established hybrid. Check the resource and source together per [storyboards and hybrid UI](../../apple-platform-ui/references/storyboards-and-hybrid.md).
- **Auto Layout and devices.** Layout uses Auto Layout or SwiftUI layout with [safe areas](https://developer.apple.com/documentation/uikit/positioning-content-relative-to-the-safe-area) and layout margins, adapts to the [size classes](https://developer.apple.com/documentation/uikit/uitraitcollection/horizontalsizeclass) and iPad widths the target supports, and scales with Dynamic Type including accessibility sizes. Hard-coded device frames, screen-size checks and fixed text heights are findings. Evidence: the constraints or layout code, a render at the narrowest and widest supported widths and a large text size, and no new unsatisfiable-constraint logs for the screen. For a [small change](../../agent-harness/references/small-change-path.md), its source and one render settle this item unless the diff can change layout across size classes or text scaling, which that path escalates.
- **Screen previews.** Every new or changed screen-level view has a `#Preview` (or the project's preview mechanism) that renders from deterministic fixtures or mock data with no live network, disk or account access. Render it through Xcode: the canvas, or the preview-render tool the Xcode MCP exposes (`RenderPreview`). When rendering fails, read the preview diagnostics (the Diagnostics button in the canvas error banner, or Editor > Canvas > Show Diagnostics), build log and file issues, then fix the cause in code or fixture instead of deleting the preview. Evidence: preview name, fixture, rendered snapshot, or the recorded failure and its fix. Storyboard scenes preview through their real scene, or use that reference's documented fallback when a faithful preview is impractical.

## Structure

Owners: [apple-platform-ui](../../apple-platform-ui/SKILL.md) for the view seam, [architecture decisions](../../agent-harness/references/architecture-decisions.md) for module boundaries.

- **Separation.** The view renders state and forwards intents; the ViewModel or presenter owns state transitions and calls injected services; networking and persistence sit below it. Business logic in a view body or controller, or UI framework types inside a ViewModel, is a finding when it blocks testing or reuse.
- **File size.** A file past about 1,000 lines, or a type that owns several unrelated responsibilities, needs a split plan by responsibility (subviews, child components, extensions, services). Ask for the split in this change only when the diff created or materially grew the problem; otherwise record a follow-up.
- **Refactor-friendly.** Dependencies arrive through initializers or the existing seam, not singletons reached from inside; no copied logic across screens; access control is as narrow as the callers allow.

## Logic and ViewModels

Owner of test evidence: [apple-platform-testing](../../apple-platform-testing/SKILL.md).

- **Inputs and outputs.** Inputs (user intents, lifecycle events) and outputs (state, navigation or one-off events) are separated through protocols or the project's established equivalent, such as `Input`/`Output` types, an action enum or a reducer. The view binds only to that surface.
- **Injectable dependencies.** Services, clocks, UUID sources and schedulers that affect results are injected, so a test can fix them.
- **Drivable with mocks.** A test or preview can build the ViewModel from fixtures and mock services and observe its outputs for the success, empty, failure and cancellation paths that apply. Evidence: the focused test, or the stated reason no test is needed.

## Networking

Owner: [network clients](../../agent-harness/references/architecture-decisions.md#network-clients).

- **Contract first.** The OpenAPI document (`openapi.yaml`, `.yml` or `.json` in the target) is added or updated in the same change, before or with the client code. Hand-written request and response models that duplicate the document are a finding.
- **Generated client.** Client code comes from Apple's [Swift OpenAPI Generator](https://github.com/apple/swift-openapi-generator): the `OpenAPIGenerator` build plugin generates it at build time, or the `generate-code-from-openapi` command plugin or CLI when generated sources must be committed, both configured by `openapi-generator-config.yaml` (or `.yml`). The app calls the generated `Client` through `OpenAPIRuntime` with `URLSessionTransport` from `swift-openapi-urlsession`, and consumers depend on the generated `APIProtocol` so a mock can simulate responses and failures.
- **Project precedence.** An accepted ADR or an established, documented client approach wins. Report an undocumented alternative instead of demanding migration.
- **Evidence.** The document diff, generator config, plugin or package wiring, a build that ran the generator, and a mock-driven test of a handled failure when behavior changed.

## Verification

- **Apple tooling.** The writer verified with Apple's tools where applicable: the Xcode MCP tools the selected Xcode exposes (for example `BuildProject`, `RenderPreview`, `XcodeRefreshCodeIssuesInFile`, `RunSomeTests`, `DocumentationSearch`; discover the callable set rather than assuming it) or an Apple-authored Xcode skill for the exact task, with host CLI fallback recorded per [xcodebuild](../../xcodebuild/SKILL.md) and [official-first routing](../../xcode-project-workflow/SKILL.md#apple-official-first-routing).
- **Evidence.** Tool or skill name, Xcode version, scheme or target, destination and result. A preview, build or test claim without that record is unverified, and a required gate that did not run blocks `approve`.

## Tests

Owner: [apple-platform-testing](../../apple-platform-testing/SKILL.md#choose-the-minimum-sufficient-evidence).

- Each added test protects logic that needs it: it names the observable contract and the failure it prevents, and covers the real edge cases (empty, boundary, failure, cancellation, ordering) or the reported regression.
- Flag construction-only tests (an initializer does not crash), tautological tests (asserting a mock's or fixture's own values, or restating the implementation), and tests that repeat one contract at unit, integration and UI layers. Recommend removing them rather than adding more.
- Missing coverage is a finding only with a named prevented failure.
