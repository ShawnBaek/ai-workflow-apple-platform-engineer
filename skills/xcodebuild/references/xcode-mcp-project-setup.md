# Register the Xcode MCP server per project

Register Apple's Xcode MCP bridge (`xcrun mcpbridge`) only in the repositories
that use Xcode, not for every session on the Mac. The steps are the same in
shape for Claude Code and Codex. Adding, moving, or removing a registration is a
persistent configuration change: get approval for the exact client, scope, and
file first, as the [provider preflight](xcode-mcp-provider-preflight.md)
requires. The client behavior below was checked on 2026-09-27 against each
client's documentation and CLI help (Claude Code 2.1.278, codex-cli 0.144.1),
and against the Codex source for that release where its documentation is silent.

## Why project scope

- Each process that runs `xcrun mcpbridge` is a new external agent to Xcode.
  Apple's documentation says that Xcode alerts you when an external agent
  connects and when it is active. On 2026-09-27, with Xcode 27.1 (27A9269) and
  Xcode 27.2 beta (27B5019j), and with "Allow external agents to use Xcode
  tools" set to Always in Xcode > Settings > Intelligence, every new bridge
  process still raised the alert.
- A client starts a bridge in each session or task where the server is
  registered. A Claude Code user-scope entry (`-s user`) or an entry in Codex's
  `~/.codex/config.toml` therefore starts a bridge, and raises an alert, in
  every repository, including ones that never use Xcode. `claude mcp list` and
  `claude mcp get` also start a bridge to health-check the server.
- A project registration limits bridges to sessions started in that
  repository. It does not reduce them there: each session in the repository
  still starts its own bridge and raises its own alert. Open only the parallel
  sessions that the task needs.

## At a glance

| | Claude Code | Codex |
|---|---|---|
| Shared file | `.mcp.json` at the repository root | `.codex/config.toml` at the repository root |
| Loads when | The folder is trusted and you approve the server once | The project is trusted |
| Written by | `claude mcp add --scope project`, or by hand | By hand; `codex mcp add` writes only the global file |
| Global entry to remove | User scope in `~/.claude.json` | `[mcp_servers.xcode]` in `~/.codex/config.toml` |
| Status without a new bridge | Read the configuration files | `codex mcp list` or `codex mcp get` |
| Personal Xcode choice | A local-scope `xcode` entry that sets `DEVELOPER_DIR` | `DEVELOPER_DIR` in the environment Codex starts in |
| Tool approvals | Permission rules named `mcp__xcode__<tool>` | Keys in `[mcp_servers.xcode]` and its `tools.<tool>` tables |

In the commands below, `<xcode>` is the selected installation, such as
`/Applications/Xcode-beta.app`.

## Claude Code

### Register in the repository

Commit this `.mcp.json` at the repository root, or add the `xcode` key to the
`mcpServers` object of an existing one:

```json
{
  "mcpServers": {
    "xcode": {
      "type": "stdio",
      "command": "xcrun",
      "args": ["mcpbridge"]
    }
  }
}
```

Running `claude mcp add --scope project --transport stdio xcode -- xcrun mcpbridge`
from the repository root creates or updates the same file. Apple's example
command has no `--scope`, so it registers at Claude Code's default local scope.
That scope also loads only in the project where you ran the command, but it is
personal rather than shared.

Claude Code expands `${VAR}` and `${VAR:-default}` in `command`, `args`, and
`env`, but passes an unset variable that has no default through as literal
text. So do not commit `"DEVELOPER_DIR": "${DEVELOPER_DIR}"`: for anyone who
has not set the variable, `xcrun` fails with
`missing DEVELOPER_DIR path: ${DEVELOPER_DIR}`. A default that names an Xcode
would commit a machine-specific path.

### Trust and approval

In an interactive session, Claude Code uses a `.mcp.json` server only after you
accept the folder's workspace trust dialog and approve the server. To reset
those approvals for the project, run `claude mcp reset-project-choices`. A clone
cannot approve its own servers: Claude Code ignores `enableAllProjectMcpServers`
or `enabledMcpjsonServers` committed in the project's `.claude/settings.json`
until you trust the folder. `claude -p` runs, cloud sessions, and Agent SDK
sessions whose `settingSources` include project settings load project servers
without asking, so they start a bridge too. Start such a run with
`--strict-mcp-config` when it must not connect to Xcode.

### Remove the global registration

```sh
claude mcp remove xcode -s user
```

Always name the scope. Without `-s`, the command removes the name from
whichever scope it finds it in, which can be the new project entry. Local-scope
entries in other repositories also start bridges there. List those
repositories with the command below, then run
`claude mcp remove xcode -s local` from each one that should not have it:

```sh
jq -r '.projects // {} | to_entries[] | select(.value.mcpServers.xcode) | .key' ~/.claude.json
```

Sessions that are already running keep their bridge until they end.

### Verify without extra bridges

From the repository root, read the configuration instead of asking the CLI:

```sh
jq '.mcpServers.xcode' .mcp.json                                   # shared entry
jq '.mcpServers.xcode // "none"' ~/.claude.json                    # user scope: expect "none"
jq --arg p "$PWD" '.projects[$p].mcpServers.xcode // "none"' ~/.claude.json  # your local entry
```

Do not use `claude mcp list` or `claude mcp get` for this. They health-check
each approved server by connecting to it, which starts a bridge. They show a
`.mcp.json` server that you have not approved as pending, without connecting to
it. After these reads, start one session in the repository, approve the server
if asked, and check `/mcp`. Confirm which Xcode answered with the
[bridge checks](xcode-mcp-provider-preflight.md#bind-the-bridge-to-the-selected-xcode).
A new session in an unrelated repository should start no bridge.

### Select the Xcode

The shared entry names no Xcode, so its bridge uses the one that `xcode-select`
selects. When the
[selected Xcode](../../xcode-project-workflow/references/xcode-selection.md) is
a different one, add a personal local-scope entry from the repository root:

```sh
claude mcp add --scope local --env DEVELOPER_DIR=<xcode>/Contents/Developer \
  --transport stdio xcode -- xcrun mcpbridge
```

Local scope takes precedence over project scope, and Claude Code uses the whole
entry from the winning scope without merging fields. This entry therefore
replaces the shared one for you only. Claude Code stores it in `~/.claude.json`
under this repository's path and loads it nowhere else. Keep an option such as
`--transport stdio` between `--env` and the server name, or `--env` reads the
name as another variable. Replace the entry, or remove it with
`claude mcp remove xcode -s local`, when the selection changes. Claude Code's
documentation does not say whether a stdio server inherits the environment that
Claude Code starts in, so do not rely on starting Claude Code with
`DEVELOPER_DIR` set.

### Tool approvals

Permission rules name the server, not its scope. Rules such as
`mcp__xcode__<tool>` or `mcp__xcode__*` in any settings file keep working after
the move, as long as the server keeps the name `xcode`.

## Codex

### Register in the repository

Commit this `.codex/config.toml` at the repository root, or add the table to an
existing one:

```toml
[mcp_servers.xcode]
command = "xcrun"
args = ["mcpbridge"]
env_vars = ["DEVELOPER_DIR"]
```

`codex mcp add` has no project option and writes only `~/.codex/config.toml`,
so write this file by hand. Codex reads each `.codex/config.toml` from the
project root, by default the nearest directory that contains `.git`, down to the
working directory; the closest file wins. `env_vars` is explained under
"Select the Xcode" below.

### Trust and approval

Codex loads a project's `.codex/` layers only when you trust the project. For
an untrusted project, it ignores them and loads only user and system
configuration. When a folder has no trust decision, the Codex CLI asks at
startup and records the answer in `~/.codex/config.toml` as
`[projects."<path>"]` with `trust_level = "trusted"` or `"untrusted"`. The
ChatGPT desktop app, the Codex CLI, and the IDE extension share this
configuration; restart the app or the IDE extension after you change it. Every
session in a trusted project, including `codex exec` runs, starts a bridge.
Start such a run with `-c mcp_servers.xcode.enabled=false` when it must not
connect to Xcode.

### Remove the global registration

First copy the tool settings that you want to keep into the project entry:
the `default_tools_approval_mode`, `enabled_tools`, and `disabled_tools` keys of
`[mcp_servers.xcode]`, and any `[mcp_servers.xcode.tools.<tool>]` tables, as
described under "Tool approvals" below. Then run:

```sh
codex mcp remove xcode
```

It edits only `~/.codex/config.toml` and removes the whole entry, including
those keys and its `tools` tables. If you edit the file by hand, delete
`[mcp_servers.xcode]` together with every `[mcp_servers.xcode.*]` table under
it. A leftover table is an entry without `command`, which Codex rejects.
Restart the app or the IDE extension, and start new CLI sessions.

### Verify without extra bridges

From the repository root:

```sh
# User and system configuration only; expect "No MCP server named 'xcode' found."
(cd / && codex mcp get xcode)
# The project entry.
codex mcp get xcode --json
```

`codex mcp list` and `codex mcp get` read the configuration and do not start
stdio servers. Run inside the repository, they include the project file when the
project is trusted. If `get` finds no `xcode` server there, check the trust
decision. Run from an unrelated repository, it should find none. After these
checks, start one session in the repository, check `/mcp`, and confirm which
Xcode answered with the
[bridge checks](xcode-mcp-provider-preflight.md#bind-the-bridge-to-the-selected-xcode).

### Select the Xcode

Codex starts a stdio server with a cleared environment. It passes on only a
short list of basics, such as `HOME`, `PATH`, and `USER`, plus the variables
named in `env_vars` and the values in the entry's `env` table. With
`env_vars = ["DEVELOPER_DIR"]`, the bridge receives `DEVELOPER_DIR` when it is
set in the environment Codex starts in. When it is not set, the bridge does not
receive it and uses the Xcode that `xcode-select` selects. Start Codex with the
[selected Xcode](../../xcode-project-workflow/references/xcode-selection.md):

```sh
DEVELOPER_DIR=<xcode>/Contents/Developer codex
```

The desktop app and the IDE extension do not start from your shell, so their
bridge uses the `xcode-select` choice unless their own environment sets
`DEVELOPER_DIR`. Confirm which Xcode answered with the bridge checks.

### Tool approvals

Tool settings are part of the server's entry, at two levels.
`default_tools_approval_mode`, and the `enabled_tools` and `disabled_tools`
filters, sit directly in `[mcp_servers.xcode]`. `approval_mode` for one tool
sits in that tool's `[mcp_servers.xcode.tools.<tool>]` table. Both approval
keys take `auto`, `prompt`, `writes`, or `approve`. Keep each key at its level:
Codex silently ignores `default_tools_approval_mode` inside a tool's table.

```toml
[mcp_servers.xcode]
command = "xcrun"
args = ["mcpbridge"]
env_vars = ["DEVELOPER_DIR"]
default_tools_approval_mode = "prompt"      # server level

[mcp_servers.xcode.tools.XcodeListWorkspaces]
approval_mode = "approve"                   # one tool
```

The values above only show where the keys go; keep the ones you already use.
These settings take effect only with that entry, so move the ones you want into
the project file before you remove the global entry, or approve again later.
When the server is defined in a project file, Codex writes a later "always
allow" choice into that project file as `approval_mode = "approve"`, not into
`~/.codex/config.toml`. Review those changes before you commit them, because a
committed approval applies to everyone who trusts the project.

## Rules for both clients

- Commit only the portable entry: `xcrun mcpbridge`, with no Xcode path, user
  path, wrapper script, or process ID. Keep personal choices in Claude Code's
  local scope or in the environment that Codex starts in.
- Keep one server name, `xcode`, in every scope and client, and remove the
  global entry instead of keeping it beside the project one.
- The committed file travels with every checkout. Claude Code's local entry and
  Codex's trust decision are recorded per path, so a separate clone needs them
  again.
- Select the Xcode with the
  [selection rule](../../xcode-project-workflow/references/xcode-selection.md):
  the newest installed Xcode, unless the user or the project pins another one.
  Bind the bridge to it with `DEVELOPER_DIR`, then confirm which Xcode answered
  with the
  [bridge checks](xcode-mcp-provider-preflight.md#bind-the-bridge-to-the-selected-xcode).
- Do not set `MCP_XCODE_PID`, not even for one diagnostic session. On
  2026-09-27, with Xcode 27.2 beta (27B5019j), setting it to the running Xcode's
  process ID left `tools/list` unanswered, with no tools after 45 seconds.
  `DEVELOPER_DIR` alone returned the tools in about 5 seconds, and
  `XcodeListWorkspaces` listed the open project. If you cannot bind the bridge
  with `DEVELOPER_DIR`, report it as unbound and use the host CLI tools with the
  selected `DEVELOPER_DIR` instead.
- Never probe with `xcrun mcpbridge run-agent`. It launches Xcode and prints MCP
  credentials.

## Sources

- [Apple: Giving external agents access to Xcode](https://developer.apple.com/documentation/xcode/giving-external-agents-access-to-xcode)
- [Claude Code docs: MCP](https://code.claude.com/docs/en/mcp) (scopes,
  `.mcp.json`, environment variable expansion, project approvals, and list
  health checks) and `claude mcp add --help`, `claude mcp remove --help`
- [Claude Code docs: Configure permissions](https://code.claude.com/docs/en/permissions)
  (MCP tool rules)
- OpenAI Docs: [Model Context Protocol](https://developers.openai.com/codex/mcp/),
  [Config basics](https://developers.openai.com/codex/config-basic),
  [Advanced configuration](https://developers.openai.com/codex/config-advanced),
  and [Configuration reference](https://developers.openai.com/codex/config-reference)
- openai/codex `rust-v0.144.1`:
  [stdio server environment](https://github.com/openai/codex/blob/rust-v0.144.1/codex-rs/rmcp-client/src/utils.rs),
  [`codex mcp` commands](https://github.com/openai/codex/blob/rust-v0.144.1/codex-rs/cli/src/mcp_cmd.rs),
  and [MCP tool approval persistence](https://github.com/openai/codex/blob/rust-v0.144.1/codex-rs/core/src/mcp_tool_call.rs)
