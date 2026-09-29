# Swift runtime and migration

The runtime is one Swift package in `../verification`, exposed as `apple-verify`. Build it once with a full Xcode Swift 6 toolchain and keep the binary beside its matching sources/contracts. There is no Python fallback or dual-runtime mode. Standalone skills do not need it; build it for guarded or coordinated work, or when a task selects one of the commands below.

## Build and locate the verifier

Build from the installed `agent-harness` folder, then resolve the path. To check an installation with `skill-inventory`, set `AGENT_HARNESS_ROOT` instead to the reviewed revision's `agent-harness` outside every skill root, as the [update procedure](../../apple-platform-setup/references/updating.md#inventory-before-reconciling) describes. `--show-bin-path` only prints the output directory and does not build, so run the build command first:

```sh
AGENT_HARNESS_ROOT='<absolute-installed-agent-harness>'
xcrun swift build --package-path "$AGENT_HARNESS_ROOT/verification" -c release --product apple-verify -j 1 -Xswiftc -j1
APE_BIN_DIR="$(xcrun swift build --package-path "$AGENT_HARNESS_ROOT/verification" -c release --product apple-verify -j 1 -Xswiftc -j1 --show-bin-path)"
APE="$APE_BIN_DIR/apple-verify"
"$APE" --help
```

Run these commands with `DEVELOPER_DIR` set to the Xcode that the [selection rule](../../xcode-project-workflow/references/xcode-selection.md) chooses. That is the newest installed full Xcode unless the user or project pins one, whatever `xcode-select -p` points to (it may be Command Line Tools or an older Xcode). Call `xcrun swift`, as above: `xcrun` resolves `swift` from that Xcode, while a bare `swift` comes from `PATH`, where a swiftly installation comes first and bypasses the selected Xcode. An App Store archive follows the rule's distribution exception instead. Do not change the user's global toolchain. Keep the built executable in its skill directory so it can locate the matching contracts.

Use the same toolchain, configuration and build flags for the build and `--show-bin-path`; a guessed `.build/release` path may select an older executable. Check `--help` for `--app-root`, then observe `runtime-identity` before binding this executable in private setup. Reuse a verified matching binary rather than rebuilding for every task.

Explicit flags go before the subcommand. `--app-root <absolute-app-repository>` selects the app a command checks, while schemas and source identity stay with the installed harness. `--repository-root <skills-repository>` selects a **skills repository**, for example when the executable was copied; it is not the app-root option.

| Command | Purpose and reference |
|---|---|
| `runtime-identity` | Observed executable/source identity for explicit private setup |
| `resources <state.json> <operation>` | [Host coordination](coordinator-setup.md), capacity and fenced leases |
| `resolve-project` | [Project resolution](project-registry.md) without guessing a checkout |
| `materialize`, `initialize-run` | Private schema-bound files and append-only run identity |
| `health` | [Live health evaluation](../../apple-development-health/SKILL.md) for a guarded profile |
| `skill-inventory [--project <dir>] [--output <new-report.json>]` | [Read-only installed skill inventory](../../apple-development-health/references/health-matrix.md#installed-skill-inventory) against the lifecycle file; no harness |
| `authorize`, `prepare-action`, `verify-reservation` | Exact action reservation, dispatch and readback contracts |
| `spec-snapshot` | [Spec Kit snapshot](spec-kit-adapter.md) when selected |
| `knowledge index\|query\|status` | [Optional local FTS retrieval](knowledge-and-rag.md) with freshness checks |
| `delivery-report` | [Validated report rendering](../../delivery-report/SKILL.md); rendering does not send messages |
| `compare --manifest <json> --output-dir <new-directory>` | [Clean and aligned side-by-side images](../../screenshot/references/aligned-comparison.md) with signed point deltas |
| `companion` | [Reference-only upstream check](../../icon-composer/references/companion-upstream.md) or authorized review-issue reconciliation |
| `repository --root <root>` | Contract and documentation validation of a skills repository checkout |
| `flow record\|render` | [Session flow summary](session-flow.md) from client hooks; no harness |

## Existing installations

Complete or safely cancel existing work before migration. Stop admitting new work, account for every active lease and owned child process, then explicitly confirm quiescence. Do not infer it from expiry or one empty run ledger.

The coordinator uses state schema 2, runtime kind `swift`, and contract `apple-verification-core.resources.v1`. Explicit `resources <state> bootstrap --legacy-leases-quiesced` can migrate a quiescent version 1 registry, preserving its identity, terminal lease history, and fencing sequence. It refuses active old leases. Never create a parallel empty registry to bypass contention or erase audit history. After migration, released and recovered leases follow the bounded [state retention](coordinator-setup.md#state-retention); run ledgers remain the audit record.

A private harness binds `resource_coordinator` to its exact state path, instance ID, executable SHA-256 and source-bundle SHA-256. `authorization_runtime` separately binds the exact executable path and contract `apple-verification-core.authorization.v1` to those observed hashes. `runtime-identity` reports these values; it does not approve or rewrite a harness. A `runtime_ui` harness also names a separate, initialized probe run in `runtime_probe_scope`; see [runtime probe scope](coordinator-setup.md#runtime-probe-scope). The source digest covers JSON under the installed harness contracts and Swift under verification Sources; build products and tests are excluded.

Old script bindings, partially updated installations, and previously approved run envelopes are incompatible. Review the installed change, explicitly update the private bindings, recollect installed-skill and live-health observations, and create a fresh run authorization/ledger. Do not auto-rehash an existing approval. Any executable rebuild changes its byte identity and requires this review even if source text is unchanged.

Custom verification and adapters should also use Swift. Existing external CLIs remain appropriate for their supported operations; use structured arguments, bounded execution/output, and only the capabilities the task needs. Do not introduce a service, wrapper hierarchy, or generic plugin system for a one-command check.

## Local outcomes

A preview or local fix can select `local_verified`. Its authorization, started from `templates/run-authorization-local.json`, has no GitHub/Apple scope; a commit grant is optional and still requires the applicable explicit user approval. `local_requirements` binds whether review and Spec Kit are required by the accepted plan, with the same values in the authorization and the harness. Omitted review is recorded in acceptance evidence, not silently treated as passed. `runtime_ui` adds the actual build and destination checks when relevant.

The local template has `github_tracking.issues: false` and `project: null`;
PR and TestFlight profiles still require issue tracking. Existing private
local harnesses that used `issues: true` to bypass the old schema contradiction
need an explicit correction during migration. Rebuild and review the changed
runtime/source identity before rebinding; do not rewrite active approvals.

For an external app, run `apple-verify --app-root <absolute-app-repository>
health ...`. This selects the app independently of the installed contracts.
`--repository-root` retains its skills-repository meaning. Build and resolve the
executable as in [Build and locate the verifier](#build-and-locate-the-verifier),
then check its `--help` and `runtime-identity`; an old `.build/release` alias is
not proof that the updated runtime is running.

The PR profile retains its publication, independent review, current evidence, and external readback requirements. A simple task plan remains a list; these internal ownership and completion conditions do not require the user to maintain a task graph.
