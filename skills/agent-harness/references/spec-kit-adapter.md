# Optional GitHub Spec Kit adapter

Keep the provider-neutral workflow and ledger authoritative. This adapter is
pinned to Spec Kit `v1.0.1`; a newer CLI is a detected migration candidate, not
an implicit upgrade. Do not vendor Spec Kit or install/update `specify` during a
health check.

## Artifact and log mapping

Spec Kit `v1.0.1` persists the selected directory in
`.specify/feature.json` under the `feature_directory` key. Resolve that pointer
exactly; this adapter accepts only the canonical repository-relative form
`specs/<feature>`. Reject an absolute path, traversal, symlink escape, missing
directory, malformed pointer, or a pointer that differs from the explicitly
approved feature directory. Do not scan every directory under `specs/` and do
not select one from the current Git branch. Spec Kit feature identity and Git
branch identity are independent.

After the spec, plan, and tasks are accepted, bind only their immutable product
artifacts to the authorization snapshot:

- required selected-feature files: `spec.md`, `plan.md`, and `tasks.md`;
- optional `.specify/memory/constitution.md`;
- optional selected-feature `research.md`, `data-model.md`, `quickstart.md`,
  `checklists/`, and `contracts/` contents.

The pointer identifies that artifact set, but its raw JSON bytes are not an
accepted product artifact. Missing required selected-feature files fail closed.
Before implementation, review, resume, and every external write, run
`scripts/spec_kit_snapshot.py` and bind `feature_directory`, `feature_id`,
`artifact_hashes`, and `snapshot_sha256` to the harness ledger and run
authorization.

When a workflow `run_id` is selected, require all three official run files:
`.specify/workflows/runs/<run_id>/state.json`, `inputs.json`, and `log.jsonl`.
Keep them in a separate mutable `workflow_checkpoint`; never include them in the
immutable authorization hash. Normal `state.json` and `inputs.json` progress is
allowed. Enforce append-only continuity for `log.jsonl`: a later log must retain
every previously observed entry in the same order and may only append new
entries; rewrite or truncation blocks resume and external writes.

From the installed `agent-harness` folder, a deterministic snapshot looks like:

```sh
python3 scripts/spec_kit_snapshot.py snapshot \
  --root '<authoritative-repository>' \
  --release v1.0.1 \
  --feature-directory 'specs/<approved-feature>' \
  --run-id '<spec-kit-run-id>'
```

Store the JSON in the private run evidence. Verification uses the same fixed
arguments plus `verify --expected '<approved-snapshot.json>'`; it does not write
into `.specify/`. Omit `--run-id` only when no Spec Kit workflow run is part of
the task. Operational snapshot and verify calls require the explicitly approved
`--feature-directory`. `snapshot --discovery` may inspect the current pointer
read-only before approval, but its result never authorizes implementation or an
external write.

Spec Kit logs are useful resumable history, but they do not own user approvals,
leases, attempts, product evidence, GitHub mutations, or TestFlight state. The
harness ledger remains authoritative for those facts.

Spec Kit's workflow lifecycle can coordinate specify, review, plan, tasks, and
implementation. Its top-level workflow is sequential, and fan-out repeats one
template over items with bounded concurrency. It is not a general dependency
graph scheduler. Keep the execution DAG in `workflow.json` and use a
deterministic ready-set resolver if a project needs arbitrary dependencies.

## Bounded convergence

Represent iteration with a `do-while`/controller loop capped at three passes.
Do not parse natural-language output to decide convergence. Run a fixed script
that hashes the relevant persisted task/spec state before and after the
convergence step and emits a small JSON result. Continue only when those hashes
differ.

After the loop, run an explicit postcondition: if the state still changes at the
cap, exit nonzero and record `blocked`. Some workflow engines treat reaching a
loop cap as normal completion, so the postcondition prevents a false green.

Keep human approval, signing, release, destructive cleanup, and external writes
outside a nested loop. Resume behavior can re-enter a parent body; loop steps
must therefore be idempotent local planning/edit/verification operations.

Set explicit shell timeouts for Xcode validation. Shell steps call fixed script
paths with allowlisted enum inputs. Never interpolate model, retrieval, issue,
or PR text into `run` or integration names, and never treat `requires` metadata
as an authorization gate.

`/speckit.converge` may expose spec/implementation gaps; it is not runtime test
evidence. The harness completion predicate still requires current build/test,
review hash, leases, acceptance evidence, and PR checks.

## GitHub tracking

`/speckit.taskstoissues` may create one Issue per T### task, but do not use it by
default for tightly coupled subtasks. Prefer one feature Issue unless a task is
independently reviewable, assignable, and PR-sized. Map Ready → In Progress → In
Review → Done/Blocked through `github-projects`; Spec Kit task completion alone
does not mark the GitHub item Done.

Generated Spec Kit workflow and template definitions change only through the
documented preset, extension, or override surface. Accepted product artifacts
such as `spec.md`, `plan.md`, and `tasks.md` may evolve through the documented
Spec Kit lifecycle, but every accepted change requires a new immutable snapshot
and renewed run authorization. Do not patch generated workflow internals and do
not interpolate model/retrieved/Issue text into shell commands or integration
names.

References:

- [Spec Kit workflow reference](https://github.com/github/spec-kit/blob/v1.0.1/docs/reference/workflows.md)
- [Spec Kit feature-directory contract](https://github.com/github/spec-kit/blob/v1.0.1/templates/commands/specify.md)
- [Spec Kit feature-path implementation](https://github.com/github/spec-kit/blob/v1.0.1/scripts/python/common.py)
- [Spec Kit converge contract](https://github.com/github/spec-kit/blob/v1.0.1/templates/commands/converge.md)
