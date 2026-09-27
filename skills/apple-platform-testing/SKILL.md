---
name: apple-platform-testing
description: Plan, structure and run minimum-sufficient Swift Testing, XCTest, XCUITest and E2E checks with deterministic launch scenarios and UI evidence. Use to choose, write or run tests, unblock system permission alerts in UI tests, or read xcresult failures. Not for builds (use xcodebuild).
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

Write no pointless tests: each added test names a unique observable contract and the failure it prevents, and exercises that logic's real edge cases or reported regression. Omit construction-only and tautological tests, such as asserting a mock's or fixture's own values. Avoid proving the same contract at unit, integration, and UI layers. Record omitted checks and residual risk in the handoff or PR. Read [test selection and evidence](references/test-selection-and-evidence.md) for the decision table and platform-specific proof.

When a node-specific Figma frame is the visual contract — the request names a Figma URL and asks for snapshot, golden, or design-parity tests — load `figma-golden-testing`; it owns the SwiftUI/UIKit capture recipe and the overlay/diff comparator. This skill keeps test selection, execution, and result reporting.

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

Read [UI and end-to-end test architecture](references/ui-test-architecture.md) before adding UI or E2E tests or the app code that prepares their launch. Test support sits behind one composition-root seam that Release does not compile; a named, strictly parsed scenario sets each launch's whole state; permission prompts never block a test that is not about them; and E2E tests stay limited to journeys across a real service boundary.

## Run and report

### Swift format and compile acceptance

A Swift change — app, framework, package manifest, tests, standalone scripts, or
snippets shipped in documentation — is complete only when the task's lines are
formatted with Apple's [swift-format](https://github.com/swiftlang/swift-format)
(`xcrun swift-format` from the selected Xcode), linted, and compiled with no
errors, without reformatting code the task did not change. An explicit project
policy that selects another formatter (for example a `.swiftformat` file, or a
format script, build phase or plugin that runs another tool) outranks this
default; record it. Choose and record one mode per file, treating each
documentation snippet as a file:

- **Whole file** (`format --in-place`) only when a `.swift-format` inside the
  repository applies (swift-format also uses one in `$HOME` or above the
  repository root; that does not count) and the file's base version was already
  conformant under it.
- **Changed ranges** otherwise: `format --in-place --lines <start>:<end>` per
  changed hunk against the task's base, with that project configuration or an
  inline `--configuration` JSON matching the file's indentation and line length.
- **Stop** when changed ranges cannot match the file's style, and propose
  adopting a project `.swift-format` or whole-file formatting as a separate change.

Lint with the same configuration against each modified file's base revision
(added files: empty baseline), comparing rule and message, not line numbers; any
new finding blocks like a task-introduced warning, even when reported outside the
task's lines.

Then compile: an app or framework target through build and warning acceptance
below; a package with `swift build`; a script with `xcrun swiftc -typecheck` for
the SDK and target it declares; and a documentation snippet, formatted under the
mode rule above, in a scratch file outside the project. `swift build` and an app
scheme's build leave test targets out, so changed test sources need their own
compile entry: `swift build --build-tests` or `swift test` for a package, and
for an Xcode test target `xcodebuild build-for-testing` with a scheme whose Test
action contains it, or an official Xcode test run that includes it. Any compile
error blocks completion. Format, lint and compile are one gate over the final
patch: any later source edit, including a fix for a compile error, lint finding
or warning, reruns all three. With Xcode's editor tools,
format after those edits are saved and confirm the build used the formatted file.
Record `xcodebuild -version` (Xcode's swift-format prints `main` for `--version`),
each file's resolved configuration and mode, new and baseline lint findings, and
each compile command or tool call with its result. Report `Format Unverified` when
swift-format could not run and `Build Failed` on a compile error, as separate
`swift-format` and `compile` checks. Read
[Swift format gate commands](references/swift-format-gate.md) for the verified
commands, snippet and Xcode-editor recipes, and report fields.

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
even when the command succeeds. Fix warnings introduced by the task, then rerun
the Swift format and compile gate above (format, lint, build) on the final patch.
Classify other warnings using available baseline evidence; if their origin is
unknown, report warning triage as pending and do not claim completion until
classified. Report remaining warnings with location,
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

Run tests on a reused destination and disable parallel-testing clones unless
the test plan requires them, as described in
[destination reuse](../xcodebuild/SKILL.md#choose-and-reuse-a-simulator-destination).

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
