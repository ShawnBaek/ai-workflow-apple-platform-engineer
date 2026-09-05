# Get started

Apple Platform Engineer is a skill collection, not an app framework. Use an individual skill for a focused task and `apple-platform-engineer` when the work spans several areas. The lead skill was renamed from `native-app-lead`; other skill names and machine contract IDs are unchanged.

## Install

Use the [Skills CLI](https://skills.sh/docs/cli) to select the skills and client you need:

```sh
npx skills add ShawnBaek/ai-workflow-apple-platform-engineer
```

After installing for your client, open your app repository and type `$apple-platform-engineer <your task>` in [Codex](https://learn.chatgpt.com/docs/build-skills), or `/apple-platform-engineer <your task>` in [Claude Code](https://code.claude.com/docs/en/skills). See the [README usage examples and workflow](../README.md#after-installation) and the [skill catalog](skills.md) for focused tasks.

Keep one active copy of each skill in the client's configured search roots. Avoid loading duplicate Codex and Claude installations into the same client. Check the [catalog](skills.md) for individual entry points; install the harness and its selected dependencies only for coordinated work.

Native builds, Previews, Simulator, and the Swift verifier need macOS and Xcode. Check the project's actual deployment targets and selected Xcode before choosing APIs. Follow the [official Xcode connection preflight](../skills/xcodebuild/references/xcode-mcp-provider-preflight.md); optional MCP integrations are selected per task, not mandatory installations. Apple documentation and Xcode's available tools come first.

## Update

For an existing installation, use the [update guide](updating.md). Updating a repository checkout does not necessarily update the copy loaded by your agent.

## Rename an existing lead installation

Install `apple-platform-engineer` through your original installation method,
preserving its supporting skills and local changes. Updating only the old
`native-app-lead` name does not install the renamed entry. Validate the new
folder and matching frontmatter. Stop admitting old-name work and let its active
tasks finish or be safely cancelled before backing up and deactivating the old
entry in the client's search roots. Retain it only for that transition, then keep
one discoverable lead; an old-name link
to new-name frontmatter is not a compatibility alias.

Use `$apple-platform-engineer <task>` in Codex or
`/apple-platform-engineer <task>` in Claude Code. Refresh skill discovery
before using the new name. For an explicitly configured private harness,
review any old `task_skills` references and collect fresh health evidence
before its next authorized run. Do not rewrite historical ledgers or
silently renew existing approvals.

## Start a task

Describe the outcome, relevant constraints, and proof you want. For example:

> Use apple-platform-engineer to add a saved-items screen. Keep our storyboard navigation, design the component in a UIKit preview first, and verify empty and populated states on the minimum supported iOS version.

The agent resolves material ambiguity, checks existing decisions, and chooses the smallest plan. A simple fix needs neither a new ADR nor a graph. Larger work gets coherent reviewable slices; use explicit dependencies when slices actually depend on one another.

For several tasks, provide their acceptance criteria and ask the lead to inspect dependencies and the available worker slots. Five tasks do not imply five simultaneous agents: queue excess work, integrate same-repository edits through one writer, and bound builds and Simulator use. See [batch delegation](../skills/agent-harness/references/collaboration.md#delegate-a-batch-of-tasks).

## Run the verifier

Build once from the installed `agent-harness` folder with Swift 6 and a full Xcode toolchain:

```sh
AGENT_HARNESS_ROOT='<absolute-installed-agent-harness>'
swift build --package-path "$AGENT_HARNESS_ROOT/verification" -c release --product apple-verify -j 1 -Xswiftc -j1
APE_BIN_DIR="$(swift build --package-path "$AGENT_HARNESS_ROOT/verification" -c release --product apple-verify -j 1 -Xswiftc -j1 --show-bin-path)"
APE="$APE_BIN_DIR/apple-verify"
"$APE" --help
```

If `xcode-select -p` points to Command Line Tools, select an existing full Xcode for this command using `DEVELOPER_DIR`; do not change the user's global toolchain automatically. Keep the built executable in its skill directory so it can locate the matching contracts.

Use the same toolchain, configuration and build flags for the build and `--show-bin-path`; a guessed `.build/release` path may select an older executable. Check `--help` for `--app-root`, then observe `runtime-identity` before binding this executable in private setup.

For an app outside the skill collection, pass its absolute authoritative root before the command:

```sh
"$APE" --app-root '<absolute-app-repository>' health '<private-report.json>' --harness '<private-harness.json>'
```

`--app-root` selects the app checked by health while schemas and source identity stay with the installed harness. `--repository-root` selects a **skills repository**, for example when the executable was copied; it is not the app-root option. Explicit flags go before the subcommand.

For a single local task, run the applicable skill and focused verification. When several agents or tasks share build/Simulator resources, set up the [private host coordinator](../skills/agent-harness/references/coordinator-setup.md). Use `harness-local.json` for `local_verified`; its accepted plan explicitly selects whether independent review and Spec Kit are required. PR delivery uses the PR profile and stronger completion conditions.

Private setup files, credentials, observations, and run ledgers stay outside repositories. Preserve already supplied account and destination approvals; ask again only when an applicable policy requires it or the approved scope changes. See [verification](verification.md) for commands and [migration](../skills/agent-harness/references/swift-verification.md) before updating an existing runtime.
