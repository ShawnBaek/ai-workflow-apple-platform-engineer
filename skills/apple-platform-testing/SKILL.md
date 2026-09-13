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

### Build and warning acceptance

For app source, resources, dependencies, or build-setting changes, completion
requires a successful build of the affected integrated app target from the final
patch in the authoritative project/workspace. Use the `xcodebuild` skill to
select an authorized official Xcode build tool.
Record the patch identity, Xcode/SDK, scheme, configuration, destination, actual
build result and log or result-bundle location. A package-only check, preview,
snapshot, editor diagnostics, or an earlier revision's build does not establish
that the final app compiles. Reuse matching build evidence; rebuild after changes
that invalidate it. Documentation-only work needs its relevant validator.

Inspect compiler, asset, linker, and build-script warnings in the build evidence,
even when the command succeeds. Fix warnings introduced by the task and rerun
the affected build. Classify other warnings using available baseline evidence;
if their origin is unknown, report warning triage as pending and do not claim
completion until classified. Report remaining warnings with location,
reason and disposition. Do not suppress diagnostics, weaken concurrency checks,
or remove warning-producing functionality merely to obtain a clean result.
Unresolved task-introduced warnings block completion; pre-existing warnings may
remain when outside scope, but must be disclosed and never called warning-free.

“I will test it” delegates manual acceptance; it does not waive compilation or
warning review. Respect an explicit instruction not to build or an execution
blocker, and report `Build Unverified` with the reason instead of complete or
ready for testing. A failed build is `Build Failed`. A passing build with manual
acceptance outstanding is implementation verified with manual QA pending, not
proof that the feature works. Keep build, warning review, automated tests and
manual QA as separate reported outcomes.

Use the authorized host environment and repository project-root rules for Xcode,
Simulator, device, and signing operations. Reuse `build-for-testing` products
with `test-without-building` when source/dependency identity, toolchain, scheme,
configuration, destination compatibility, and built test targets still match.
Changing an `-only-testing` filter to a test already present in those products
does not itself require another build. Rebuild when a required target was not
built or a compatibility input changed.

Write repository-owned verification in Swift (Foundation, Swift Testing,
XCTest, ImageIO, CoreGraphics, or AVFoundation as appropriate). Apple tools such
as `xcodebuild`, `simctl`, `xcresulttool`, and Instruments remain the execution
surface. Do not add a Python or Node helper for parsing or evidence composition.
Third-party tool internals are not a claim that the entire toolchain is Swift.

Preserve the `.xcresult` and report toolchain, project/container, scheme, destination, command, test selection, attachments, and the first actionable failure. A platform-appropriate screenshot or video proves a UI flow; it does not replace functional test evidence.

## Sources

- [Apple: XCTest](https://developer.apple.com/documentation/xctest)
- [Apple: recording UI automation](https://developer.apple.com/documentation/XCUIAutomation/recording-ui-automation-for-testing)
- [Apple: waiting for element existence](https://developer.apple.com/documentation/xcuiautomation/xcuielement/waitforexistence%28timeout%3A%29)
- [Apple: accessibility identifiers](https://developer.apple.com/documentation/uikit/uiaccessibilityidentification/accessibilityidentifier)
- [Apple: XCUIElement identifier](https://developer.apple.com/documentation/xcuiautomation/xcuielementattributes/identifier)
