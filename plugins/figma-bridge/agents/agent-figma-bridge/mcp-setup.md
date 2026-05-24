# Figma MCP server setup — Claude Code & Codex

The Figma MCP server is the engineer's read/write bridge to a Figma file. Once connected, the agent can: fetch design context, screenshots, metadata, variable defs, generate SwiftUI from a frame, post comments back. Without it, you're working from copy-pasted screenshots.

## Prerequisites

- Figma Professional, Organization, or Enterprise seat (Dev Mode + MCP server are not in the Starter / free tier).
- A Figma personal access token (`Settings → Account → Personal access tokens`). For Org/Enterprise, an OAuth flow is also available.
- A modern editor with MCP support: Claude Code v2.0.12+, Codex (recent versions), or VS Code with the MCP extension.

## Install in Claude Code

The official one-liner (uses Figma's hosted MCP endpoint, requires you to sign in):

```bash
claude mcp add figma --url https://mcp.figma.com/v1 --transport http
```

Then restart Claude Code. The tools surface under `mcp__figma__*` (or `mcp__Figma_remote_mcp__*` depending on the registration). Verify:

```bash
# In Claude Code:
/mcp list
```

You should see `figma` listed. If your seat isn't eligible, the connection succeeds but `whoami` returns an error — fix the seat tier before continuing.

Alternative (local NPM-hosted variant if Figma adds one — check Figma's docs first):

```bash
claude mcp add figma --command npx -- -y @figma/mcp@latest
```

## Install in Codex

For the OpenAI Codex CLI / VS Code Codex extension. Per Figma's launch post (https://www.figma.com/blog/introducing-codex-to-figma/), the setup is the same MCP configuration in a different host.

**VS Code Codex extension:**

```bash
code --add-mcp '{"name":"figma","transport":"http","url":"https://mcp.figma.com/v1"}'
```

Restart VS Code. The MCP tools become available to Codex via the same JSON-RPC pipe.

**Codex CLI:**

Codex reads MCP config from `~/.codex/mcp.json` (path may vary — check `codex --help mcp`). Append:

```json
{
  "mcpServers": {
    "figma": {
      "transport": "http",
      "url": "https://mcp.figma.com/v1"
    }
  }
}
```

Reference: https://developers.openai.com/codex/use-cases/figma-designs-to-code

## Tools the server exposes

After connection, the most-used MCP tools (filter by prefix `mcp__figma__` or whatever your host registers):

| Tool | Use |
|------|-----|
| `whoami` | Sanity check — confirm the auth is working and you can see your account |
| `get_metadata(fileKey, nodeId?)` | Walk file structure: pages, frames, components, variants. Cheap, doesn't pull pixel data. |
| `get_design_context(fileKey, nodeId)` | Full design payload for a node: layout, styles, text, variants, applied tokens. Drives `generate_figma_design`. |
| `get_screenshot(fileKey, nodeId)` | PNG render of a node. Use for visual diffs against your built UI. |
| `get_variable_defs(fileKey)` | All design tokens (color/text/number/boolean variables) — what you'd map to a Swift `Theme` enum. |
| `get_code_connect_map(fileKey)` | Existing Code Connect mappings for components in this file. Tells you what's already wired. |
| `add_code_connect_map(...)` | Register a new mapping from a Figma component to a SwiftUI type. |
| `generate_figma_design(fileKey, nodeId)` | Generate framework code (SwiftUI / SwiftUI-For-Web / React) from a node. **Read [`generate-from-frame.md`](generate-from-frame.md) before calling.** |
| `get_figjam(fileKey)` | FigJam variant — for diagrams, not for app screens. |

Full list: https://developers.figma.com/docs/figma-mcp-server/tools-and-prompts/

## URL parsing

The MCP tools want `fileKey` and `nodeId` separately. Figma URLs look like:

```
https://www.figma.com/design/<fileKey>/<fileName>?node-id=<nodeId>
                                                            ↑ convert "-" to ":"
```

So `?node-id=1234-5678` becomes `nodeId = "1234:5678"`. Branch URLs (`/branch/<branchKey>/`) carry the branch key — the MCP server is branch-aware.

## Permissions

The MCP server respects Figma file permissions. If `get_design_context` returns "Not authorized," the engineer needs view access on the file in the Figma UI. **Surface the error, don't retry** — the engineer needs to request access from the file owner.

## Self-review before continuing

- [ ] `whoami` returned the engineer's account, not an error.
- [ ] At least one file's `fileKey` is known and accessible (test with `get_metadata`).
- [ ] If using the GitHub Code Connect UI ([`code-connect.md`](code-connect.md)), the engineer has admin on the GitHub repo to install the Figma GitHub app.

## References

- **Figma MCP guide** → https://help.figma.com/hc/en-us/articles/32132100833559
- **MCP tools and prompts** → https://developers.figma.com/docs/figma-mcp-server/tools-and-prompts/
- **Figma → Claude Code blog** → https://www.figma.com/blog/introducing-claude-code-to-figma/
- **Figma → Codex blog** → https://www.figma.com/blog/introducing-codex-to-figma/
- **OpenAI Codex Figma use cases** → https://developers.openai.com/codex/use-cases/figma-designs-to-code
