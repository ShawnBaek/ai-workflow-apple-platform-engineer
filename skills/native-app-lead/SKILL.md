---
name: native-app-lead
description: >-
  Routes broad or cross-cutting iOS, iPadOS, watchOS, and macOS work through the iOS-experts skill set. Use for an app idea, roadmap, architecture, task-to-PR delivery, “what next”, multi-model collaboration, or any request spanning several specialists. Loads the agent harness for guarded graph/loop execution, then selects only the focused skills required.
---

# Native App Lead

Locate the task, choose the smallest safe path, and hand each concern to its
owner. For task-to-PR, multi-agent, RAG, or resumable work, start with
`agent-harness`. Do not reimplement specialist guidance here.

## Mandatory gates

- Any Xcode project action starts with `xcode-project-workflow`.
- Any branch/index/worktree/commit/push/PR action routes through `git-workflow`.
- Signing/App Store actions load the private Apple account/team policy before
  account discovery.
- Broad work uses one writer lease and evidence-backed bounded attempts.
- Preserve an explicit model choice. Otherwise keep planning/architecture on a
  deep-capability lead and route only independently bounded mechanical work to
  a current cost-efficient model under `agent-harness/references/cost-and-usage.md`.
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
| CLI/skill/MCP/account/Spec Kit readiness | `apple-development-health` |
| project root/container, host Xcode, XcodeGen | `xcode-project-workflow` |
| branches, explicit worktrees, index locks, PR Git state | `git-workflow` |
| UI implementation without Figma | `apple-platform-ui` |
| Figma handoff | `figma-bridge` then `apple-platform-ui` |
| Core Data/SwiftData/CloudKit choice | `apple-data` |
| Core Data migration/concurrency detail | `core-data` |
| performance diagnosis | `apple-platform-performance` |
| app icon | `icon-composer` |
| Swift package resolution/cache | `swift-package-manager` |
| test selection, XCTest/XCUITest/xcresult | `apple-platform-testing` |
| build/run/debug/Simulator | `xcodebuild` |
| marketing/build number | `app-versioning` |
| Xcode/Simulator disk pressure | `xcode-storage` |
| visual/App Store evidence | `screenshot` |
| TestFlight/App Store/Xcode Cloud | `app-store-connect` |
| CI/CD | `cicd` |
| Issues/Projects board | `github-projects` |
| marketing site | `app-website` |
| staged-diff commit text | `commit-message` |

## Typical flow

1. Freeze acceptance criteria and affected tradeoffs.
2. Resolve authoritative repository/Xcode/account boundaries.
3. Plan only real dependencies, assign a justified model class per node, and
   parallelize frozen-snapshot read-only research.
4. Implement with one repository writer and scoped Apple resource leases.
5. Run the minimum checks justified by impact and risk.
6. Review a frozen patch, converge with bounded attempts, and preserve failures.
7. Prepare evidence, confirm repository, commit, push, create the PR, and wait
   for required checks when the task authorized those actions.
8. Stop at the selected authorized target: `pr_ready` by default, or the
   pre-authorized TestFlight uploaded/internal-distributed continuation. Merge,
   App Review/production release, signing-resource mutation, destructive
   cleanup, and scope expansion remain separate human gates.

## UI path

If a Figma file is the design source, use `figma-bridge` first. Otherwise use
`apple-platform-ui` directly. Ask only when the repository/request does not make
the source clear.

UI mocks are preview fixtures only. Acceptance for an existing application must
exercise the real package/persistence boundary required by the task, without
gratuitously rewriting that layer. The lead maps those integration points into
one acceptance flow and assigns the repository writer to connect them.

## Principles

- one next move for narrow questions; a graph only when dependencies justify it;
- current source and observable behavior over assumptions;
- minimum-sufficient tests, with omitted checks and residual risk recorded;
- a file/artifact existing is not proof that its acceptance criterion passed;
- no specialist duplication, blind retry, auto-worktree, auto-cleanup, unscoped
  auto-submit, force push, or auto-merge.
