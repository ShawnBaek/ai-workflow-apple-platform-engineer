---
name: apple-platform-engineer
description: >-
  Coordinates Apple-platform work from a clarified product outcome through design, implementation, focused verification, and reviewable delivery. Use for an app idea, cross-cutting feature, roadmap, architecture, or task-to-PR request. Selects only the specialists and orchestration needed by the task.
---

# Apple Platform Engineer

Locate the task, choose the smallest safe path, and hand each concern to its
owner. For task-to-PR, multi-agent, RAG, or resumable work, start with
`agent-harness`. Do not reimplement specialist guidance here.

The entry skill is `apple-platform-engineer`: use `$apple-platform-engineer` in
Codex or `/apple-platform-engineer` in Claude Code. It replaces `native-app-lead`.
A skill is guidance, not a permanent agent.

For several assigned tasks, follow [batch delegation](../agent-harness/references/collaboration.md#delegate-a-batch-of-tasks): establish dependencies, effective worker slots and [workspace boundaries](../agent-harness/references/task-workspaces.md), launch only ready independent work, queue the rest, and retain one repository writer. Report actual worker IDs and completed evidence rather than treating a task list as running agents.

## Understand the task first

Use the shared [task intake](../agent-harness/references/task-intake.md): establish
what the user wants to build, meaningful constraints, and observable acceptance.
Reuse prior answers, ask only about material ambiguity, and proceed when the
request is clear. Read relevant [ADRs](../agent-harness/references/architecture-decisions.md)
before architecture and task breakdown. Routine work does not need a new ADR.

## Mandatory gates

- Any Xcode project action starts with `xcode-project-workflow`.
- Any branch/index/worktree/commit/push/PR action routes through `git-workflow`.
- If no explicit repository or opened Xcode container identifies the target,
  `agent-harness` may use its optional private project registry to return
  validated candidates. Ambiguity remains a human selection gate.
- Signing/App Store actions load the private Apple account/team policy before
  account discovery.
- Broad work uses one writer lease and evidence-backed bounded attempts.
- Preserve an explicit model choice. Otherwise use the [shared model policy](../agent-harness/references/cost-and-usage.md):
  efficient models for bounded mechanical work, balanced models for routine
  implementation/review, and stronger reasoning for demonstrated risk or ambiguity.
  Lead and reviewer roles do not automatically require the highest model.
- For cross-layer features, the repository writer owns final integration across
  UI, package, persistence, and navigation boundaries. Specialists advise or
  change their layer; none may declare the feature complete from an isolated
  mock or preview.
- Use an Apple-authored skill/tool when it already owns the exact task; this
  collection supplies coordination, project policy, and missing specialist
  workflows rather than duplicated Apple skill bodies.

## Routing map

| Need | Skill |
|---|---|
| graph/loop/RAG, Codex/Claude collaboration, task-to-PR | `agent-harness` |
| first-run dependency setup, configuration or update | `apple-platform-setup` |
| current CLI/skill/MCP/account/Spec Kit readiness | `apple-development-health` |
| 1Password development ENV connection, secrets, or local mounts | `onepassword-environments` |
| project root/container, host Xcode, XcodeGen | `xcode-project-workflow` |
| branches, explicit worktrees, index locks, PR Git state | `git-workflow` |
| UI implementation without Figma | `apple-platform-ui` |
| new UI or substantial redesign without a design-tool reference | `xcode-preview-design`, then `apple-platform-ui` for the bounded view implementation |
| Figma handoff | `figma-bridge` then `apple-platform-ui`; add `xcode-preview-design` when requested |
| Core Data/SwiftData/CloudKit choice | `apple-data` |
| Core Data migration/concurrency detail | `core-data` |
| performance diagnosis | `apple-platform-performance` |
| Foundation Models and agentic app features | `apple-foundation-models` |
| probabilistic AI quality, prompt/model evaluation | `apple-ai-evaluation` |
| custom Core AI/Core ML/MLX model integration | `apple-model-integration` |
| App Intents, entities, Shortcuts and Siri integration | `app-intents` |
| independent review, review comments and author response | `code-review` |
| report, investigate or fix a problem in this skill collection | `skill-maintenance` |
| app icon | `icon-composer` |
| Swift package resolution/cache | `swift-package-manager` |
| test selection, XCTest/XCUITest/xcresult | `apple-platform-testing` |
| build/run/debug/Simulator | `xcodebuild` |
| marketing/build number | `app-versioning` |
| Apple Ads campaigns, paid keywords, supporting ASO checks, bids, budgets, and reporting | `apple-ads` |
| StoreKit local/sandbox/TestFlight purchase testing | `storekit-sandbox-testing` |
| Xcode/Simulator disk pressure | `xcode-storage` |
| visual acceptance and PR media evidence | `screenshot` |
| App Store screenshots/previews from the target build | `app-store-screenshots` |
| completion summary or private message delivery | `delivery-report` |
| TestFlight/App Store/Xcode Cloud | `app-store-connect` |
| CI/CD | `cicd` |
| Issues/Projects board | `github-projects` |
| marketing site | `app-website` |
| staged-diff commit text | `commit-message` |

## Typical flow

1. Clarify the user outcome, acceptance criteria, and affected tradeoffs.
2. Resolve authoritative repository/Xcode/account boundaries.
3. Read applicable ADRs and record significant new decisions. Use a simple plan
   by default; add graph structure only when actual dependencies justify it.
   Split broad work into coherent reviewable PRs. Assign justified model classes
   and parallelize independent frozen-snapshot research when useful and authorized.
4. Implement with one repository writer and scoped Apple resource leases.
5. Run the minimum checks justified by impact and risk.
6. Use `code-review` for an independent view of the frozen patch, assess findings
   against sources and behavior, and verify accepted fixes within bounded attempts.
7. Prepare evidence, confirm repository, commit, push, create the PR, wait for
   required checks, and route the completion summary to `delivery-report` when
   the task authorized those actions.
8. Stop at the selected authorized target: `local_verified` for local work, `pr_ready` for a PR request, or the
   pre-authorized TestFlight uploaded/internal-distributed continuation. Merge,
   App Review/production release, signing-resource mutation, destructive
   cleanup, and scope expansion remain separate human gates.

## UI path

If a Figma file is the design source, use `figma-bridge` first. New UI design
without an external reference starts with
`xcode-preview-design`, which gives only the bounded production view change to
`apple-platform-ui` and then resumes its deterministic matrix, canvas review,
human feedback, and motion contract. Ask only when the repository/request does
not make the source clear.

Design the actual SwiftUI/UIKit presentation before new domain logic. Preserve
the affected feature's storyboard/XIB, programmatic, or hybrid construction;
load its real scene/nib for preview when appropriate. A small logic fix does not
need a design phase. Compare the accepted preview or Figma state with the
integrated app through `screenshot`'s comparison guidance.

UI mocks are preview fixtures only. Prefer a value fixture; add a narrow protocol
mock only when the interaction requires one. Acceptance for an existing
application must exercise the real package/persistence boundary required by the
task, without gratuitously rewriting that layer. The lead maps those integration
points into one acceptance flow and assigns the repository writer to connect
them.

## Principles

- one next move for narrow questions; a graph only when dependencies justify it;
- current source and observable behavior over assumptions;
- minimum-sufficient tests, with omitted checks and residual risk recorded;
- a file/artifact existing is not proof that its acceptance criterion passed;
- no specialist duplication, blind retry, auto-worktree, auto-cleanup, unscoped
  auto-submit, force push, or auto-merge.
