# Figma connection preflight

First inspect the current client's exposed Figma capabilities. Reuse an active
plugin/connection; do not register a duplicate server because its tool prefix
differs. Installation, authentication, file access and a successful tool response
are separate observations.

## When setup is actually missing

Use the client's supported Figma plugin or current manual MCP setup. Follow the
applicable installation/account approval policy; a verification request does not
require rewriting global client configuration. The official remote endpoint is
`https://mcp.figma.com/mcp` and uses OAuth. Do not request a personal access token
as a default prerequisite. Check current [access limits](https://developers.figma.com/docs/figma-mcp-server/rate-limits-access/)
instead of assuming every user needs a paid seat.

For an explicitly selected manual setup, verify the installed CLI's help first:

```sh
# Codex
codex mcp add figma --url https://mcp.figma.com/mcp

# Claude Code
claude mcp add --transport http figma https://mcp.figma.com/mcp
```

Authenticate through the client and inspect its connection status. Do not invent
a shared JSON config path for different clients. Codex uses its supported MCP
configuration/commands; VS Code's own MCP registration does not by itself prove
that another agent extension sees the server. Follow [Figma's client-specific setup](https://developers.figma.com/docs/figma-mcp-server/remote-server-installation/)
and the [Codex MCP reference](https://developers.openai.com/codex/mcp/).

## Verify the requested capability

Resolve the intended file/node URL and the account when needed. Use `whoami`
when required by the provider or when identity is unclear; do not dump account
or plan inventories into public evidence. Load any provider-required design
skill before its tool call, and use the exact exposed argument schema.

| Capability | Intended use |
|---|---|
| `get_design_context` | Read the selected design for native implementation |
| `get_metadata` | Inspect structure or narrow an oversized selection |
| `get_screenshot` / `download_assets` | Inspect or export the exact reference |
| `get_variable_defs` / `get_code_connect_map` | Reuse selected tokens and existing mappings |
| `generate_figma_design` / `use_figma` | Write interfaces/designs into Figma when explicitly in scope |

Parse the node from the supplied URL, preserving branch identity when present.
For example, URL node `123:456` may be encoded as `123-456`; adapt only as the
provider requires. A remote provider needs an explicit source; do not assume the
user's desktop selection is available.

Record one real successful read of the requested node. Tool discovery or login
alone is not design-export evidence. On a missing file, permission failure or
rate limit, preserve the exact blocker; do not test unrelated private files or
change credentials to find a working path. See [Figma's tool roles](https://developers.figma.com/docs/figma-mcp-server/tools-and-prompts/)
and [native implementation](generate-from-frame.md).
