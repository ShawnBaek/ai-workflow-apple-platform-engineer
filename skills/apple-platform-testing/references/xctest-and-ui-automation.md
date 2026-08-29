# XCTest and UI automation practice

## Test type

Use Swift Testing for new, focused unit-level tests when supported by the project and toolchain. Use XCTest for existing XCTest suites, UI automation, performance metrics, and cases needing its integration. Keep an existing suite's conventions unless the task explicitly includes migration.

## Accessibility tree and selector contract

XCUITest discovers app UI through the accessibility tree. That does not make an
accessibility label the default automation key. For app-owned controls and
navigation, prefer a stable, unique, nonlocalized `accessibilityIdentifier` and
scope the query by semantic element type or container. Keep identifiers in
production-like builds, treat them as a test-facing API, and never derive them
from localized text, array position, personal data, or volatile content.

An identifier is not a substitute for `accessibilityLabel`, value, traits,
actions, grouping, focus order, or hit behavior. Keep those user-facing
semantics correct for VoiceOver and other assistive technologies. Do not change
a label only to make a test pass. When wording, localization, selected value, or
another accessibility semantic is the acceptance criterion, query the element
by identifier and assert its label/value/traits in the selected locale. A
localized label selector is acceptable only when that visible/accessibility text
is the contract or an unowned system surface exposes no stable identifier;
scope it narrowly and record the locale-dependent risk.

```swift
// App code
Button("Save") { save() }
    .accessibilityIdentifier("settings.save")

// UI test: stable navigation, then a user-facing accessibility assertion.
let saveButton = app.buttons["settings.save"]
XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
XCTAssertEqual(saveButton.label, expectedLocalizedSaveLabel)
```

For repeated content, use a stable fixture/domain ID without PII and keep the
semantic element unique inside its screen/container. Duplicate or missing IDs
block the selector contract; do not fall through silently to coordinates. Seed
deterministic state through an approved launch argument, environment variable,
fixture, or dependency seam. Wait explicitly for the expected element or state;
do not use time-based sleeps as synchronization. Use hierarchy inspection before
any documented coordinate fallback.

Keep the test focused on the changed user contract. Prefer an assertion on the visible outcome over implementation details, and avoid recording-based selectors without reviewing and stabilizing them.

## Gesture contracts

For a detented sheet, slider, scrubber, reorder handle, or other continuous
control, exercise one uninterrupted touch-down, held move, and touch-up gesture.
Start from the current hierarchy-derived hit region, cross the actual threshold,
wait for animation completion, then recapture and assert the changed frame or
state. A tap followed by a swipe, a command exit, or an outer-container-only
assertion does not prove the recognizer handled the intended gesture. Reverse
gestures must use the element's new coordinates rather than stale ones.

If an official host interaction grammar does not expose pinch, do not invent an
undocumented command or occupy the device session while searching for one. Use
an enabled XCUITest target and call
`XCUIElement.pinch(withScale:velocity:)` on the visible zoom surface. Confirm the
UI test target is included in the active scheme/test plan and that the named test
actually executed. Build success or a compiled test method is
not pinch runtime evidence; report it as unrun when the target is excluded.

## Build reuse and results

`test-without-building` is valid only after `build-for-testing` for the identical project/container, scheme, destination, configuration, toolchain, and test selection. Any change to that tuple requires a fresh build-for-testing.

When a run fails, retain the raw `.xcresult`, extract a concise summary with the supported Xcode result tooling, and lead with the first actionable failure. Treat sandbox/CoreSimulator permission failures as host-environment problems, not failing application tests.
