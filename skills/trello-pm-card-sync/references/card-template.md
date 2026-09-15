# Agent-ready card template

Append or update a clearly delimited brief while preserving original PM content
and attachments. Copy to another tracker only in authorized sync mode. Sections
are conditional: `Not provided` means unknown; `Not applicable` requires a known
reason. Do not present required future proof as an already observed result.

```markdown
## Agent-ready brief
- Objective: [one testable outcome]
- Platform / route: [selected platform and entry point]
- Source mapping: [existing symbol/path, or Not provided]
- Scope: [concrete work and exclusions]
- Acceptance: Given [fixture], when [action], then [observable result].

## Design and inputs
- Selected source: [Figma node / supplied image / code-first Preview / N/A]
- Required input: [link or BLOCKED — required source missing]
- Visible content/states: [relevant fixed labels/data/loading/error states]
- Open questions: [user/PM decision; never a guessed frame]

## Verification plan and observed evidence
- Required checks: [behavior-specific tests or review]
- Fixture: [device/OS/locale/data when applicable]
- Execution: [Not run, or exact command/result and revision]
- PR: [URL + SHA, only when the workflow requires a PR]
- Visual proof: [approved raw inputs, side-by-side, overlay/diff if applicable]
- Pixel result: [Not run, or threshold + required/actual percentage]
- Semantic result: [Not run, or missing/extra/changed fields]
- Failure: [actionable mismatch or environment blocker, if observed]

## Handoff and sync
- Current status: [existing mapped board status]
- Board-visible title: [readiness status] [TestFlight version (build)] [outcome, in English]
- Next owner and readiness condition: [configured workflow]
- Blockers: [reason or None]
- TestFlight, if selected: [marketing version; build number or Build TBD; processing state; source revision inclusion; tester/group access]
- Links: [current card; issue/PR/proof only when selected and available]
- Sync: [direction, field ownership, record IDs and last verified state]
```

For a required Figma task without a node URL, retain the blocker and ask the
user for the authoritative node. A supplied-image task does not need a Figma
account. A documentation task does not need Simulator proof or a TestFlight
build. Map readiness separately from completion; a QA handoff is not QA passed.

Respect the connector's actual text/attachment limits. If the original content
plus brief will not fit, do not truncate or overwrite it. Prepare a compact
summary and link an authorized canonical work item or attachment; if none is
authorized, report the limit and keep the prepared brief local. On concurrent
edits, re-read and reconcile before writing rather than replacing stale content.
