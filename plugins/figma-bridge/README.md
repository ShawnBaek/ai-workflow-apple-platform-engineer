# figma-bridge

The Figma path for engineers shipping Apple-platform apps.

Two paths for UI work in this marketplace:

| Situation | Use | Path summary |
|---|---|---|
| Pure indie, no designer, no Figma file | [`apple-platform-ui`](../apple-platform-ui/README.md) | Agent makes every design decision itself, anchored in Apple HIG |
| Designer hands you a Figma file (or you have your own Figma mockup) | **`figma-bridge`** → `apple-platform-ui` | Extract design context from Figma; generate first-draft SwiftUI; then HIG polish |

`figma-bridge` is the second path. It assumes a Figma file exists and that you want the code to stay in sync with that design — not just a one-shot screenshot-to-code blast.

## What it does

1. **Sets up the Figma MCP server** for either Claude Code (`claude mcp add figma …`) or Codex (`code --add-mcp …` or codex CLI config). Both editors get the same MCP tools (`get_design_context`, `get_screenshot`, `get_metadata`, `get_variable_defs`, `generate_figma_design`, etc.).
2. **Establishes Code Connect for SwiftUI** so the engineer's real component code surfaces inside Figma's Dev Mode. Two install routes (CLI vs the GitHub plugin UI) — picks the one that fits the team's workflow.
3. **Generates SwiftUI from a selected Figma frame** via the MCP `generate_figma_design` tool. Knows the "avoid large frames" rule and walks the engineer through node selection when a frame is too big for MCP context.
4. **Maps codebase ↔ design with a lightweight code-connect map** — a one-line `// figma: <url>` comment on every screen / component file. Companion to the formal component-level Code Connect above; complements it at the file/screen level. Lets future engineers (and agents) jump between code and design without leaving the editor.
5. **Reviews a Figma file for developer-friendliness** — auto-layout coverage, components vs. raw groups, variants, consistent naming, frame size budgets, color/text-style discipline, missing or stale Code Connect mappings. Returns a punch list the designer can fix before handoff.
6. **Hands off to `apple-platform-ui`** for the HIG polish — Dynamic Type, dark mode, semantic colors, SF Symbols substitution, Light/Dark/XXL previews, Container + Presenter via mock UseCase. `figma-bridge` writes the first draft; `apple-platform-ui` ships it.

## When to use

- "I have a Figma file from the designer — turn this screen into SwiftUI."
- "Set up Code Connect for our component library."
- "Review this Figma file — is it ready for a developer to work from?"
- "Add Figma links into every view file as comments so we can navigate back."
- "Pull the latest Figma frame into the existing `ProfileView`."
- "Set up the Figma MCP server in Codex / Claude Code."

## When NOT to use

- You have no Figma file and don't plan to — go straight to [`apple-platform-ui`](../apple-platform-ui/README.md). HIG-anchored generation needs no design source.
- You want a screenshot-to-code one-shot with no plan to keep the design and code in sync — `figma-bridge` is overkill; ask Claude directly with the screenshot pasted in.

## Install

```bash
npx claude-plugins install @shawnbaek/agent-design/figma-bridge
```

Or inside Claude Code:

```text
/plugin marketplace add shawnbaek/agent-design
/plugin install figma-bridge@indie-native-app
```

## Prerequisites

| Need | Where to get it |
|------|-----------------|
| Figma account (Professional / Org / Enterprise for Dev Mode + MCP server) | https://www.figma.com |
| Figma MCP server access | https://help.figma.com/hc/en-us/articles/32132100833559 |
| Code Connect CLI (Swift) | https://github.com/figma/code-connect (Swift package) |
| Claude Code v2.0.12+ OR Codex with MCP support | — |

## References

- **Figma + Claude Code (official)** → https://www.figma.com/blog/introducing-claude-code-to-figma/
- **Figma + Codex (official)** → https://www.figma.com/blog/introducing-codex-to-figma/
- **OpenAI: Figma → Codex use cases** → https://developers.openai.com/codex/use-cases/figma-designs-to-code
- **Figma MCP server guide** → https://help.figma.com/hc/en-us/articles/32132100833559
- **MCP tools + prompts (including `generate_figma_design`)** → https://developers.figma.com/docs/figma-mcp-server/tools-and-prompts/
- **Avoid large frames** → https://developers.figma.com/docs/figma-mcp-server/avoid-large-frames/
- **Code Connect quickstart** → https://developers.figma.com/docs/code-connect/quickstart-guide/
- **Code Connect (SwiftUI)** → https://developers.figma.com/docs/code-connect/swiftui/
- **Code Connect via GitHub UI** → https://developers.figma.com/docs/code-connect/code-connect-ui-github/
- **Comparing Code Connect options (CLI vs UI)** → https://developers.figma.com/docs/code-connect/comparing-cc/

## Companion agents

- [`apple-platform-ui`](../apple-platform-ui/README.md) — receives the SwiftUI first draft from `figma-bridge`, runs the HIG polish pass, adds the 3 previews.
- [`xcodebuild`](../xcodebuild/README.md) — builds + runs the generated view on a simulator so you can see it.
- [`screenshot`](../screenshot/README.md) — capture the actual rendered view; useful as a "design vs. as-built" comparison to share back with the designer.
- [`commit-message`](../commit-message/README.md) — for the inevitable "feat(profile): wire ProfileView to figma frame X" commits.
