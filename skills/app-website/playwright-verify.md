# Browser verification — mandatory before declaring done

You do not say "done" until the page is loaded in a real browser, the console is clean, and you have screenshots. Web is not native — you cannot reason about layout in your head the way the `apple-platform-ui` agent can about SwiftUI. Browsers have edge cases (module resolution, content-type negotiation, importmap support, framework version drift, CSS specificity battles, image decode timing) that only show up at runtime.

## Canonical verification loop

Every time you change web code:

1. **Start a static server** in the project root with **no-cache headers** (critical — see "Cache discipline" below). Use the project's development server or `npx serve -c serve.json` with `"headers": [{ "source": "**", "headers": [{ "key": "Cache-Control", "value": "no-store" }] }]`.
2. **Load the page** in a browser via Playwright MCP / Chrome MCP (or whichever browser-automation MCP your host exposes), in a **fresh tab**.
3. **Read the console** for errors and exceptions. Module resolution errors (`Failed to resolve module specifier`), SyntaxErrors (`does not provide an export named ...`), and 404s on assets all fail silently if you only look at the screenshot.
4. **Scroll through every section** and screenshot each. Every section. Don't stop at the hero — the failure mode you're trying to catch is "section 4 doesn't render".
5. **Verify functionally, not just structurally.** For each `<img>` confirm `naturalWidth > 0` (not just that the element exists). For each interactive element (tap badges, share links), exercise the handler via the browser MCP's `computer.left_click` or `javascript_tool` and confirm it does the thing.
6. **Screenshot at mobile** (≤ 480 wide). Confirm `.row-wrap` collapsed rows to columns, headlines don't overflow, no element clipped.
7. **Only then** report the change as complete.

If any step fails: fix the issue, refresh with a cache-buster (`?v=2`) or hard reload, re-verify. Do not handwave "should be fine."

A blank white page is the most common failure mode — it means your JS errored before any DOM was created. The console will tell you why. Read it.

## Verify functionally — not just "the page loaded"

A page can return 200, have a clean console, and still be broken in ways a single screenshot misses. **Before telling the developer "go look,"** confirm each of these via `javascript_tool` or interaction:

| Check | How |
|-------|-----|
| Every `<img>` actually loaded | `Array.from(document.querySelectorAll('img')).map(i => ({src: i.src, ok: i.naturalWidth > 0}))` — every `ok` must be `true` |
| `<model-viewer>` rendered | `document.querySelectorAll('model-viewer').length > 0` and visually confirm the 3D content (not just the poster) |
| Tap-to-open buttons work | Click the App Store badge → confirm a new tab opens to the App Store URL |
| Copy-link works | Click → check `navigator.clipboard.readText()` returned the right URL |
| Dark mode follows OS | Switch the OS theme (or use `Emulation.setEmulatedMedia`) — confirm colors invert |
| Responsive collapse | Resize to 375px width — confirm features stack vertically |

**If `naturalWidth === 0` on any `<img>`** — that image didn't load. Common causes: wrong URL, 404, ad blocker (placehold.co is sometimes blocked), corporate proxy, mixed content (http img on https page).

**Telling the developer "open localhost:8000" is the LAST step.** Not the first response to "show me the demo." Earn the right to do it by visually + functionally verifying first.

## Cache discipline (the lesson learned the hard way)

Use explicit cache headers during development and inspect the served response when edits appear stale.

### Always serve with no-cache headers during development

Use the existing development server where available. For a static site, put this in `serve.json`:

```json
{"headers": [{"source": "**", "headers": [{"key": "Cache-Control", "value": "no-store"}]}]}
```

Run `npx serve -c serve.json -l 8000`. Verify with `curl -sI http://localhost:8000/main.js` and inspect `Cache-Control`. No custom server helper is needed.

### When the cache still bites

Even with no-cache, Chrome's *module* cache is persistent across page reloads. Three escalating fixes:

1. **Query-string buster on the script tag**: change `<script src="./main.js">` to `<script src="./main.js?v=2">` in `index.html`. Bump the number whenever modules don't update.
2. **Query-string busters on imports inside main.js**: `import { X } from './sections/X.js?v=2';` — needed for transitive modules.
3. **Close the tab, open a fresh one.** Don't just reload — Chrome's module cache survives reload, doesn't survive tab close.

### When the developer says "I see the old version"

Hand them this:

> Hard-refresh: `Cmd+Shift+R` (Mac) / `Ctrl+Shift+R` (Win). If that doesn't work, close the tab and open a fresh one. The cache buster on `index.html` (e.g. `?v=2`) tells the browser to fetch fresh modules — bump it and re-share the URL.

If they still see old, walk through it together — open DevTools → Network tab → check "Disable cache" → reload. That's the nuclear option.

## Install Playwright MCP (one-time, per host)

If the host doesn't already have a browser-automation MCP, install **Playwright MCP** (https://github.com/microsoft/playwright-mcp). Prerequisite: **Node.js 18+**.

### Claude Code
```bash
claude mcp add playwright npx @playwright/mcp@latest
# Optional: --scope user (global) or --scope project (versioned in repo)
```
Persists to `~/.claude.json` (user scope) or `.mcp.json` (project scope).

### VS Code
With the MCP-capable Copilot/Continue extension:
```bash
code --add-mcp '{"name":"playwright","command":"npx","args":["@playwright/mcp@latest"]}'
```
Or interactively: **Command Palette → "MCP: Add Server"**.

### Codex CLI (or any other MCP-compatible client)
Drop this into the host's MCP config file (often `~/.codex/config.json` or `~/.config/<host>/mcp.json` — check the host's docs):
```json
{
  "mcpServers": {
    "playwright": {
      "command": "npx",
      "args": ["@playwright/mcp@latest"]
    }
  }
}
```

### Common flags
Append to the `args` array:
- `--headless` — no UI window (faster in CI, less useful for visual debugging)
- `--browser=firefox` or `--browser=webkit` — default is Chromium
- `--isolated` — fresh profile per session

### Verify the install
Ask your agent: *"Use Playwright to navigate to https://example.com and screenshot it."* If the screenshot comes back, you're set.

## Bonus — Playwright Test Agents

https://playwright.dev/docs/test-agents — for projects that have Playwright tests, bootstrap planner/generator/healer subagents:

```bash
npx playwright init-agents --loop=claude     # for Claude Code
npx playwright init-agents --loop=vscode     # for VS Code
npx playwright init-agents --loop=opencode   # for OpenCode CLI
```

Generates project-local agent loops that explore the app, write Playwright tests, and self-heal failing ones. Optional but worth knowing about — for an indie one-pager you can skip it.

## Sources

- [Playwright Test Agents](https://playwright.dev/docs/test-agents)
- [microsoft/playwright-mcp](https://github.com/microsoft/playwright-mcp)
- [@playwright/mcp on npm](https://www.npmjs.com/package/@playwright/mcp)
- [VS Code MCP docs](https://code.visualstudio.com/docs/copilot/customization/mcp-servers)
