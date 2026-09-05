# Swift runtime and migration

The runtime is one Swift package in `../verification`, exposed as `apple-verify`. Build it once with a full Xcode Swift 6 toolchain and keep the binary beside its matching sources/contracts. See the repository [command map](../../../docs/verification.md). There is no Python fallback or dual-runtime mode.

## Existing installations

Complete or safely cancel existing work before migration. Stop admitting new work, account for every active lease and owned child process, then explicitly confirm quiescence. Do not infer it from expiry or one empty run ledger.

The coordinator uses state schema 2, runtime kind `swift`, and contract `apple-verification-core.resources.v1`. Explicit `resources <state> bootstrap --legacy-leases-quiesced` can migrate a quiescent version 1 registry, preserving its identity, terminal lease history, and fencing sequence. It refuses active old leases. Never create a parallel empty registry to bypass contention or erase audit history.

A private harness binds `resource_coordinator` to its exact state path, instance ID, executable SHA-256 and source-bundle SHA-256. `authorization_runtime` separately binds the exact executable path and contract `apple-verification-core.authorization.v1` to those observed hashes. `runtime-identity` reports these values; it does not approve or rewrite a harness. The source digest covers JSON under the installed harness contracts and Swift under verification Sources; build products and tests are excluded.

Old script bindings, partially updated installations, and previously approved run envelopes are incompatible. Review the installed change, explicitly update the private bindings, recollect installed-skill and live-health observations, and create a fresh run authorization/ledger. Do not auto-rehash an existing approval. Any executable rebuild changes its byte identity and requires this review even if source text is unchanged.

Custom verification and adapters should also use Swift. Existing external CLIs remain appropriate for their supported operations; use structured arguments, bounded execution/output, and only the capabilities the task needs. Do not introduce a service, wrapper hierarchy, or generic plugin system for a one-command check.

## Local outcomes

A preview or local fix can select `local_verified`. Its authorization has no GitHub/Apple scope; a commit grant is optional and still requires the applicable explicit user approval. `local_requirements` binds whether review and Spec Kit are required by the accepted plan. Omitted review is recorded in acceptance evidence, not silently treated as passed. `runtime_ui` adds the actual build and destination checks when relevant.

The local template has `github_tracking.issues: false` and `project: null`;
PR and TestFlight profiles still require issue tracking. Existing private
local harnesses that used `issues: true` to bypass the old schema contradiction
need an explicit correction during migration. Rebuild and review the changed
runtime/source identity before rebinding; do not rewrite active approvals.

For an external app, run `apple-verify --app-root <absolute-app-repository>
health ...`. This selects the app independently of the installed contracts.
`--repository-root` retains its skills-repository meaning. Resolve the built
executable with SwiftPM `--show-bin-path` using the same build flags, and check
its `--help` and `runtime-identity`; an old `.build/release` alias is not proof
that the updated runtime is running.

The PR profile retains its publication, independent review, current evidence, and external readback requirements. A simple task plan remains a list; these internal ownership and completion conditions do not require the user to maintain a task graph.
