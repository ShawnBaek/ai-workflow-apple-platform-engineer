# AI Workflow — Apple Platform Engineer

```text
  .-----------.
  |    </>    |  APPLE PLATFORM
  '-----+-----'  ENGINEER
      __|__
```

**Give your AI coding agent a practical workflow for building native Apple apps.**

Apple Platform Engineer is a collection of reusable skills for Codex and Claude Code. It helps your agent design, build, debug, test, and prepare reviewable changes using Apple documentation and Xcode tools.

Previously **iOS Experts**.

For new and existing iOS, iPadOS, watchOS, and macOS projects using SwiftUI or UIKit.

## What it helps you do

- **Design before adding logic.** Explore real UI in Xcode Previews, or work from a Figma reference.
- **Find the cause of slow UI.** Investigate scrolling, launch time, and memory use with focused measurements.
- **Verify what changed.** Choose meaningful tests and capture screenshots or short recordings for review.
- **Keep changes easy to review.** Break larger tasks into coherent PRs with relevant evidence.
- **Keep development work organized.** Coordinate repository changes, Simulator use, and package/build resources.

## Get started

Install with the [Skills CLI](https://www.skills.sh/docs/cli):

```sh
npx skills add ShawnBaek/ai-workflow-apple-platform-engineer
```

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
| Choose and run focused tests | `apple-platform-testing` |

For listing images and recorded previews, use **`$app-store-screenshots Prepare screenshots and a preview from this release build`** (Claude Code: `/app-store-screenshots`). Captures stay tied to the intended app version/build.

See [all 36 skills](docs/skills.md). Each skill supplies guidance; it does not require a separate agent.

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

Small fixes skip unrelated stages. [Multiple tasks](skills/agent-harness/references/collaboration.md#delegate-a-batch-of-tasks) use a bounded worker pool with explicit checkout, folder and permission boundaries. Independent research/review can overlap; same-repository writes and heavy jobs follow their resource limits. For approved PR delivery, split larger changes into focused or stacked PRs with relevant screenshots, recordings or JSON evidence.

## Explore

[Skills](docs/skills.md) · [Workflow](skills/agent-harness/SKILL.md) · [Verification](docs/verification.md) · [Contribute](CONTRIBUTING.md) · [Report a problem](skills/skill-maintenance/SKILL.md)

**Version:** 2.0.0-beta.9
