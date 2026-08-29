# XCTest and UI automation practice

## Test type

Use Swift Testing for new, focused unit-level tests when supported by the project and toolchain. Use XCTest for existing XCTest suites, UI automation, performance metrics, and cases needing its integration. Keep an existing suite's conventions unless the task explicitly includes migration.

## UI contracts

Assign a stable, unique accessibility identifier to each UI element the test must address. Select by identifier, not visible or localized text. Seed deterministic state through an approved launch argument, environment variable, fixture, or dependency seam. Wait explicitly for the expected element or state; do not use time-based sleeps as synchronization.

Keep the test focused on the changed user contract. Prefer an assertion on the visible outcome over implementation details, and avoid recording-based selectors without reviewing and stabilizing them.

## Build reuse and results

`test-without-building` is valid only after `build-for-testing` for the identical project/container, scheme, destination, configuration, toolchain, and test selection. Any change to that tuple requires a fresh build-for-testing.

When a run fails, retain the raw `.xcresult`, extract a concise summary with the supported Xcode result tooling, and lead with the first actionable failure. Treat sandbox/CoreSimulator permission failures as host-environment problems, not failing application tests.
