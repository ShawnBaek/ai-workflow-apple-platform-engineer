---
name: apple-platform-testing
description: Plan and run minimum-sufficient iOS, iPadOS, watchOS, and macOS tests with deterministic UI evidence and actionable Xcode results.
---

# Apple Platform Testing

Use this skill when selecting, implementing, or running tests for iOS, iPadOS, watchOS, or macOS. Start with the product risk and changed contract, then choose the smallest evidence that makes the change credible. Prefer Apple/Xcode testing tools and documentation; do not vendor Apple-built-in skill content.

## Choose the minimum sufficient evidence

- Documentation or configuration-only changes: run the relevant validator; do not create app tests without a behavioral change.
- Bug fix: add one regression test that reproduces the defect when it is practical and stable.
- Pure logic: cover changed branches and material boundary cases.
- UI-visible behavior: build the affected target, exercise one critical flow, and capture requested visual evidence on the relevant platform.
- Migration: cover a representative old-to-new store and a clean install; do not fabricate a full historical-migration matrix.
- Network/integration: cover success plus a material handled failure when it changed.

Avoid proving the same contract at unit, integration, and UI layers. Record omitted checks and residual risk in the handoff or PR. Read [test selection and evidence](references/test-selection-and-evidence.md) for the decision table and platform-specific proof.

A critical flow is the shortest deterministic sequence from the nearest
prepared scenario state to the changed observable outcome. Include Home, icon
tap, launch, or first-run setup only when launch/startup behavior is the changed
contract. Prefer an existing stable XCUITest. If no UI harness exists and adding
one would exceed the feature risk, run a recorded host-driven manual flow with a
fixed fixture/state, hierarchy or accessibility checkpoints, and a final
observable state assertion; state explicitly that no automated UI regression
was added. A screenshot alone is not that assertion. Route QA screenshots,
recordings, trimming, and publication checks to `screenshot`.

## Implement deterministic tests

Use Swift Testing for new focused unit tests where it fits the project; retain
XCTest when existing conventions or Xcode integration require it. Use
XCTest/XCUIAutomation for UI and performance work. UI tests need deterministic
launch arguments/environment/fixtures and explicit condition or existence
waits—never arbitrary sleeps. Prefer stable accessibility identifiers for
app-owned automation paths; use label/value/traits when those accessibility
semantics are themselves the contract, not as a fragile substitute for an
identifier.

Read [XCTest and UI automation practice](references/xctest-and-ui-automation.md) before changing UI/performance tests or interpreting results.

## Run and report

Never run Xcode, simulator, device, signing, or related commands from a sandboxed process. Use the authorized host environment and repository project-root rules. For the same scheme, destination, configuration, and test selection, `build-for-testing` once may be followed by `test-without-building`; otherwise rebuild.

Preserve the `.xcresult` and report toolchain, project/container, scheme, destination, command, test selection, attachments, and the first actionable failure. A platform-appropriate screenshot or video proves a UI flow; it does not replace functional test evidence.

## Sources

- [Apple: XCTest](https://developer.apple.com/documentation/xctest)
- [Apple: recording UI automation](https://developer.apple.com/documentation/XCUIAutomation/recording-ui-automation-for-testing)
- [Apple: waiting for element existence](https://developer.apple.com/documentation/xcuiautomation/xcuielement/waitforexistence%28timeout%3A%29)
- [Apple: accessibility identifiers](https://developer.apple.com/documentation/uikit/uiaccessibilityidentification/accessibilityidentifier)
- [Apple: XCUIElement identifier](https://developer.apple.com/documentation/xcuiautomation/xcuielementattributes/identifier)
