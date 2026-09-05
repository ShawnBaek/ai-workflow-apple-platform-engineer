---
name: apple-development-health
description: >-
  Read-only health check for an Apple development task before implementation or
  delivery. Verifies required CLIs, Codex/Claude skills, MCP provenance and
  current-task connectivity, GitHub/Spec Kit state, Xcode/CoreSimulator layers,
  App Store Connect readiness, optional AppleSampleCode MCP and local LLMs, and
  companion upstreams without installing, repairing, cleaning, or broadening
  credentials.
---

# Apple Development Health

Run this skill near the start of a broad Apple task and again before an
authorized external delivery continuation. It answers a narrow question:
**does the selected delivery profile have the connections and evidence it needs
right now?** It does not repair the machine.

This skill requires `agent-harness` from the same installed `iOS-experts`
collection because health hashes and reads that sibling's coordinator. If the
sibling is unavailable, report `installed resource coordinator script is
unavailable`; do not copy an arbitrary script or create a new state as repair.

## Choose one profile

| Profile | Required surfaces |
| --- | --- |
| `pr_ready` | authoritative Git repository, selected agent skills, Git/GitHub CLI and account, Issue/PR capability, Spec Kit only when selected |
| `runtime_ui` | `pr_ready` plus authoritative Xcode container, host Apple tools, exact destination/session, required runtime capabilities |
| `testflight_uploaded` | `pr_ready` plus authoritative Xcode/archive path, private Apple account guard, `asc`, signing/upload/read-back readiness; no Simulator unless selected separately |
| `testflight_distributed` | uploaded profile plus exact pre-authorized internal TestFlight group IDs |
| `icon_upstream` | `pr_ready` plus public companion-upstream provenance and Icon Composer handoff tools that the task actually needs |

Do not require every tool for every run. Missing optional project registry,
AppleSampleCode MCP, Local LLM, Project v2, Simulator, Icon Composer, or
TestFlight support is `not_applicable` when the selected profile does not use
it.

## Rules

1. Resolve the authoritative repository, exact Xcode container when applicable,
   current GitHub identity, private Apple account guard, and delivery target
   before probing tools.
2. Materialize the private report, then let the installed evaluator collect and
   reconcile high-risk GitHub, Xcode, Simulator, ASC, and selected MCP facts
   using [health-matrix.md](references/health-matrix.md). Run Apple host-only
   observations only in the logged-in host environment.
3. Emit one structured report matching
   [health-report.schema.json](contracts/health-report.schema.json), then pass it
   through `scripts/evaluate_health.py` for aggregation and redaction.
4. Keep component status separate: `healthy`, `degraded`, `blocked`, or
   `not_applicable`. Never collapse a passing app test, degraded runtime, and
   failed MCP capability into one “healthy” statement.
5. A required `blocked` component stops the affected graph node. An optional
   failure makes the report `degraded`; it never silently expands scope.

Evaluate a populated private report from the installed skill folder:

```sh
python3 scripts/evaluate_health.py '<health-observations.json>' \
  --harness '<authoritative-harness.json>'
```

The evaluator performs bounded read-only probes but no repair. Caller-written
status/evidence never establishes high-risk success: the evaluator overwrites
it from live observations and repeats those observations at action dispatch.
Missing commands, offline providers, timeouts, target/account drift, or a
required non-healthy result block. Unselected optional MCPs are not probed.

`active_lease_count` is a time-scoped observation, not coordinator identity.
Unrelated tasks may change it between collection and evaluation; binding uses
only canonical state-path hash, instance, schema/bootstrap state, and installed
script plus complete executable/JSON contract-bundle hashes.

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
- start a build, test, device inventory, install, or launch merely to prove
  an MCP connection;
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
