# Human feedback and bounded self-improvement

Treat feedback received during a run as a first-class graph event, not ephemeral
chat text. Record its actor, timestamp, scope, target node/attempt/decision,
concise redacted summary, disposition, and the plan, patch, review, or evidence
IDs it invalidates. Preserve the superseded record; do not rewrite history.

## Apply feedback during the current run

An explicit current-user correction is authoritative within its authorized
scope. Pause affected ready/acting nodes, release a writer lease before changing
owners, and re-evaluate acceptance criteria and the ready set. If source or test
inputs change, create a new attempt linked by `feedback_on`, `attempt_of`, and
`supersedes`; recompute patch identity and invalidate stale review/evidence.

Feedback does not silently grant a new account, repository, destructive action,
external write, merge, or submission permission. Ask when its requested effect
would cross one of those existing gates.

## Propose a durable improvement

After the task, cluster redacted feedback, repeated normalized failures, retry
cost, and missed acceptance checks into an improvement candidate. A local LLM
may cluster or draft the candidate using source IDs; it cannot approve or apply
it. Each candidate records:

- source feedback/failure IDs and scope;
- the narrow rule, route, fixture, or validator change proposed;
- expected benefit and possible regression/overfitting risk;
- one focused before/after probe;
- target: private project overlay or public iOS-experts repository;
- proposal hash, approval, applied version/PR, and rollback reference.

When repository policy allows it, route an approved candidate to
`github-projects` as a linked Issue/Project item with Proposed, Validated,
Approved, Applied, or Rolled Back state. Creating that external record remains a
separate GitHub write gate.

A single correction changes the current run. Promote it durably only when the
user explicitly says it is a general rule, or when repeated evidence supports a
proposal and a human approves it. Sensitive project facts stay in the private
overlay; never train, index, or publish raw feedback containing credentials,
personal data, proprietary code, or private account identifiers.

## Measure and roll back

Judge an applied improvement by observable outcomes such as fewer identical
retries, lower active execution time, fewer false environment/app-failure
classifications, or stronger acceptance evidence. Speed alone is insufficient.
If its probe fails, it conflicts with newer authority, or it causes a broader
regression, mark it `rolled_back`, follow its rollback reference, and preserve
the negative evidence for the next proposal.

Self-improvement is therefore an ordinary reviewed change through the same
branch, minimum-test, repository-confirmation, and PR gates—not invisible
self-modifying behavior.
