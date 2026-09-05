# Update and delegation checks

Reviewed on 2026-09-06 against source commit
`296bf446d0a5ecc4ce2fad008b950bf2c6997682`, plus the documentation changes in this
documentation phase. The preceding runtime repair is verified separately in
[its regression record](local-runtime-repair.json). These update/delegation
probes did not change host policy, client settings or active installations.

## Update instructions

The inspected Skills CLI 1.5.18 implementation supports named updates and
global/project scope, but an independent review found that `updateGlobalSkills`
and `updateProjectSkills` omit the original agent/method options when calling
`add`. Its noninteractive path selects detected clients and derives a default
installation mode. The original update example could therefore broaden the
installation; it was replaced with an explicitly targeted staged-copy example.
`add --agent ... --copy` writes only selected client destinations. Symlink mode
also updates shared canonical content, affecting other clients linked there.

Its `check` command invokes the updater too; it is not a read-only preflight.
These conclusions come from package 1.5.18's `dist/cli.mjs`, checked without
running an installer or update. The [upstream reference](https://github.com/vercel-labs/skills#available-options)
describes the explicit `add` options. Actual replacement and rollback remain
unexecuted; this collection has no general bundle updater.

## Five resource requests

A temporary Swift probe linked the existing `AppleVerificationCore` object and
started five subprocesses per phase with five distinct synthetic run IDs.
It used isolated coordinator state and fixture authorities. No private runtime
binding, repository mutation, GitHub request, Xcode build or Simulator was used.

| Phase | Initial result | Explicit caller retry after each release | Final state |
|---|---|---|---|
| Five requests for the same repository writer | One admitted; four `resource_conflict` | All five admitted and released in total; fencing tokens 1–5 | Zero active leases and zero capacity in use |
| Five different repository requests, each explicitly claiming one synthetic heavy-job slot | One admitted; four `capacity_exceeded` | All five admitted and released in total; fencing tokens 1–5 | Zero active leases and zero capacity in use |

These observations extend the existing two-process cases in
[ResourcePortTests.swift](../../skills/agent-harness/verification/Tests/AppleVerificationCoreTests/ResourcePortTests.swift).
The probe's caller controlled retries: it did not demonstrate a built-in waiter
queue, fairness, cancellation recovery, five live agents or real build capacity.

## Five-assignment planning walkthrough

Two fresh Codex subagent attempts used GPT-5.6 Luna at medium reasoning. Input:
five read-only City Commuter assignments (route choice, storyboard wiring,
offline states, test plan and VoiceOver), followed by justified integration;
four total client slots including the lead; three free child slots; host limits
of one heavy job, one destination and two internal workers.

- **First attempt: failed.** It confused `internal_workers=2` with the number of
  LLM subagents and proposed fixed 2/2/1 waves. It did retain one integration
  writer and avoided inventing completed work. The owning resource/delegation
  guides were clarified to distinguish local-tool capacity from agent slots.
- **Recheck: passed within planning scope.** It planned three initial workers,
  two pending tasks, immediate refill of freed slots and one integration writer.
  It did not claim worker IDs or completions before dispatch.

No City Commuter project or live application was inspected. The walkthrough
does not prove dispatch, end-to-end task completion or five-way execution.
The current client slot limit and repository-level ownership rule remain the
actual limits; worktrees alone do not change them.

## Workspace and permission audit

The added [workspace guide](../../skills/agent-harness/references/task-workspaces.md)
was checked against Git/Xcode policy and the Swift enforcement source:

- [ResourceCoordinator](../../skills/agent-harness/verification/Sources/AppleVerificationCore/ResourceCoordinator.swift) serializes same-repository writers
  across checkout paths. Its path-overlap checks do not provide complete
  symlink isolation; callers must supply pre-resolved paths.
- [ProjectResolver](../../skills/agent-harness/verification/Sources/AppleVerificationCore/ProjectResolver.swift) detects linked worktrees and checks the
  supplied `allowWorktree` flag. It does not prove user approval or enforce the
  sibling-folder naming convention.
- [Authorization](../../skills/agent-harness/verification/Sources/AppleVerificationCore/Authorization.swift) validates declared `allowed_paths`; it does not intercept
  arbitrary filesystem writes. Client permissions supply that boundary.

A fresh Luna planning check used two fixtures: five investigations in a client
with no child permission controls, and two approved, sandboxed worktrees of the
same repository. The worktree case preserved serialized writers and separate
verification leases. The first case initially proposed read-only dispatch before
resolving unavailable restrictions. One clarification correctly moved inspection
to the lead. The guides now require that decision before dispatch.

A fresh recheck disclosed inherited full-access tools and retained one writer,
but still offered advisory excerpt dispatch without explicitly withholding those
tools. This is **partial planning coverage**, not proof of enforced isolation or
a clean pass for the no-controls case. Keep that case as a regression; prose
alone must not be used to certify a read-only worker. No further retries were run.

No OS sandbox, worktree lifecycle, path-escape denial or app build was exercised.
This evaluation session exposes shared full-access tools, not isolated worker
filesystems. The guide makes these limitations explicit instead of claiming
that a task folder or cooperative lease enforces a sandbox.
