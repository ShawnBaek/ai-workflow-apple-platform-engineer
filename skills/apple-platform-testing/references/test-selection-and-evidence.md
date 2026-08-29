# Test selection and evidence

## Decision table

| Change | Minimum evidence | Usually omit |
| --- | --- | --- |
| Documentation/configuration | targeted validator or parse check | app/unit/UI tests with no changed behavior |
| Local bug | one stable regression plus affected build | duplicate UI and integration coverage of the same assertion |
| Pure logic | changed decisions and meaningful limits | broad randomized or snapshot suites without risk justification |
| UI behavior | affected build, one critical flow, screenshot/video when requested | exhaustive device matrix unless layout/platform support changed |
| Persistence migration | representative prior data upgrade and clean install | every historic schema path without a supported-user risk |
| Network boundary | success and one changed/material failure | live-network flake tests when a deterministic seam exists |

Escalate scope when a shared core contract, release gate, or explicit request justifies it. Do not build test infrastructure larger than the product change unless that infrastructure is the requested deliverable.

Before adding a test, record three fields: `observable_contract`,
`prevented_failure`, and `unique_path`. If one is empty, or an existing test
already protects the same contract/path at a cheaper layer, do not add it.

For UI work, define the critical flow as the shortest deterministic launch-to-
outcome sequence. Use an existing stable UI test when available. When creating a
new UI-test harness would be materially larger than the change, a host-driven
manual run is acceptable only with fixed inputs, recorded steps, hierarchy or
accessibility checkpoints, and an independently observable final state. Record
the missing automated regression and residual risk; screenshots/videos remain
supporting visual evidence.

## Platform evidence

Use the platform affected by the changed experience: iPhone for iOS, an iPad destination for iPadOS layout/multitasking behavior, a watch destination for watchOS interaction, and a macOS destination for window/menu/keyboard behavior. Name the exact destination and OS/runtime actually used; do not claim coverage for another platform from a nearby simulator run.

For a visual PR artifact, preserve the captured file, its source command/test, and the flow it represents. Treat a screenshot as point-in-time UI evidence. A video can demonstrate a sequence but still needs deterministic steps and attached test result evidence.

## Handoff template

State: changed contract; each new test's three fields; tests/evidence run;
result; omitted checks and reason; residual risk; artifact or `.xcresult`
location. This makes a small test set reviewable rather than merely short.
