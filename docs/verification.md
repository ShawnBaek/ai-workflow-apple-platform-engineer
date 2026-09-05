# Swift verification

Use the [workflow test plan](workflow-test-plan.md) for scenario selection, pass
criteria and the current distinction between runtime, agent and live integration
coverage. The commands below verify the bundled runtime and repository.
The [functional audit](evidence/skill-functional-audit.md) records actual artifact
generation, native framework probes, discovered guidance defects and per-skill
integration gaps; it does not treat metadata checks as end-to-end proof.

All bundled runtime helpers and their tests use Swift. The package has no third-party dependencies: Foundation, CryptoKit, SQLite, CoreGraphics, ImageIO, and CoreText provide the implementation. Xcode, `git`, `gh`, and selected Apple tools remain subprocess dependencies where the operation needs them. Custom Python helpers are not required.

Requirements: macOS 13 or later, Swift 6, and full Xcode for the test libraries. Use the project's selected Xcode; a newer verifier toolchain does not raise the app's deployment target.

```sh
swift test --package-path skills/agent-harness/verification -j 1 -Xswiftc -j1
APE_BIN_DIR="$(swift build --package-path skills/agent-harness/verification -j 1 -Xswiftc -j1 --show-bin-path)"
"$APE_BIN_DIR/apple-verify" repository --root .
```

The first command builds the executable and runs targeted regression tests. The second validates skill metadata, documentation links, JSON/schema pairs, workflow dependencies and lease intervals, terminal conditions, capability policies, fixtures, and the example ledger. It does not contact GitHub, boot Simulator, evaluate model quality, or measure an app's performance.

CI runs the same checks on macOS. Keep worker counts bounded; do not add a second build just to repeat a passing result. Generated `.build` content is ignored and excluded from installed-source identity.

The [local-runtime regression record](evidence/local-runtime-repair.json) covers
the actual CLI, both harness templates and their before/after results.

For adding skills or changing workflow decisions, use the focused behavioral
evaluation guidance in [CONTRIBUTING.md](../CONTRIBUTING.md). Metadata validation
does not prove that an agent chose the right action. Reporting evaluations use
sanitized fixtures and mocked publication, not test issues in the live repository.

## Command map

Set `APE` to the absolute built executable as shown in [setup](getting-started.md). A copied executable requires `--repository-root <skills-repository>` before its subcommand.
For app health, use `"$APE" --app-root <absolute-app-repository> health ...`;
the installed skill root still supplies trusted schemas and source identity.

| Command | Purpose and reference |
|---|---|
| `repository --root <root> [--output <new-report.json>]` | Repository contract and documentation validation |
| `compare --manifest <json> --output-dir <new-directory>` | [Clean and aligned side-by-side images](../skills/screenshot/references/aligned-comparison.md) with signed point deltas |
| `runtime-identity` | Observed executable/source identity for explicit private setup |
| `resources <state.json> <operation>` | [Host coordination](../skills/agent-harness/references/coordinator-setup.md), capacity and fenced leases |
| `resolve-project` | [Project resolution](../skills/agent-harness/references/project-registry.md) without guessing a checkout |
| `materialize`, `initialize-run` | Private schema-bound files and append-only run identity |
| `health` | [Live health evaluation](../skills/apple-development-health/SKILL.md) for the selected profile |
| `authorize`, `prepare-action`, `verify-reservation` | Exact action reservation, dispatch and readback contracts |
| `spec-snapshot` | [Spec Kit snapshot](../skills/agent-harness/references/spec-kit-adapter.md) when selected |
| `knowledge index\|query\|status` | [Optional local FTS retrieval](../skills/agent-harness/references/knowledge-and-rag.md) with freshness checks |
| `delivery-report` | [Validated report rendering](../skills/delivery-report/SKILL.md); rendering does not send messages |
| `companion` | [Reference-only upstream check](../skills/icon-composer/contracts/companion-upstream.json) or authorized review-issue reconciliation |

## Evidence and limits

Choose checks by the observable failure they prevent. A layout change usually needs a relevant build and screenshot; add XCUITest only when a durable interaction regression warrants it. For animation, inspect a trimmed recording, interruption/reversal, and Reduce Motion; use Instruments or a device metric for performance claims.

A comparison report proves the measured geometry of supplied images. It does not infer Figma coordinates, move pixels to hide differences, or turn a screenshot into an animation/performance test. Retain the clean images alongside guides. Use [code review](../skills/code-review/SKILL.md) to check the implementation and challenge findings with source references and reproductions.

The private coordinator is cooperative local process coordination, not remote exactly-once delivery or protection against a hostile same-user process. Never fabricate unavailable usage, Simulator evidence, or a passing CI result.
