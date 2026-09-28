# AI Workflow — Apple Platform Engineer

```text
  .-----------.
  |    </>    |  APPLE PLATFORM
  '-----+-----'  ENGINEER
      __|__
```

**Agent skills for building iOS, iPadOS, watchOS and macOS apps with SwiftUI, UIKit and Xcode, in Claude Code and Codex.**

Apple Platform Engineer gives your AI coding agent a practical workflow for native Apple apps. It helps the agent design, build, debug, test, and prepare reviewable changes using Apple documentation and Xcode tools. It is for developers and small teams working on new or existing Apple-platform projects.

Claude Code and Codex are supported equally: the same skills and skill names (`/name` in Claude Code, `$name` in Codex), and the same install command with a different `-a` value. The skills are standard Agent Skills Markdown that other clients may load, but the collection supports and documents only these two, and its optional guarded runtime runs only with them.

Previously **iOS Experts** (`ShawnBaek/iOS-experts`, which now redirects here).

## What it helps you do

- **Design before adding logic.** Explore real UI in Xcode Previews, or work from a Figma reference.
- **Find the cause of slow UI.** Investigate scrolling, launch time, and memory use with focused measurements.
- **Verify what changed.** Choose meaningful tests and capture screenshots or short recordings for review.
- **Keep changes easy to review.** Break larger tasks into coherent PRs with relevant evidence.
- **Keep development work organized.** Coordinate repository changes, Simulator use, and package/build resources.

## Get started

Install the starter set with the [Skills CLI](https://www.skills.sh/docs/cli). This command installs it for your user (`-g`) in Claude Code; use `-a codex` for Codex, or `-a claude-code codex` for both:

```sh
npx skills add ShawnBaek/ai-workflow-apple-platform-engineer -g -a claude-code \
  --skill apple-platform-engineer agent-harness apple-platform-setup \
  apple-development-health xcode-project-workflow xcodebuild core-simulator-health \
  apple-platform-ui xcode-preview-design apple-platform-testing screenshot \
  git-workflow code-review open-xcode-handoff
```

With `-g`, the skills work in every repository (`~/.claude/skills` for Claude Code, linked to a copy in `~/.agents/skills`; `~/.agents/skills` for Codex). Without it, they install into the current directory, so run the command from your app repository. Add a specialist later with the same command and its name, or use `--skill '*'` for the whole collection. Keep `agent-harness` installed: the lead and many specialists follow its shared references (see the [catalog](docs/skills.md)). Its guarded Swift runtime stays opt-in.

Apple builds and Simulator work require macOS and Xcode. Follow the [getting-started guide](docs/getting-started.md) before running coordinated app tasks.

Already installed? Follow the [update guide](docs/updating.md) for Skills CLI, linked-checkout or versioned-bundle installations.

## After installation

For a new environment, run **`$apple-platform-setup Set up this app for local development and PR delivery`** in Codex (use `/apple-platform-setup` in Claude Code). The agent checks the needed tools, guides missing setup, and verifies connections. Optional integrations stay optional.

Open your app repository in the client you installed for. Start with **`apple-platform-engineer`**, the main skill's name, and describe what you want to build.

| Client | Type in the chat |
| --- | --- |
| [Codex](https://learn.chatgpt.com/docs/build-skills) | `$apple-platform-engineer Add a saved-items screen and verify the empty state.` |
| [Claude Code](https://code.claude.com/docs/en/skills) | `/apple-platform-engineer Add a saved-items screen and verify the empty state.` |

Include your minimum OS, existing UI approach, reference apps and preferred style when known, and the proof you want. For open design choices, the agent clarifies missing preferences and researches useful references. For a focused task, use the same client prefix with one of these skills:

| Task | Skill name |
| --- | --- |
| Build or fix SwiftUI, UIKit or storyboard UI | `apple-platform-ui` |
| Design a screen in Xcode Previews | `xcode-preview-design` |
| Build, run or debug on Simulator | `xcodebuild` |
| Show an agent's worktree or sandbox changes in the Xcode you have open | `open-xcode-handoff` |
| Choose and run focused tests | `apple-platform-testing` |

For listing images and recorded previews, use **`$app-store-screenshots Prepare screenshots and a preview from this release build`** (Claude Code: `/app-store-screenshots`). Captures stay tied to the intended app version/build.

See [all skills](docs/skills.md). Each skill supplies guidance; it does not require a separate agent.

## How the workflow works

```text
Describe what you want to build
              |
              v
Clarify outcome + references + style
              |
              v
Research as needed + plan tasks
              |
              v
Design in Preview / Figma (UI work)
              |
              v
Implement + integrate
              |
              v
Verify + capture evidence
              |
              v
Review when needed -> fix -> recheck
              |
              v
Local result or approved PRs
```

[Small changes](skills/agent-harness/references/small-change-path.md), such as one button style, skip unrelated stages. [Multiple tasks](skills/agent-harness/references/collaboration.md#delegate-a-batch-of-tasks) use a bounded worker pool with explicit checkout, folder and permission boundaries. Independent research/review can overlap; same-repository writes and heavy jobs follow their resource limits. For approved PR delivery, split larger changes into focused or stacked PRs with relevant screenshots, recordings or JSON evidence.

## Adapt it to your project

Use individual skills with your existing tools and project policy. Figma, Sketch,
Trello, GitHub Projects, 1Password, and the guarded Swift runtime are opt-in. Authorized
personal and organization repositories are supported; this collection's owner
is only the upstream installation/report destination.

See [customization](docs/customization.md) for private preferences, supported
runtime profiles, design sources, and evidence publication. Public examples use
synthetic data. The collection is available under the [MIT license](LICENSE);
linked third-party projects retain their own licenses.

## Explore

[Skills](docs/skills.md) · [Workflow](skills/apple-platform-engineer/SKILL.md) · [Verification](docs/verification.md) · [Changelog](CHANGELOG.md) · [Contribute](CONTRIBUTING.md) · [Report a problem](skills/skill-maintenance/SKILL.md)

**Version:** 2.0.0-beta.11
