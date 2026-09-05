# Get started

Apple Platform Engineer is a skill collection, not an app framework. Use an individual skill for a focused task and `native-app-lead` when the work spans several areas. The collection name changed; existing skill names, repository URLs, and machine contract IDs remain compatible.

## Install

Use the [Skills CLI](https://skills.sh/docs/cli) to select the skills and client you need:

```sh
npx skills add ShawnBaek/ai-workflow-apple-platform-engineer
```

After installing for your client, open your app repository and type `$native-app-lead <your task>` in [Codex](https://learn.chatgpt.com/docs/build-skills), or `/native-app-lead <your task>` in [Claude Code](https://code.claude.com/docs/en/skills). See the [README usage examples and workflow](../README.md#after-installation) and the [skill catalog](skills.md) for focused tasks.

Keep one active copy of each skill in the client's configured search roots. Avoid loading duplicate Codex and Claude installations into the same client. Check the [catalog](skills.md) for individual entry points; install the harness and its selected dependencies only for coordinated work.

Native builds, Previews, Simulator, and the Swift verifier need macOS and Xcode. Check the project's actual deployment targets and selected Xcode before choosing APIs. Follow the [official Xcode connection preflight](../skills/xcodebuild/references/xcode-mcp-provider-preflight.md); optional MCP integrations are selected per task, not mandatory installations. Apple documentation and Xcode's available tools come first.

## Start a task

Describe the outcome, relevant constraints, and proof you want. For example:

> Use native-app-lead to add a saved-items screen. Keep our storyboard navigation, design the component in a UIKit preview first, and verify empty and populated states on the minimum supported iOS version.

The agent resolves material ambiguity, checks existing decisions, and chooses the smallest plan. A simple fix needs neither a new ADR nor a graph. Larger work gets coherent reviewable slices; use explicit dependencies when slices actually depend on one another.

## Run the verifier

Build once from the installed `agent-harness` folder with Swift 6 and a full Xcode toolchain:

```sh
AGENT_HARNESS_ROOT='<absolute-installed-agent-harness>'
swift build --package-path "$AGENT_HARNESS_ROOT/verification" -c release --product apple-verify -j 1 -Xswiftc -j1
APE="$AGENT_HARNESS_ROOT/verification/.build/release/apple-verify"
"$APE" --help
```

If `xcode-select -p` points to Command Line Tools, select an existing full Xcode for this command using `DEVELOPER_DIR`; do not change the user's global toolchain automatically. Keep the built executable in its skill directory so it can locate the matching contracts.

For a single local task, run the applicable skill and focused verification. When several agents or tasks share build/Simulator resources, set up the [private host coordinator](../skills/agent-harness/references/coordinator-setup.md). Use `harness-local.json` for `local_verified`; its accepted plan explicitly selects whether independent review and Spec Kit are required. PR delivery uses the PR profile and stronger completion conditions.

Private setup files, credentials, observations, and run ledgers stay outside repositories. Preserve already supplied account and destination approvals; ask again only when an applicable policy requires it or the approved scope changes. See [verification](verification.md) for commands and [migration](../skills/agent-harness/references/swift-verification.md) before updating an existing runtime.
