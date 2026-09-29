# Get started

Apple Platform Engineer is a skill collection, not an app framework. Use an individual skill for a focused task and `apple-platform-engineer` when the work spans several areas. The lead skill was renamed from `native-app-lead`; other skill names and machine contract IDs are unchanged.

## Install

Use the [Skills CLI](https://skills.sh/docs/cli). This installs the starter set for your user (`-g`) and for Claude Code; use `-a codex` for Codex, or `-a claude-code codex` for both:

```sh
npx skills@1.5.23 add ShawnBaek/ai-workflow-apple-platform-engineer -g -a claude-code \
  --skill apple-platform-engineer agent-harness apple-platform-setup \
  apple-development-health xcode-project-workflow xcodebuild core-simulator-health \
  apple-platform-ui xcode-preview-design apple-platform-testing screenshot \
  git-workflow code-review open-xcode-handoff
```

With `-g`, the skills work in every repository, laid out per `-a` value:

- `-a claude-code codex`: one real folder per skill in `~/.agents/skills`, which Codex reads directly, and a link to each in `~/.claude/skills` for Claude Code.
- `-a claude-code`: real folders copied into `~/.claude/skills`; nothing in `~/.agents/skills`.
- `-a codex`: real folders in `~/.agents/skills`.

Without `-g`, it installs into the current directory (`.claude/skills` or `.agents/skills`); run it from the app repository root. Each skill folder is installed on its own, so skills that link another skill need that skill installed too: `agent-harness` is required by the lead and by the specialists the [catalog](skills.md) lists. Add a specialist later with the same command and its name, or install the whole collection with `--skill '*'`.

`code-review` is always part of the set; keep it in a selective install, because PR delivery waits for its review verdict. In Claude Code it intentionally replaces the bundled `/code-review`, which stays reachable through its alias `/review`. Codex bundles no `code-review` skill, so `$code-review` is the collection's there as well, and Codex's `/review` command is unchanged.

The command pins Skills CLI 1.5.23, the [tested version](../skills/apple-platform-setup/references/updating.md#skills-cli-version). It declares Node.js 22.20.0 or later (`node --version`); on an older Node, an unpinned `npx skills` silently resolves to 1.5.18, which the collection does not support.

After installing for your client, use the [first-run setup](#first-run-setup-with-your-agent) for a new environment. Then open your app repository and type `$apple-platform-engineer <your task>` in [Codex](https://learn.chatgpt.com/docs/build-skills), or `/apple-platform-engineer <your task>` in [Claude Code](https://code.claude.com/docs/en/skills). See the [README usage examples and workflow](../README.md#after-installation) and the [skill catalog](skills.md) for focused tasks.

Keep one active copy of each skill in the client's configured search roots. Avoid loading duplicate Codex and Claude installations into the same client. Installing `agent-harness` adds files only; nothing is built or configured until you select coordinated work.

Native builds, Previews, Simulator, and the Swift verifier need macOS and Xcode. Check the project's actual deployment targets and selected Xcode before choosing APIs. Follow the [official Xcode connection preflight](../skills/xcodebuild/references/xcode-mcp-provider-preflight.md); optional MCP integrations are selected per task, not mandatory installations. Apple documentation and Xcode's available tools come first.

## Update

For an existing installation, use the [update guide](updating.md). Updating a repository checkout does not necessarily update the copy loaded by your agent.

## First-run setup with your agent

Include `apple-platform-setup` and the specialists for your selected work in the
installation. Then open the intended app repository and ask:

```text
$apple-platform-setup Set up this project for local app work and GitHub PR delivery.
```

Use `/apple-platform-setup` in Claude Code. Add ASC/Xcode Cloud, Figma or another
integration only when needed. The setup skill inventories the active client and
skill copy, checks dependencies, carries authorized configuration through its
owning specialist, and verifies actual capability before handing off to the lead.
It reuses your answers and requires only missing decisions/approvals. See the
[dependency matrix](../skills/apple-platform-setup/references/dependencies.md).
Lightweight setup uses direct capability checks; coordinated profiles also use
the harness and its health report.

Installed → configured → authenticated when needed → exposed → verified.
Each step is a separate observation. A setup report names remaining work; files
copied or a successful login alone do not mean an app task was verified. Existing
environments resume from their working state rather than repeating installation.

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

Choose consumer preferences using [customization](customization.md). Ordinary
local and PR tasks can use standalone skills; select the guarded runtime for
coordinated work or an explicitly requested runtime profile.

Describe the outcome, relevant constraints, and proof you want. For example:

> Use apple-platform-engineer to add a saved-items screen. Keep our storyboard navigation, design the component in a UIKit preview first, and verify empty and populated states on the minimum supported iOS version.

The agent resolves material ambiguity, checks existing decisions, and chooses the smallest plan. A simple fix needs neither a new ADR nor a graph. Larger work gets coherent reviewable slices; use explicit dependencies when slices actually depend on one another.

For several tasks, provide their acceptance criteria and ask the lead to inspect dependencies and the available worker slots. Five tasks do not imply five simultaneous agents: queue excess work, integrate same-repository edits through one writer, and bound builds and Simulator use. See [batch delegation](../skills/agent-harness/references/collaboration.md#delegate-a-batch-of-tasks).

## Run the verifier

Coordinated work uses the Swift verifier `apple-verify`, built from the installed
`agent-harness` folder. The build, path resolution, toolchain selection,
`--app-root` usage and command map ship inside that skill, so an installed copy
has them without this repository: follow
[Build and locate the verifier](../skills/agent-harness/references/swift-verification.md#build-and-locate-the-verifier).

For a single local task, run the applicable skill and focused verification. When several agents or tasks share build/Simulator resources, set up the [private host coordinator](../skills/agent-harness/references/coordinator-setup.md). Use `harness-local.json` for `local_verified`; its accepted plan explicitly selects whether independent review and Spec Kit are required. PR delivery uses the PR profile and stronger completion conditions.

Private setup files, credentials, observations, and run ledgers stay outside repositories. Preserve already supplied account and destination approvals; ask again only when an applicable policy requires it or the approved scope changes. See [verification](verification.md) for commands and [migration](../skills/agent-harness/references/swift-verification.md) before updating an existing runtime.
