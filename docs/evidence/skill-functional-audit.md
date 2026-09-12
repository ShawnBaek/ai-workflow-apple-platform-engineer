# Functional skill audit

Audited **2026-09-05**, against the uncommitted candidate based on `06cf8f8`.
All **34 skill entry points** were assessed. This is a coverage inventory, not
a claim that all 34 completed an end-to-end task. The checks below separate
executed behavior, read-only prerequisites, instruction review and unavailable
integrations. No test issues, messages, purchases or releases were published.

The lead was named `native-app-lead` when this audit ran. Its current entry point
is [apple-platform-engineer](../../skills/apple-platform-engineer/SKILL.md); the
historical row below does not imply that the renamed installation was re-tested.

Environment: Apple silicon, macOS 27 beta, selected Xcode 27 beta, Swift 6.4,
macOS/iPhoneOS 27 SDKs; GitHub CLI 2.99.0 and ASC CLI 2.2.0. Compiler work was
serialized with `-j 1`; the global Xcode selection was unchanged. The optional
framework probes require newer SDKs than the Swift verifier itself.

## Executed evidence

- **Runtime:** the full suite was rerun: 64 XCTest cases and 11 Swift Testing
  cases passed. It includes real competing child processes, capacity/fencing,
  authorization denial/expiry/replay, bounded processes and image geometry.
  External-service responses in these tests are fixtures.
- **Images:** the [Swift generator](generate-comparison.swift) produced fresh
  inputs, then the real `apple-verify compare` command generated clean and
  annotated PNGs. Both were opened and visually inspected. The title/card
  measured **+3 pt x, +6 pt y**, with horizontal guides across the panels and
  repeated vertical reference guides. Reusing the output directory exited 2
  with an output-collision error and preserved the existing image hash.
  See the [images, manifest and measured report](README.md). These are synthetic
  fixtures, not live Figma exports or Simulator screenshots.
- **Frameworks:** the five [standalone Swift probes](framework-probes/README.md)
  were compiled and run on macOS. They performed a real SQLite v1-to-v2 Core
  Data migration, a SwiftData save/fetch, a direct App Intent `perform()`, deleted
  entity filtering, idempotent retry, typed tool bounds, and a missing-model
  rejection. They also ran Apple's Evaluations framework: its [native JSON
  result](framework-probes/evaluation-result.json) retains two passing cases and
  one deliberate failure, with mean `2/3`. That score tests evaluation plumbing,
  not model quality. The final probe sources also passed iPhoneOS typechecks at
  iOS 17 (persistence), 16 (App Intents), 26 (Foundation Models), 27 (Evaluations)
  and 17 (guarded model integration). These do not establish iOS execution.
- **Model availability:** the real system model returned `modelNotReady`.
  Guided schema construction and direct tool calls ran; model generation and
  model-selected tool calls did not. Core AI option/compute-unit discovery ran;
  no approved preconverted model was supplied for inference.
- **Delivery rendering:** Markdown, Telegram, WhatsApp and iMessage previews
  rendered successfully. Exact iMessage authorization preserved identical
  output bytes; a drifted report hash exited 2 with zero stdout. No transport
  sent a message. The [Markdown preview](delivery-preview.txt) preserves unknown
  usage and partial status instead of inventing success or cost.
- **Identity/retrieval:** executable SHA-256 and source-bundle identity matched
  independent CLI observations. A bounded local index included one allowed
  document, skipped one secret-bearing fixture, returned a fresh untrusted
  result, and rejected the query after source content changed. Restoring the
  original bytes restored freshness.
- **External prerequisites:** read-only `gh repo view` confirmed the public
  repository has Issues enabled; `gh issue list` returned no open issues.
  Live `gh pr create --help` exposed `--attach` and partial-upload behavior.
  ASC help exposed distinct Ads commands. Figma tools were exposed in the
  current client; no Xcode or 1Password MCP tools were exposed.
- **Resource observation:** one repeated compositor run took **0.05 s**, with
  maximum RSS **32,325,632 bytes** and zero swaps (`/usr/bin/time -l`). This is a
  single CLI observation, not an app optimization or before/after benchmark.

## Every skill and its boundary

| Skill | Evidence reached | Still unverified / next input |
|---|---|---|
| `agent-harness` | Swift runtime, real contention, authorization, identity and retrieval checks passed | Complete client task through live delivery, active-Xcode cancellation, aggregate resource use |
| `app-intents` | Compiled and directly executed intent; entity filtering and retry verified | Host app metadata extraction and invocation from Siri/Shortcuts |
| `app-store-connect` | Installed ASC version/help checked | Selected guarded account, app and authorized operation/readback |
| `app-versioning` | Source-authority workflow reviewed | Actual app/extension build settings and resulting bundle versions |
| `app-website` | Guidance reviewed; incorrect universal minimum-OS text fixed | Generate and exercise a real page, images, links, responsive layout and browser behavior |
| `apple-ads` | Installed Ads command surface checked without account queries | Selected ad account/app and authorized read or experiment; no spending tested |
| `apple-ai-evaluation` | Actual Apple Evaluations run and native JSON; intentional failure retained | Model-backed evaluation, judge calibration and model quality |
| `apple-data` | Local Core Data and SwiftData mechanisms executed | App-specific routing, entitled CloudKit sync/sharing and Web Services |
| `apple-development-health` | Swift aggregation/denial tests and live tool prerequisites checked | Fully populated private health profile and real high-risk adapter reconciliation |
| `apple-foundation-models` | Availability, generated schema and bounded typed tool executed | Generation blocked by `modelNotReady`; no model-quality claim |
| `apple-model-integration` | Core ML missing-model rejection and Core AI discovery executed | Approved converted artifact, reference outputs, inference and load/memory measurements |
| `apple-platform-performance` | Deployment-first triage reviewed; compositor resource sample measured | App hitch/launch/memory baseline, Instruments trace and equivalent after measurement |
| `apple-platform-testing` | Real Swift suite and focused framework probes ran | App XCTest/XCUITest, xcresult extraction and durable interaction regression |
| `apple-platform-ui` | SwiftUI/UIKit/storyboard/hybrid instructions reviewed | Actual rendered screen and integrated behavior in the selected app |
| `cicd` | Candidate workflow's Swift commands ran locally; permissions/timeouts/concurrency reviewed | GitHub macOS runner execution and published candidate checks |
| `code-review` | Independent migration findings, author dispositions and rechecks recorded | Published review comment/readback and reviewer-run Simulator edge case |
| `commit-message` | Actual staged migration diff/history inspected and message drafted | Creating a commit is outside this skill's draft-only outcome; approval remains pending |
| `core-data` | Real seeded SQLite migration and cross-context object-ID rehydration passed | App model resources, explicit/staged mapping and CloudKit mirroring |
| `core-simulator-health` | Discovery prerequisite cycle corrected in guidance | Actual bounded registry/device probe and recovery on a selected destination |
| `delivery-report` | Four previews, exact-byte authorization and hash-drift denial executed | Actual selected transport delivery and receipt |
| `figma-bridge` | Live tool roles checked; wrong read/write direction/setup corrected; compositor ran | Exact Figma file/node export, matching app state and actual design-to-app comparison |
| `git-workflow` | Live branch/remote/index/history inspected; no commit or push performed | Approved commit, push, PR and exact remote-head readback |
| `github-projects` | Real repository and issue reads succeeded | Selected Project v2 identity/fields and authorized Issue/Project mutation |
| `icon-composer` | Actual installed app launched through UI | First-run Apple license agreement blocked authoring; no `.icon` was created |
| `native-app-lead` | Routing and minimum-sufficient execution reviewed | Fresh-agent app intake through verified local outcome |
| `onepassword-environments` | Current tool inventory checked; required MCP tools absent | Official MCP connection, selected account/Environment and verified consumer |
| `screenshot` | Real clean/guide PNG generation, visual inspection and collision denial passed | App/Simulator capture, trimmed recording and viewable PR attachment |
| `skill-maintenance` | Three simulated reporting cases passed; real Figma defect investigated and guidance fixed locally | Live report publication, assigned issue repair, PR readback and installed-fix confirmation |
| `storekit-sandbox-testing` | Environment separation and bounded scenario guidance reviewed | Selected app/products/test environment; no payment or tester mutation performed |
| `swift-package-manager` | Actual dependency-free package built/tested with automatic resolution disabled | Consuming app dependency drift, Xcode package reuse and multi-task cache measurements |
| `xcode-preview-design` | Preview fixture/motion/evidence instructions reviewed | Actual Xcode canvas, UIKit/storyboard preview, interruption/reversal and Reduce Motion recording |
| `xcode-project-workflow` | Explicit repository/package path and per-command toolchain used; non-app gate clarified | Selected app container/session, project generation and app build |
| `xcode-storage` | Read-only disk, memory and task build-size observations completed | Itemized cleanup/reclaimed-space verification; no deletion performed |
| `xcodebuild` | Selected Xcode/Swift toolchain used for standalone compilation | App build/install/launch/debug and exact Simulator/device state |

## Corrections from the audit

1. Figma reading uses `get_design_context`; `generate_figma_design` writes live
   UI into a Figma file. Removed invented SwiftUI arguments and guaranteed
   native-code/size claims. Setup now uses the documented `/mcp` OAuth endpoint,
   supported client registration and provider-discovered schemas. Evidence:
   [Figma tool roles](https://developers.figma.com/docs/figma-mcp-server/tools-and-prompts/),
   [official setup](https://developers.figma.com/docs/figma-mcp-server/remote-server-installation/)
   and the actual exposed tools/installed Codex CLI help.
2. Screenshot publication now checks installed `gh --attach` support and reads
   back an uncertain partial upload before retrying. Evidence: installed
   `gh pr create --help`; no dry-run publication command was executed.
3. Core Data, performance and website guidance now takes minimum OS from the
   real app instead of assuming OS 26. Native macOS migration evidence is valid
   for that platform; it is not an iOS Simulator result.
4. Repository/package work no longer requires a nonexistent app container.
   Standalone Simulator discovery can establish a UUID before device work.
   Local completion and health instructions no longer imply a required PR or
   unrelated account probe. These are instruction-consistency fixes, not claims
   of a completed live app workflow.

## Reproduce and continue

Use [the runtime commands](../verification.md), the
[image reproduction instructions](README.md) and the five optional
[framework probes](framework-probes/README.md). Keep the
[workflow scenario plan](../workflow-test-plan.md) for evaluating agent decisions;
native API probes alone do not evaluate routing quality. No framework-probe
matrix is added to normal CI or required for a wording-only change.

To close the app gaps, select one small app and exact container/destination,
then perform Preview → integrated screen → aligned capture → one meaningful
interaction/edge case. Supply the exact Figma frame for its live comparison.
Choose the app's existing test support before adding XCUITest. Account/service
paths require their actual scoped prerequisites and separately authorized
writes. Icon Composer requires the user to review its pending license first.
