# Swift verification

Use the [workflow test plan](workflow-test-plan.md) for scenario selection, pass
criteria and the current distinction between runtime, agent and live integration
coverage. The commands below verify the bundled runtime and repository.
The [functional audit](evidence/skill-functional-audit.md) of the 34 skills present
on 2026-09-05 records actual artifact generation, native framework probes,
discovered guidance defects and per-skill integration gaps; it does not treat
metadata checks as end-to-end proof, and it has not been rerun since.

All bundled runtime helpers and their tests use Swift. The package has no third-party dependencies: Foundation, CryptoKit, SQLite, CoreGraphics, ImageIO, and CoreText provide the implementation. Xcode, `git`, `gh`, and selected Apple tools remain subprocess dependencies where the operation needs them. Custom Python helpers are not required.

Requirements: macOS 13 or later, Swift 6, and full Xcode 16.4 or later for the test libraries. Use the project's selected Xcode; a newer verifier toolchain does not raise the app's deployment target.

```sh
xcrun swift test --package-path skills/agent-harness/verification -j 1 -Xswiftc -j1
APE_BIN_DIR="$(xcrun swift build --package-path skills/agent-harness/verification -j 1 -Xswiftc -j1 --show-bin-path)"
"$APE_BIN_DIR/apple-verify" repository --root .
```

The first command builds the executable and runs targeted regression tests. The second validates skill metadata, the description budget, the [skill lifecycle file](../skills/agent-harness/lifecycle/skill-lifecycle.json), documentation links, JSON/schema pairs, workflow dependencies and lease intervals, terminal conditions, capability policies, fixtures including the [routing fixture](../tests/fixtures/skill-routing.json), and the example ledger. It does not contact GitHub, boot Simulator, evaluate model quality, or measure an app's performance.

CI runs the same checks on macOS. Its `validate` job sets Xcode 16.4 (build 16F6) on the `macos-15` image through `DEVELOPER_DIR`, fails when that path resolves to another build, and records `xcodebuild -version` and `swift --version`. The `validate` job is this repository's compatibility-floor lane under `xcode-project-workflow`'s [selection rule](../skills/xcode-project-workflow/references/xcode-selection.md#choose-by-precedence): it keeps proving the verifier on the oldest supported Xcode, so its path is a minimum rather than a pin, and local runs use Xcode 16.4 or later, the newest installed by default. Move it only with a reviewed change chosen from the image's [published Xcode list](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md). A pull request's newer push cancels its running check; every push to `main` runs to completion. On a developer machine keep worker counts bounded (the `-j 1 -Xswiftc -j1` above); the dedicated CI runner uses SwiftPM's default of one job per CPU. Do not add a second build just to repeat a passing result. Generated `.build` content is ignored and excluded from installed-source identity.

## Swift formatting and compilation

Every Swift change in this repository follows
[Swift format and compile acceptance](../skills/apple-platform-testing/SKILL.md#swift-format-and-compile-acceptance).
The repository owns the root [`.swift-format`](../.swift-format) and CI keeps
every tracked Swift file conformant to it, so whole-file formatting is the right
mode for `.swift` files here. Swift snippets in Markdown are not covered by that
check, and most use 4-space indentation, so they follow the gate's
[snippet recipe](../skills/apple-platform-testing/references/swift-format-gate.md#snippets-and-xcode-editor-tools).
Format with Apple's [swift-format](https://github.com/swiftlang/swift-format),
lint, then compile:

```sh
xcodebuild -version   # identifies Xcode's swift-format, whose --version prints "main"
git ls-files -z '*.swift' | xargs -0 xcrun swift-format format --in-place
git ls-files -z '*.swift' | xargs -0 xcrun swift-format lint   # add no findings beyond the base branch's
git diff --check
xcrun swift build --build-tests --package-path skills/agent-harness/verification -j 1 -Xswiftc -j1
for script in skills/*/scripts/*.swift docs/evidence/generate-comparison.swift; do xcrun swiftc -typecheck "$script"; done
```

This repository's CI gates formatting and compilation. It builds swift-format
604.0.0, the release matching the Xcode 27 toolchain, from the tag's commit
`15d7877c6b32926948f6520f0156657945955ea3`, and fails when formatting changes any
tracked Swift file. It then type-checks the standalone scripts above; the package
build and tests cover the verifier. The
[framework probes](evidence/framework-probes/README.md) need the Xcode 27 SDK, so
CI checks their formatting but not their compilation; compile them with the
commands in their README when you change them. CI reports `swift-format lint`
findings but does not gate on them here, because the tree has a few pre-existing
rule findings (`ReplaceForEachWithForLoop`, `UseSynthesizedInitializer`,
`AlwaysUseLowerCamelCase`); do not add new ones.

With an Xcode whose bundled swift-format differs, build the pinned release
instead of accepting unrelated reformatting: run
`git clone --depth 1 --branch 604.0.0 https://github.com/swiftlang/swift-format`
and `cd swift-format`, confirm `git rev-parse HEAD` prints that commit, then run
`xcrun swift build -c release --product swift-format`. Still in that checkout, run
`SF="$(swift build -c release --show-bin-path)/swift-format"`, then use `"$SF"`
in place of `xcrun swift-format` in the commands above.

Reformatting Swift under the verifier's `Sources` changes the source-bundle
SHA-256 that private harnesses bind, even when behavior is unchanged. After
updating, a private harness observes `runtime-identity` again and reviews its
bindings as described in
[Swift runtime and migration](../skills/agent-harness/references/swift-verification.md).

The [local-runtime regression record](evidence/local-runtime-repair.json) covers
the actual CLI, both harness templates and their before/after results.

For adding skills or changing workflow decisions, use the focused behavioral
evaluation guidance in [CONTRIBUTING.md](../CONTRIBUTING.md). Metadata validation
does not prove that an agent chose the right action. Reporting evaluations use
sanitized fixtures and mocked publication, not test issues in the live repository.

## Command map

Set `APE` to the absolute built executable as shown in [Build and locate the verifier](../skills/agent-harness/references/swift-verification.md#build-and-locate-the-verifier), which also carries this map for installed copies. A copied executable requires `--repository-root <skills-repository>` before its subcommand.
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
| `skill-inventory [--project <dir>] [--output <new-report.json>]` | [Read-only installed skill inventory](../skills/apple-development-health/references/health-matrix.md#installed-skill-inventory) against the lifecycle file; no harness |
| `authorize`, `prepare-action`, `verify-reservation` | Exact action reservation, dispatch and readback contracts |
| `spec-snapshot` | [Spec Kit snapshot](../skills/agent-harness/references/spec-kit-adapter.md) when selected |
| `knowledge index\|query\|status` | [Optional local FTS retrieval](../skills/agent-harness/references/knowledge-and-rag.md) with freshness checks |
| `delivery-report` | [Validated report rendering](../skills/delivery-report/SKILL.md); rendering does not send messages |
| `companion` | [Reference-only upstream check](../skills/icon-composer/contracts/companion-upstream.json) or authorized review-issue reconciliation |
| `flow record\|render` | [Session flow summary](../skills/agent-harness/references/session-flow.md) from client hooks; no harness |

## Evidence and limits

The [open-source portability audit](evidence/open-source-portability.md) inventoried
the 38 skills present at its base commit, `947022e`, and records synthetic
consumer decision checks. Skills added since are not in either audit; the
[current verification boundary](workflow-test-plan.md#current-verification-boundary)
lists them with the latest suite result. Golden script
regressions compile the real Swift scripts with the selected toolchain and run
them from an unrelated working directory; they do not require or validate a live Figma file or app capture.

Choose checks by the observable failure they prevent. A layout change usually needs a relevant build and screenshot; add XCUITest only when a durable interaction regression warrants it. For animation, inspect a trimmed recording, interruption/reversal, and Reduce Motion; use Instruments or a device metric for performance claims.

A comparison report proves the measured geometry of supplied images. It does not infer Figma coordinates, move pixels to hide differences, or turn a screenshot into an animation/performance test. Retain the clean images alongside guides. Use [code review](../skills/code-review/SKILL.md) to check the implementation and challenge findings with source references and reproductions.

The private coordinator is cooperative local process coordination, not remote exactly-once delivery or protection against a hostile same-user process. Never fabricate unavailable usage, Simulator evidence, or a passing CI result.
