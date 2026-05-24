# indie-native-app

Claude Code **plugin marketplace** for indie developers shipping **Apple-platform native apps end-to-end** — from blank Xcode project to App Store submission, on your own (or with a designer), without a DevOps team.

Nine agents that share one job: kill the time-sinks that make shipping native apps painful. **Two paths for the UI layer** — pick the one that matches your situation:

| Situation | UI path |
|---|---|
| Pure indie, no designer, no Figma file | [`apple-platform-ui`](plugins/apple-platform-ui/README.md) directly — agent makes HIG-anchored decisions itself |
| Designer hands you a Figma file (or you have your own Figma mockup) | [`figma-bridge`](plugins/figma-bridge/README.md) → [`apple-platform-ui`](plugins/apple-platform-ui/README.md) — Figma extraction, then HIG polish |

## The nine agents

| Agent | When to invoke | What it owns |
|-------|----------------|--------------|
| [`apple-platform-ui`](plugins/apple-platform-ui/README.md) | "Build me a screen", "design this view", "SwiftUI / UIKit" | UI implementation in SwiftUI/UIKit, grounded in Apple HIG (pure-indie path) |
| [`figma-bridge`](plugins/figma-bridge/README.md) | "Figma", "generate from this frame", "code connect", "review my figma file", "set up figma mcp" | Figma → SwiftUI handoff. MCP setup (Claude Code + Codex), Code Connect for SwiftUI, generate-from-frame, dev-friendliness file review, `// figma:` sitemap convention. Hands off to `apple-platform-ui` for HIG polish. |
| [`apple-platform-performance`](plugins/apple-platform-performance/README.md) | "App is janky", "scroll stutters", "launch is slow", "Instruments shows…" | Hangs / hitches / launch / body cost / ML inference / audio pipeline — 27 Effective-style items in 6 Parts |
| [`xcodebuild`](plugins/xcodebuild/README.md) | "Build", "run on sim", "screenshot the screen", "attach debugger" | Xcode builds + simulator + UI automation via XcodeBuildMCP (XcodeGen-aware) |
| [`screenshot`](plugins/screenshot/README.md) | "App Store screenshots", "capture and upload" | End-to-end App Store screenshot pipeline (capture → frame → upload) |
| [`app-store-connect`](plugins/app-store-connect/README.md) | "TestFlight", "submit", "store metadata", "crash reports" | App Store Connect ops via the asc CLI (iOS / macOS / Mac Catalyst / watchOS / visionOS) |
| [`app-website`](plugins/app-website/README.md) | "Build my app's landing page", "one-pager", "download page" | One-page introduction website via SwiftUI-For-Web + Gridlover rhythm |
| [`cicd`](plugins/cicd/README.md) | "Set up CI", "GitHub Actions workflow", "self-hosted runner", "deploy on tag" | GitHub Actions on a self-hosted Mac runner; `act` local testing; `gh` CLI secrets; failure routing |
| [`commit-message`](plugins/commit-message/README.md) | "Write a commit message for this", right before `git commit` | Good commit messages from the staged diff (Conventional, Swift `[area]`, or plain) |

Each agent has its own README in `plugins/<name>/README.md` with detailed setup, prerequisites, and example commands.

## The end-to-end flow

```
   [optional: figma-bridge]  →   apple-platform-ui        apple-platform-performance        xcodebuild
        ↓                              ↓                         ↓                       ↓
   Figma MCP setup,              SwiftUI code              Hangs / hitches /        Build + run on
   Code Connect for SwiftUI,     with mocks,               launch / body cost /     simulator;
   generate from frame,    →     Light/Dark/XXL    →       ML inference / audio →   capture logs;
   // figma: sitemap             previews,                 — 27 Effective items     UI tests
   (skip if no Figma file)       HIG polish                + XCTMetric tests
                                                          ↓
                            screenshot                app-store-connect
                                 ↓                         ↓
                        Capture App Store           Upload IPA,
                        shots; frame;          →    TestFlight,
                        upload via asc              submit for review
                                 ↓                         ↓
                                 └─── app-website ────────┘
                                       (screenshots feed the
                                        Features section;
                                        App Store URL feeds
                                        the Download badge)

   commit-message sits across all of them — invoked right before any `git commit`
   to turn the staged diff into a properly-formatted, useful message.

   cicd wraps the whole loop — GitHub Actions on a self-hosted Mac runner
   builds + tests on every PR, archives + ships to TestFlight on tag push.
   Failures route back to xcodebuild / app-store-connect / apple-platform-performance
   for diagnosis.
```

## Install

### One-liner per plugin (recommended)

Uses the [claude-plugins](https://claude-plugins.dev) CLI from your terminal — handles both marketplace-add and plugin-install in one call. Requires **Claude Code v2.0.12+**.

```bash
npx claude-plugins install @shawnbaek/agent-design/apple-platform-ui
npx claude-plugins install @shawnbaek/agent-design/figma-bridge
npx claude-plugins install @shawnbaek/agent-design/apple-platform-performance
npx claude-plugins install @shawnbaek/agent-design/xcodebuild
npx claude-plugins install @shawnbaek/agent-design/screenshot
npx claude-plugins install @shawnbaek/agent-design/app-store-connect
npx claude-plugins install @shawnbaek/agent-design/app-website
npx claude-plugins install @shawnbaek/agent-design/cicd
npx claude-plugins install @shawnbaek/agent-design/commit-message
```

List / enable / disable installed plugins:
```bash
npx claude-plugins list
npx claude-plugins disable <plugin-name>
npx claude-plugins enable <plugin-name>
```

### Interactive alternative (inside Claude Code)

```text
/plugin marketplace add shawnbaek/agent-design
/plugin install apple-platform-ui@indie-native-app
# … one per plugin
```

Update later: `/plugin marketplace update indie-native-app`
Uninstall: `/plugin uninstall <plugin-name>@indie-native-app`

## External tools (some agents wrap third-party CLIs / MCP servers)

| Agent | External dependency | Install once |
|-------|---------------------|--------------|
| `apple-platform-ui` | none (uses Xcode itself) | — |
| `figma-bridge` | **Figma MCP server** + (optional) **Code Connect Swift package** | `claude mcp add figma --url https://mcp.figma.com/v1 --transport http` (or the Codex equivalent); `.package(url: "https://github.com/figma/code-connect", from: "1.0.0")` in `Package.swift` |
| `apple-platform-performance` | Instruments + XCTest (ship with Xcode) | — |
| `xcodebuild` | **XcodeBuildMCP** ([xcodebuildmcp.com](https://www.xcodebuildmcp.com)) | `npx -y xcodebuildmcp@latest mcp` via Claude Code MCP config |
| `screenshot` | XcodeBuildMCP + asc CLI | both via the agents above |
| `app-store-connect` | **asc CLI** ([asccli.sh](https://asccli.sh)) | `brew install asc` |
| `app-website` | **SwiftUI-For-Web** ([repo](https://github.com/ShawnBaek/SwiftUI-For-Web)) | `npm install swiftui-for-web` |
| `cicd` | **`gh` CLI** + **`act`** + a Mac self-hosted runner | `brew install gh act` |
| `commit-message` | `git` | already on your machine |

The agents walk you through each install on first run.

## See it in action

Two paired reference projects — one is the app, one is the site that markets it:

- **[`examples/NotesJournal/`](examples/NotesJournal/)** — multiplatform SwiftUI notes/journal app generated by `apple-platform-ui`. iOS + iPadOS + macOS + watchOS from one shared codebase. Every view ships with Light / Dark / XXL previews.
- **[`examples/NotesJournalWebsite/`](examples/NotesJournalWebsite/)** — one-page introduction website for that app, generated by `app-website`. SwiftUI-For-Web, Gridlover vertical rhythm, all 5 sections wired up. Deploys to GitHub Pages out of the box.

See each example's README for a tour of which principle each file demonstrates.

## Repo layout

```
agent-design/
├── .claude-plugin/
│   └── marketplace.json                       # marketplace catalog (name: indie-native-app)
├── plugins/
│   ├── apple-platform-ui/
│   │   ├── .claude-plugin/plugin.json
│   │   ├── README.md
│   │   └── agents/agent-apple-platform-ui.md
│   ├── figma-bridge/
│   │   ├── .claude-plugin/plugin.json
│   │   ├── README.md
│   │   └── agents/
│   │       ├── agent-figma-bridge.md          # router
│   │       └── agent-figma-bridge/
│   │           ├── mcp-setup.md                # Claude Code + Codex MCP install
│   │           ├── code-connect.md             # SwiftUI Code Connect (CLI + GitHub UI)
│   │           ├── sitemap.md                  # // figma: URL comment convention
│   │           ├── figma-review.md             # developer-friendliness audit
│   │           └── generate-from-frame.md      # generate_figma_design + avoid-large-frames
│   ├── apple-platform-performance/
│   │   ├── .claude-plugin/plugin.json
│   │   ├── README.md
│   │   └── agents/agent-apple-platform-performance.md
│   ├── xcodebuild/
│   │   ├── .claude-plugin/plugin.json
│   │   ├── README.md
│   │   └── agents/agent-xcodebuild.md
│   ├── screenshot/
│   │   ├── .claude-plugin/plugin.json
│   │   ├── README.md
│   │   └── agents/agent-screenshot.md
│   ├── app-store-connect/
│   │   ├── .claude-plugin/plugin.json
│   │   ├── README.md
│   │   └── agents/agent-app-store-connect.md
│   ├── app-website/
│   │   ├── .claude-plugin/plugin.json
│   │   ├── README.md
│   │   └── agents/agent-app-website.md
│   ├── cicd/
│   │   ├── .claude-plugin/plugin.json
│   │   ├── README.md
│   │   └── agents/agent-cicd.md
│   └── commit-message/
│       ├── .claude-plugin/plugin.json
│       ├── README.md
│       └── agents/agent-commit-message.md
└── examples/
    ├── NotesJournal/                          # multiplatform SwiftUI app from apple-platform-ui
    │   ├── README.md
    │   └── Sources/
    └── NotesJournalWebsite/                   # one-page marketing site from app-website
        ├── README.md
        ├── index.html
        ├── main.js
        ├── sections/
        ├── styles/
        └── assets/
```

## Philosophy

Indie developers ship. They don't theme, don't have a release engineer, don't have a perf team, and don't have time to read every doc.

Each agent saves the most expensive thing — the loop of *do it, realize you missed a step, do it again*:

- **apple-platform-ui** kills the rebuild-tweak loop by reasoning through layout in-head before ⌘R.
- **figma-bridge** kills the design-handoff-as-screenshot loop — wires the Figma MCP server, sets up Code Connect for SwiftUI, generates first-draft code from a chosen frame, then hands off to apple-platform-ui for the HIG polish. The Figma path complements (doesn't replace) the pure-indie path.
- **apple-platform-performance** kills the "ship → real users complain → reverse-engineer the regression" loop by gating it in CI with XCTMetric.
- **xcodebuild** kills the "what's the destination flag again" loop.
- **screenshot** kills the multi-hour manual screenshot ritual.
- **app-store-connect** kills the App Store Connect web-UI loop (and the 24h rejection cycle by always pre-flighting).
- **app-website** kills the "I'll just put a `<div>About</div>` page up" loop by giving you a typography-first one-pager in the same SwiftUI style as the app.
- **cicd** kills the "commit, push, wait 8 minutes, fail" loop by running workflows locally with `act` first, then deploying via `gh` CLI + a self-hosted Mac.
- **commit-message** kills the `git log | grep wip` loop.

Default to system. Deviate only when there's a real reason.

## Naming conventions

- **Plugins** live in `plugins/<short-name>/` (e.g. `xcodebuild`). The plugin name in `plugin.json` matches the folder name.
- **Agents** live in `plugins/<short-name>/agents/agent-<name>.md` (e.g. `agent-xcodebuild`). All agent names start with `agent-`.
- **Sub-docs** for big agents live in `plugins/<short-name>/agents/agent-<name>/<topic>.md`. The router agent file stays small (overview + quick-reference table) and tells the subagent to `Read` the matching sub-doc when a topic comes up. Used today by `app-website` (6 sub-docs), `apple-platform-performance` (6 sub-docs: parts 1–6 including ML/audio), `cicd` (5 sub-docs), `figma-bridge` (5 sub-docs: mcp-setup, code-connect, sitemap, figma-review, generate-from-frame), and `apple-platform-ui` (2 sub-docs: keyboard, launch-screen).

## Publish / contribute

To validate locally before pushing:

```text
/plugin marketplace add ./
/plugin install apple-platform-ui@indie-native-app
```

To list this marketplace in the [Anthropic community marketplace](https://github.com/anthropics/claude-plugins-community) so anyone can find it, submit at https://platform.claude.com/plugins/submit.

Adding a new agent: copy any `plugins/<existing>/` as a template, update the `plugin.json` and `agents/agent-<name>.md`, add an entry to `.claude-plugin/marketplace.json`, and add a README.
