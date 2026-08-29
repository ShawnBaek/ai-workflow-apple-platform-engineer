# Apple development health matrix

Collect only the rows required by the selected profile. Bound every probe and
record timeout as an infrastructure observation, never as a failed app test.

## Agent and skill surfaces

- Confirm the selected mode: Codex, Claude, or collaborative with one writer.
- Resolve each required skill in the effective client environment. Report a
  missing skill, duplicate shadowing copy, broken symlink, and different client
  versions separately.
- Check Codex and Claude configuration independently. Shared files or installed
  skills do not prove that the current task exposed the same tools.
- A Local LLM is optional and loopback-only. When selected, prove only the
  required retrieve/rerank/extract/cluster capability; do not pull a model,
  expose a port, or send credentials during health collection.

## CLI provenance

For each required CLI (`git`, `gh`, `swift`, `xcodebuild`, `xcrun`, `asc`,
`specify`, `codex`, `claude`, and optional `ollama`), record:

- command lookup and all matches;
- resolved real path;
- version/help response;
- package-manager ownership when relevant;
- selected client/config scope.

Cross-check a claimed Xcode MCP binary against Homebrew formula inventory,
global npm packages, transient npx cache, and live process parentage. A Homebrew
tap is not an installed formula. `npm exec ...@latest`, a global NVM binary, and
a Homebrew formula are different provenance and drift risks.

## Xcode MCP ladder

Installation, registration, current-task exposure, and read-only connectivity
are four separate facts. Report every provider injection layer:

1. official Codex route: `xcode -> xcrun mcpbridge`;
2. direct third-party Codex MCP entry;
3. MCP contributed by an installed Codex plugin;
4. Xcode Coding Assistant AgentPlugin, including an independent npx process.

`xcrun mcp-server enable` enables an Apple service/permission; it is not Codex
registration. Codex registration uses
`codex mcp add xcode -- xcrun mcpbridge`. A newly registered tool may require a
new client/task before it is exposed. Treat blanket
`--unsafe-always-allow-all-agents` as a security warning.

After registration and exposure, make one bounded read-only call. Bind the
opaque workspace identifier returned by the current Xcode session; do not pick
the first duplicate path/window. A diagnostic process search can match the
diagnostic command itself, so observe again after it exits before declaring a
provider live.

Use a capability matrix rather than one connection bit:

| Capability | Separate result |
| --- | --- |
| workspace discovery | exact current workspace response |
| target/scheme/destination discovery | only when needed by the task, not a connectivity probe |
| interaction session start/end | fresh session lifecycle |
| workspace-bound install/run | selected workspace and destination |
| hierarchy/touch/capture | actual interaction semantics |
| direct Apple CLI path | fallback evidence, not proof MCP is healthy |

One capability may be degraded while another works. After a user grants Xcode
agent access, discard a stale session, start one fresh session, retry the blocked
read-only capability once, then stop if unchanged. Do not repeat 300-second
build/install/launch loops.

## AppleSampleCode MCP

Treat AppleSampleCode as an optional independent analysis source, not an Apple
official MCP or a substitute for live Apple documentation. When the harness
selects `apple_sample_code_mcp`, verify these layers separately for each selected
client:

The required health check ID is `mcp.apple_sample_code`.

1. exact registration name `apple-sample-code` and streamable HTTP endpoint
   `https://mcp.applesamplecode.com/mcp`;
2. exposure in the current task after any required client restart;
3. the exact read-only tools `search_samples`, `get_sample`, `compare_samples`,
   and `get_status`;
4. one bounded `get_status` call with `refresh: false`.

Codex registration is
`codex mcp add apple-sample-code --url https://mcp.applesamplecode.com/mcp`;
Claude Code registration is
`claude mcp add --transport http apple-sample-code https://mcp.applesamplecode.com/mcp`.
These are repair/configuration mutations and do not belong inside health. An npm
or public MCP Registry release is not required for the remote endpoint.

Do not probe this streamable HTTP server with GET and call an allowed `405` a
failure. Use an MCP client or a bounded JSON-RPC initialization plus the
read-only tool call. Record server version, corpus revision, sample and validated
sequence-diagram counts, source mode, `isLatest`, `lastError`, and observation
time without turning current counts or an alpha version into permanent policy.
`isLatest: null` is unknown freshness; `isLatest: false` is degraded when the
corpus remains usable; a missing revision, missing tool, failed initialization,
or unusable status response is blocked when selected. If not selected, report
`not_applicable` rather than requiring installation.

## GitHub, Spec Kit, and delivery

- Verify active personal/approved GitHub account, exact remote repository,
  permission level, Issues availability, and PR capability.
- Inspect Project v2 only when selected. Missing `read:project`/`project` scope is
  a scoped Project limitation; do not refresh OAuth during health collection.
- When Spec Kit is selected, require the pinned release `v1.0.1`,
  `.specify/feature.json`, intended `specs/<feature>` artifacts, and the chosen
  workflow run's `state.json`, `inputs.json`, and append-only `log.jsonl` when
  present. Bind the explicit feature directory and approved Git branch as two
  independent identities. Compare immutable accepted artifacts before every
  external write and mutable workflow continuity as a separate checkpoint.
- Spec Kit logs describe specification/workflow state; the harness ledger owns
  approvals, attempts, leases, evidence, and external writes.
- For TestFlight profiles, verify the private Apple account/team guard before
  account discovery, then exact app, bundle, platform, version/build policy,
  `asc` capability, agreements/compliance, signing/archive prerequisites, and
  named internal group IDs. Do not upload during health collection.

## CoreSimulator and runtime layers

A project-independent runtime inventory that does not return within 30 seconds
is an infrastructure gate failure. Use one bounded retry for a read-only MCP
capability; stop Simulator mutation fan-out when CoreSimulator is invalid, a
runtime disk service is unresponsive, or a process is in uninterruptible state.

Never infer a single root cause from old beta images, a large inventory, low
disk space, multiple MCP processes, host/Xcode drift, or runtime verification
error `-67054`. They are evidence or hypotheses until a controlled comparison
proves causality. One fresh official runtime re-download is the maximum repair
attempt for one host/Xcode/runtime tuple; a repeated signature stops reinstall.

Runtime health layers are separate:

1. `simctl runtime list -v` disk-image truth, including duplicate builds,
   unavailable or `Deleting` records;
2. fresh temporary-device monitored boot reaches terminal `Finished`;
3. complete shutdown and a strict second monitored boot when runtime stability
   is an acceptance criterion;
4. system-app launch;
5. project install and project launch;
6. XCTest worker materializes and tests actually execute with counts;
7. hierarchy, screenshot, and touch/gesture observation;
8. session shutdown and temporary UUID disappearance.

Exit code 0, `Ready`, `Verified`, first boot, screenshot, or install alone does
not prove the complete path. Parse terminal boot text: aggregate
`Data Migration Failed` is Simulator OS migration evidence and does not
implicate app Core Data/SwiftData when the app was not installed or launched.
A runtime can be partially usable and should then be `degraded`, not healthy or
dead.

Fresh-device runtime health and existing-device task validation are distinct.
Likewise, a provider omitting an older runtime from its interaction targets is a
provider coverage result, not proof that the runtime is absent. Preserve app
build/test evidence separately from infrastructure evidence.

Before labeling an interaction failure as an app bug, use hierarchy-derived
coordinates and the actual gesture semantics. A continuous drag is one
down-hold-move-up gesture; a sequence of taps is not equivalent. If the active
interaction grammar has no pinch command, use an enabled XCUITest target and
`XCUIElement.pinch(withScale:velocity:)`; do not guess syntax or claim runtime
pinch evidence from compilation alone.

## Companion upstream

For a public reference-only upstream, check repository visibility, default
branch HEAD, reviewed revision, selected source blob hashes, license state, and
consumer skill. Do not clone merely for health, execute upstream generators, or
copy code/assets/docs. A changed revision creates a review candidate; it never
auto-merges a consumer-skill change.
