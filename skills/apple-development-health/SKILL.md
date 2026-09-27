---
name: apple-development-health
description: >-
  Read-only readiness check: CLIs, skills, MCP, GitHub, Xcode, Simulator, App Store Connect and local LLMs. Use before implementation or delivery. Not for setup or installs (use apple-platform-setup).
---

# Apple Development Health

Run this skill near the start of a broad Apple task and again before an
authorized external delivery continuation. It answers a narrow question:
**does the selected delivery profile have the connections and evidence it needs
right now?** It does not repair the machine.

For first installation, missing dependency configuration or upgrade resumption,
use [apple-platform-setup](../apple-platform-setup/SKILL.md). It prepares and carries
authorized changes through existing specialists, then returns here for readiness.
Do not turn a health probe into an installer or require working harness health
before first-run dependency inventory can begin.

The guarded profiles below require `agent-harness` from the same installed Apple
Platform Engineer collection. Health binds its exact Swift executable, source
bundle, coordinator contract and state. A missing or mismatched runtime blocks
a guarded profile; do not substitute an arbitrary executable or create a new
coordinator as repair. Without a selected guarded profile or private harness,
use [standalone readiness](#standalone-readiness-no-harness) instead.

## Standalone readiness (no harness)

Use this when the user asks whether the environment is ready for a task and no
guarded profile is selected. It needs no `apple-verify`, harness, coordinator
or `--harness` report, and follows the same no-repair boundary. Label the result
standalone observations: it cannot satisfy a guarded profile's gate.

Probe only the surfaces the stated task uses. Run each probe once under the
client's command timeout, since macOS ships no `timeout` command: about 10
seconds, or 30 seconds for the runtime inventory. Do not retry in a loop.

| Surface | Bounded read-only probe |
| --- | --- |
| Required CLIs | `command -v` for each selected tool (`git`, `gh`, `swift`, `xcrun`, `asc`, …), then its `--version`; `xcodebuild -version` for Xcode |
| Selected Xcode | Resolve it by the [selection rule](../xcode-project-workflow/references/xcode-selection.md), then `DEVELOPER_DIR='<selected Xcode>/Contents/Developer' xcodebuild -version`; `xcode-select -p` is only a comparison |
| GitHub, for PR delivery | `gh auth status` (never `--show-token`), then `gh repo view <owner/repo> --json nameWithOwner,viewerPermission` for the delivery repository |
| MCP registration | The [registration read](#mcp-registration-read) below, which prints server names and transport only. `claude mcp list` and `get` health-check approved servers, so they are not a registration-only read |
| MCP exposure and connectivity | Whether the current task's tool list includes the selected server (Xcode, Figma, Sketch, Trello, 1Password; plugin and connector servers appear only there), then at most one read-only call its owning skill names |
| Simulator runtimes | `xcrun simctl list runtimes --json` within 30 seconds; add `xcrun simctl list devices available --json` only when the task needs a destination |
| Installed skills | Each selected skill resolves once in the client's skill root, and its `../<skill>/` links resolve there, including `agent-harness` |

Report each component with the same vocabulary:

- `healthy`: the probe returned the capability the task needs.
- `degraded`: an optional surface failed, or a required one works with a stated
  limit, such as `gh` signed in without the Project scope an optional board needs.
- `blocked`: a required surface is missing, unauthenticated, not exposed in this
  task (a registration may need a new session), failing or timed out. A
  timed-out runtime inventory blocks Simulator work as infrastructure, not as an
  app failure; start no second inventory.
- `not_applicable`: the task does not use the surface. The coordinator, leases,
  harness bindings and run authorization are always `not_applicable` here.

Include the probe, bounded evidence (versions, IDs, sanitized states) and a next
action with its owner for each non-healthy component. Route installation or
configuration to `apple-platform-setup`.

### MCP registration read

Print names and transport only; never print or record `env`, header, token or
account values, and never read `~/.claude.json` or `.mcp.json` whole.
`codex mcp list --json` does not mask `env` the way its table does. `jq` ships
in `/usr/bin` since macOS 15.

```sh
# Codex
codex mcp list --json | jq '[.[] | {name, enabled, transport: .transport.type}]'
# Claude Code: user and local scope, then the repository's project scope
jq --arg p '<absolute repository path>' '{user: (.mcpServers // {} | map_values(.type // "stdio")), local: (.projects[$p].mcpServers // {} | map_values(.type // "stdio"))}' ~/.claude.json
jq '.mcpServers // {} | map_values(.type // "stdio")' .mcp.json
```

## Choose one profile

| Profile | Required surfaces |
| --- | --- |
| `local_verified` | authoritative Git repository, selected agent skills, Git CLI and shared coordinator; no GitHub/Apple scope |
| `pr_ready` | authoritative Git repository, selected agent skills, Git/GitHub CLI and account, Issue/PR capability, Spec Kit only when selected |
| `runtime_ui` | local repository/skills/coordinator plus authoritative Xcode container, host Apple tools and exact destination/session; GitHub checks apply only to a PR delivery target |
| `testflight_uploaded` | `pr_ready` plus authoritative Xcode/archive path, private Apple account guard, `asc`, signing/upload/read-back readiness; no Simulator unless selected separately |
| `testflight_distributed` | uploaded profile plus exact pre-authorized internal TestFlight group IDs |
| `icon_upstream` | `pr_ready` plus public companion-upstream provenance and Icon Composer handoff tools that the task actually needs |

Do not require every tool for every run. Missing optional project registry,
AppleSampleCode MCP, Local LLM, Project v2, Simulator, Icon Composer, or
TestFlight support is `not_applicable` when the selected profile does not use
it.

## Rules

1. Resolve the authoritative repository, exact Xcode container when applicable,
   delivery target, and only the GitHub identity or private Apple account guard
   required by that profile before probing tools.
2. Materialize the private report, then let the installed evaluator collect and
   reconcile high-risk GitHub, Xcode, Simulator, ASC, and selected MCP facts
   using [health-matrix.md](references/health-matrix.md). Run Apple host-only
   observations only in the logged-in host environment.
3. Emit one structured report matching
   [health-report.schema.json](contracts/health-report.schema.json), then pass it
   through `apple-verify health` for aggregation and redaction.
4. Keep component status separate: `healthy`, `degraded`, `blocked`, or
   `not_applicable`. Never collapse a passing app test, degraded runtime, and
   failed MCP capability into one “healthy” statement.
5. A required `blocked` component stops the affected graph node. An optional
   failure makes the report `degraded`; it never silently expands scope.

Set `APE` using the [Swift setup](../agent-harness/references/swift-verification.md#build-and-locate-the-verifier), then evaluate a populated private report:

```sh
"$APE" --app-root '<absolute-authoritative-app-repository>' health '<health-observations.json>' \
  --harness '<authoritative-harness.json>'
```

The evaluator performs bounded read-only probes but no repair. Caller-written
status/evidence never establishes high-risk success: the evaluator overwrites
it from live observations and repeats those observations at action dispatch.
Missing commands, offline providers, timeouts, target/account drift, or a
required non-healthy result block. Unselected optional MCPs are not probed.

Keep a failed operation separate from the whole assignment. A busy lease follows
[contention handling](../agent-harness/references/host-resources.md); a root/schema
failure needs the installed runtime and caller checked before blaming task
locks. Reuse the selected profile within its freshness rules; delegated workers
do not repeat unrelated discovery or ask again for settled project facts.

`active_lease_count` is a time-scoped observation, not coordinator identity.
Unrelated tasks may change it between collection and evaluation; binding uses
only canonical state-path hash, instance, schema/bootstrap state, and installed
Swift executable and source-bundle hashes.

When `apple_sample_code_mcp` is selected, require the exact
`mcp.apple_sample_code` check. For each client selected by the harness, observe
that client's registration separately from current-task tool exposure. Require
both Codex and Claude observations only when both clients consume the MCP. Make
one bounded read-only corpus-status call. Health never registers the server or
refreshes its corpus.

When `project_registry` is selected, require
`repository.project_registry`. A selected candidate is healthy only when the
structured `project_registry_resolution` and live canonical Git root, remote
fingerprint, checkout kind, and applicable opened Xcode container agree. A
free-form evidence string is not sufficient. Stale unselected entries are
degraded inventory; a selected mismatch, unapproved worktree, or unresolved
ambiguity is blocked. Health never edits the registry or chooses among
ambiguous candidates.

## No-repair boundary

The health check must not:

- install, update, enable, disable, or uninstall a CLI, skill, plugin, MCP, Xcode
  component, runtime, package, or Local LLM model;
- edit Codex, Claude, Xcode AgentPlugin, project, signing, or GitHub settings;
- build, test, install, or launch an app, or create or boot a Simulator device;
  cite the owning skill's evidence instead, as the
  [runtime layers](references/health-matrix.md#coresimulator-and-runtime-layers)
  describe;
- run a destination inventory merely to prove an MCP connection;
- broaden OAuth scopes, switch cached accounts, create credentials, or reveal a
  token/profile/private key;
- terminate providers/services, reboot, erase devices, delete runtimes, clear
  DerivedData/caches, or mutate CoreSimulator registration;
- execute scripts from a companion upstream.

When a repair is required, report the exact failed layer and route to its owner:
`xcode-project-workflow`, `xcodebuild`, `git-workflow`, `github-projects`,
`app-store-connect`, `swift-package-manager`, `xcode-storage`, or
`icon-composer`. Repair remains a separately authorized action.

For 1Password development ENV setup, repair, secret migration, or local mounts,
route to [`onepassword-environments`](../onepassword-environments/SKILL.md).
It is optional and does not add a required check to this read-only health profile.

## Completion

A useful report includes the profile, authoritative targets, timestamp, every
required component, bounded evidence, explicit omissions, and a next action for
each non-healthy component. Evidence contains versions/IDs and sanitized states,
not credentials or raw account inventories.

Health is a gate, not acceptance evidence for the product change. Continue to
minimum-sufficient build, test, interaction, screenshot/video, and external
read-back verification required by the task.
