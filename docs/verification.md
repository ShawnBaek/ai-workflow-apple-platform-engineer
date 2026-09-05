# Swift verification

The active runtime and verification commands use Swift. The package has no third-party
dependencies. Xcode, `git`, `gh`, and selected Apple tools remain subprocess
dependencies only where an operation needs them. There is no Python fallback.

Requirements are macOS 13 or later, Swift 6, and full Xcode for the test
libraries. Use the project's selected Xcode; a newer verifier toolchain does
not raise an app's deployment target.

```sh
swift test --package-path skills/agent-harness/verification -j 1 -Xswiftc -j1
skills/agent-harness/verification/.build/debug/apple-verify repository --root .
```

The first command builds the executable and runs its regression tests. The
second validates the repository contracts, workflows, fixtures, skill metadata,
and local links. It does not contact GitHub, boot Simulator, evaluate model
quality, or measure app performance.

## Command map

Set `APE` to the absolute built executable as shown in
[setup](getting-started.md). A copied executable requires
`--repository-root <skills-repository>` before its subcommand.

| Command | Purpose and reference |
|---|---|
| `repository --root <root> [--output <new-report.json>]` | Repository contract and documentation validation |
| `compare --manifest <json> --output-dir <new-directory>` | Deterministic image comparison |
| `runtime-identity` | Observed executable and source identity for explicit private setup |
| `resources <state.json> <operation>` | [Host coordination](../skills/agent-harness/references/coordinator-setup.md), capacity, and fenced leases |
| `resolve-project` | [Project resolution](../skills/agent-harness/references/project-registry.md) without guessing a checkout |
| `materialize`, `initialize-run` | Private schema-bound files and append-only run identity |
| `health` | [Live health evaluation](../skills/apple-development-health/SKILL.md) for the selected profile |
| `authorize`, `prepare-action`, `verify-reservation` | Exact authorization, action reservation, dispatch, and readback contracts |
| `spec-snapshot` | [Spec Kit snapshot](../skills/agent-harness/references/spec-kit-adapter.md) when selected |
| `knowledge index\|query\|status` | [Optional local retrieval](../skills/agent-harness/references/knowledge-and-rag.md) with freshness checks |
| `delivery-report` | [Validated report rendering](../skills/delivery-report/SKILL.md); rendering does not send messages |
| `companion` | Reference-only upstream checks or authorized review-issue reconciliation |

The coordinator is cooperative same-user process coordination, not remote
exactly-once delivery or protection against a hostile local process. Never
fabricate unavailable usage, Simulator evidence, or a passing CI result.
