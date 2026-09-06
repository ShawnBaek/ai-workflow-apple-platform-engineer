# Workflow test plan

Verify both the Swift runtime and the decisions an agent makes with these skills. Passing parser, schema or lease tests does not prove that a user task reaches the right outcome. This plan selects a few representative scenarios; it is not a requirement to run every skill, model or device on every PR.

## Select the checks

- **Documentation-only edit:** inspect the change and run the repository validator.
- **Routing or workflow change:** add the relevant scenario below and its closest confusing case. For a fix, replay the reported failure before and after the change.
- **Runtime or shared contract change:** run the relevant Swift regression and the full Swift package/repository checks. Keep actual contention, denial, expiry and replay coverage when those boundaries change.
- **Release or broad workflow change:** evaluate the affected end-to-end path as well as its components. Record any unexecuted integration explicitly; a simulated publication is not live delivery proof.

Use the commands in [verification](verification.md). CI runs the Swift suite and repository validator; agent walkthroughs and live app scenarios require separate evidence.

## Scenario matrix

Each row describes a repeatable test, its observable pass condition and the evidence currently available. **Planned** means the scenario is defined but has not been executed. **Partial** names the narrower observation we have.

| Scenario and input | Pass condition and smallest proof | Current coverage |
|---|---|---|
| **Intake and proportionality:** a precise README typo; then an ambiguous saved-items feature request | Fix the typo without a new ADR, graph, delegate or UI harness. For the feature, resolve material behavior/minimum-OS uncertainty before dependent implementation; reuse supplied answers and split only coherent deliverables. Keep the task brief and selected steps. | Planned agent evaluation. The reporting walkthrough discusses overtesting but did not execute a README task. |
| **Competitors and design direction:** a new screen with missing references/style; a supplied product/style brief; then a precise visual fix | Ask only the missing material questions. Research the selected app/service using cited observations, distinguish inference and unavailable behavior, and carry the same direction into design. Reuse supplied answers, respect approved Figma/brand choices, and skip a style interview for the precise fix. | Partial: [synthetic intake walkthrough](evidence/design-discovery-walkthrough.md) exercised missing/supplied preferences, precise fixes and website typography/motion. Initial failures and corrections are retained; no live competitor-app or rendered-design evaluation. |
| **Concurrent tasks and recovery:** two tasks request the same checkout or destination; repeat with different resources exceeding the shared budget | Exactly one conflicting acquisition succeeds; the caller queues excess work without extra capacity. Stale ownership cannot write. Cancellation stops owned work and releases resources after it stops; unrelated processes and caches remain untouched. Keep receipts, process outcomes and bounded resource observations. | Partial: real child-process contention, capacity, fencing and recovery tests passed in `ResourcePortTests.swift`. A [five-request probe and planning walkthrough](evidence/update-and-delegation-check.md) exercised caller-driven retry and client-slot decisions. Multi-agent app execution, cancellation under a running Xcode build, peak memory and disk reuse remain unmeasured. |
| **Design, compatibility and construction:** a small reference-guided screen; repeat without a design tool; use a storyboard-hosted variant | Use SwiftUI/UIKit Preview with fixed states before domain logic. Preserve the actual storyboard/XIB/code/hybrid path and verify outlet/action wiring. Respect minimum OS and selected SDK. Capture aligned clean/annotated images with horizontal and vertical guides; verify meaningful empty/error/content states. | Partial: synthetic image geometry and signed offsets passed. No real Figma-to-app, Preview or storyboard scenario has been run for this change. |
| **Workspace boundaries:** five investigations without per-child permission controls; then two approved, sandboxed worktrees of the same repository | Record actual access and task-owned outputs, preserve app structure, and resolve unavailable restrictions before dispatch. Approved worktrees retain the repository writer conflict. Keep permission observations and writer/verification handoffs. | Partial: [workspace audit and planning checks](evidence/update-and-delegation-check.md#workspace-and-permission-audit) confirmed source/policy consistency and serialized worktree writers. The no-controls planning case remained ambiguous after clarification and recheck; actual sandbox denial, worktree lifecycle and app execution were not tested. |
| **Interaction and performance:** interrupt/reverse one changed animation, enable Reduce Motion, then reproduce a reported hitch | A short recording shows the behavior and relevant edge case. Compare before/after with the same device, build configuration and input for an agreed metric; do not infer speed from a screenshot. Use a focused test only for a durable regression. | Planned app evaluation; no animation, device-performance or memory improvement claim. |
| **Review and PR delivery:** a small known logic defect plus an unsupported review claim; prepare a dependent two-slice change | Independent review cites the defect's source/reproduction. Author accepts and verifies the valid finding, disputes or requests evidence for the unsupported claim, and returns changed evidence for re-review. Each PR uses its actual base, short template and viewable proof. No automatic merge or duplicate publication. | Partial: [independent migration review and author response](evidence/review-record.md) completed locally. Live review-comment publication, two-PR delivery and readback have not been exercised. |
| **Completion handoff:** verified interaction, inspected PNG/MP4 and local no-findings review; user requested PR and posted review; repeat as local-only and with busy build capacity | Reuse settled intake/destination facts, ask only for missing immediate commit approval, then carry authorized publication through viewable proof, posted review and readback. Local-only stays local; busy capacity queues only dependent work. | Partial: [fresh-agent baseline/candidate walkthrough](evidence/workflow-handoff-check.md) caught an omitted review in the baseline and exercised all three candidate decisions. No live app delivery or timing improvement claimed. |
| **Report, investigate and fix:** explicitly report a collection defect from a private app; contrast an app-only bug; replay an uncertain create response; then assign the report for repair | Sanitize the report, target the collection and reuse matching issues. Reproduce the assigned defect, make a focused correction, demonstrate before/after and review the linked PR. Keep local, submitted, merged and available-to-installed-users states distinct. | Partial: [three simulated reporting cases](evidence/maintenance-walkthrough.md) passed. Assigned-issue-to-fix execution and live issue/PR delivery remain planned. |
| **Installation and local completion:** selected skills in a clean temporary client profile; a local-only fix; then a stale installed copy | Discover the intended skill/version without duplicate routing. Run only selected dependencies. Complete local acceptance without inventing a PR; detect source/runtime drift and require explicit migration where applicable. Keep observed paths/version hashes and the local outcome. | Partial: installed-source drift, local health and local completion contract tests passed. A fresh client installation and full agent local-fix run have not been exercised. |

The runtime tests are in [AppleVerificationCoreTests](../skills/agent-harness/verification/Tests/AppleVerificationCoreTests). Their synthetic records and injected service responses test enforced contracts, not real GitHub, Apple-account or Simulator integrations.

## Run an agent scenario

1. Freeze the candidate skill/source revision and a small fixture. Record the actually loaded skill path/hash, client, model/effort when observable, relevant toolchain and task limits. Unknown values remain unknown. Use a temporary task-owned test location; do not replace the user's active skill installation.
2. Give a fresh agent the realistic request and raw inputs. Keep the expected decisions in the evaluator's rubric, outside the agent's prompt. Let the agent select the route for routing tests; name the skill only when testing its internal workflow. Start with a lightweight model for a bounded simple case, respecting any explicit model choice.
3. Observe actions, source diff and artifacts, not just the final explanation. For a regression, use the same fixture against the old and candidate versions; preserve the failing baseline. For new behavior, record that there is no prior baseline. A deliberate defective fixture must be isolated from shipped code.
4. Evaluate each pass condition and the closest route that should behave differently. One targeted follow-up may investigate a failure; do not retry until a green outcome hides earlier failures. Record all attempts. Broaden the model/device matrix only for a demonstrated variability or compatibility concern.
5. Keep a short result linked from the PR. Use `passed`, `failed`, `blocked` or `not_run`, with the exact scope and supporting artifact. A reviewer checks the observation and any accepted fix. Changed inputs invalidate the affected result.

For GitHub scenarios, use explicit fixture responses or an authorized test repository and account. Record whether tool calls were simulated, intercepted or actually executed. A prose instruction saying “do not publish” is not a mock transport: retain human control over write tools unless the environment actually disables them. This collection's public issue tracker is not a test sandbox.

For app scenarios, select an authorized sample/app and exact Xcode container/destination; follow existing ownership and signing guards. Reuse the app's test support. Prefer previews, focused Swift tests and a short manual Simulator flow; add XCUITest only when a repeatable interaction regression justifies its maintenance cost. Custom fixture/verification helpers use Swift.

## Check the evaluation itself

Apply these controls to the affected scenario, not every documentation edit.
The [engineering source comparison](research-notes.md) explains their origin and
the larger systems we deliberately did not adopt.

- **Verifier sensitivity:** when changing a checker, pair a valid fixture with one deliberate defect, such as stale evidence or a missing required outcome. Confirm the defect fails for the intended reason before verifying its correction. A build error or unavailable service is not evidence that the checker detected the target defect. Existing Swift negative cases may supply this proof; no mutation-testing framework is needed.
- **Representative cases:** turn sanitized reported failures into regression cases. Keep tuning examples separate from held-out acceptance cases, and record fixture/rubric revisions. Human-check a small sample of model-judged results; disagreement needs investigation rather than averaging away. Treat thresholds as task decisions, not borrowed company percentages.
- **Actions and final outcome:** inspect required tool arguments, authority and dependency order, plus the final artifact/state. Allow equivalent correct paths. Include a case where the final prose sounds successful but the required action is absent; it must fail the evaluation. This agent-level control is planned, not covered by the three reporting walkthroughs.
- **Failures remain evidence:** classify product, instruction, checker and environment failures separately. Preserve the first failure and all bounded attempts. A later pass does not erase flakiness; changing the test, filter or expected result requires an explanation and review. A newly blocking UI test needs a small predeclared repeat check when timing stability is uncertain, not an always-on repeated device matrix.

## Keep the result small

Use an existing evidence note or JSON artifact with these fields; no new runner or result schema is required:

```text
Scenario / candidate revision / loaded skill identity:
Client and effective model / relevant toolchain and destination:
Input fixture / baseline result / candidate result:
Observed actions and acceptance evidence:
Publication mode: simulated | intercepted | live | none
Elapsed time / peak memory / disk delta / provider usage: measured values or unknown
Status: passed | failed | blocked | not_run
Unverified scope and next check:
```

Measure resource changes only for a resource/performance task. Compare equivalent inputs and separate cache warm-up or toolchain differences. Do not add profiling overhead to every documentation evaluation or estimate unavailable model usage.

For model or workflow comparisons, use the
[outcome-based cost policy](../skills/agent-harness/references/cost-and-usage.md).
Report the attempted-task denominator and compare the same fixture set. Tiny
samples are case results, not a stable success rate or a reason to change default
routing.

## Current verification boundary

The [recorded result](evidence/verification.json) contains **75 passing Swift tests** and **three passing simulated reporting scenarios**. Repository validation also passed. Those results support their stated scopes; they do not establish an end-to-end agent success rate.

The subsequent [34-skill functional audit](evidence/skill-functional-audit.md)
also ran the comparison CLI, five native Swift framework probes, report
rendering/authorization and fresh/stale retrieval cases. It records each skill's
executed layer and remaining integration gap. These component results do not
replace the planned app and agent scenarios above.

The first integration priorities are one local task through actual verification, one reported defect through reproduction/fix/re-review, and one authorized PR delivery with artifact readback. Add the real Preview/Simulator path when validating UI guidance. Until these runs exist, describe their coverage as planned rather than calling the entire workflow end-to-end verified. Published CI status must be read from the actual PR checks.
