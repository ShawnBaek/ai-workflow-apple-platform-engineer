# Optional GitHub Spec Kit adapter

Keep the provider-neutral workflow and ledger authoritative. Pin the Spec Kit
version a project validated; do not assume a newer CLI has identical workflow
commands or engine semantics.

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

References:

- [Spec Kit workflow reference](https://github.com/github/spec-kit/blob/v1.0.1/docs/reference/workflows.md)
- [Spec Kit converge contract](https://github.com/github/spec-kit/blob/v1.0.1/templates/commands/converge.md)
