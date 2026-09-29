# Session flow summary

`apple-verify flow` records a redacted outline of a Claude Code or Codex session
from the client's hooks and draws it as a Mermaid flowchart or a text tree: which
agent ran which tools, which subagents it spawned, and where steps failed or
never finished. Version 0 records hooks only. It does not import Claude Code
transcripts or Codex rollouts, and it needs no harness, run authorization or
installed contracts.

Set `APE` to the built Swift verifier; see
[Build and locate the verifier](swift-verification.md#build-and-locate-the-verifier).

## What is recorded and what is dropped

`flow record` reads one hook JSON object from stdin and appends at most one line
to `<store>/<session-hash>.jsonl`. Redaction is an allowlist: a field is stored
only in one of these forms.

| Stored | Form |
|---|---|
| Session, agent, turn (`turn_id`, or Claude Code's `prompt_id`) and `tool_use_id` | 16-hex salted HMAC-SHA256 |
| Event, step kind and status, session `source`/`reason`, compaction `trigger` | Documented enum values; anything else becomes `unknown` |
| Tool name | A built-in name of that client; an MCP tool as `mcp:<server-hash>/<tool>`; any other tool as `tool:<hash>` |
| Agent type | A built-in type (`general-purpose`, `Explore`, `Plan`, `claude`, `statusline-setup`, `claude-code-guide`; Codex `default`, `explorer`, `worker`) or `custom:<hash>` |
| Failure | `error_class`: `exit_code`, `timeout`, `denied`, `interrupt` or `error` |
| Time | The recorder's timestamp and the client-reported `duration_ms` |

Never stored: prompts, assistant messages, `tool_input`, `tool_response`,
commands, file paths, `cwd`, transcript paths, error text, compaction summaries,
descriptions and nicknames. The recorder reads error text only to classify it,
and a spawn tool's result only to hash the spawned agent's id.

`flow record --include-labels` also stores the raw MCP server name, unknown tool
name and custom agent type, capped at 64 characters. Render shows them only with
its own `--include-labels`; without the recorder opt-in there is nothing to show. Labels
drop control, format (including bidirectional overrides) and line separator
characters.

The store holds a `salt` file, created once per store with an exclusive link and
never rewritten, and one JSONL file per session. A missing store is created with
mode 0700 inside an existing parent, and its files with 0600; the recorder does
not create parent directories. It records nothing when the store, the salt or a
session file is a symlink, or when the store path has a `.` or `..` component.
Keep it outside every repository: anyone holding the salt can confirm a guessed
id. Delete a session file to forget it;
v0 does not rotate or expire files.

## Hook configuration

Installing these hooks changes the client's configuration. Do it only after the
person approves the exact file, scope and entries, as
[apple-platform-setup](../../apple-platform-setup/SKILL.md) requires; never add
them automatically. Both commands need absolute paths: `<APE>` is the absolute
path of the built `apple-verify`, and `<STORE>` an absolute private directory.
A relative `--store` records nothing. Those paths are personal, so put the hooks
in a file that is not committed: Claude Code's user settings or a project's
`.claude/settings.local.json` (confirm it is ignored by Git), and the user's
Codex home rather than a project's `.codex/`. The recorder always exits 0 with no
stdout, so it never changes a decision; a missing executable makes the hook
itself fail, so rebuild in place rather than moving the binary.

<table>
<tr><th>Claude Code</th><th>Codex</th></tr>
<tr><td>

`.claude/settings.local.json` or the user
settings file, under `hooks`. Command hooks accept
`"async": true`, which runs the recorder in the
background. Repeat the entry for `SessionStart`,
`SessionEnd`, `PreToolUse`, `PostToolUse`,
`PostToolUseFailure`, `SubagentStart`,
`SubagentStop`, `PreCompact`, `PostCompact` and
`Stop`. An omitted `matcher` matches every tool.

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "'<APE>' flow record --client claude --store '<STORE>'",
            "async": true
          }
        ]
      }
    ]
  }
}
```

</td><td>

`hooks.json` in the user's Codex home, or
`[hooks]` in its `config.toml`; use one form per
layer. A trusted project's `.codex/` also loads
hooks, but it is usually committed. Command hooks accept `async`;
Codex runs an async `SessionEnd` synchronously.
Repeat for `SessionStart`, `SessionEnd`,
`PreToolUse`, `PostToolUse`, `SubagentStart`,
`SubagentStop`, `PreCompact`, `PostCompact`,
`Stop` and `Interrupt`.

```toml
[[hooks.PostToolUse]]

[[hooks.PostToolUse.hooks]]
type = "command"
command = "'<APE>' flow record --client codex --store '<STORE>'"
async = true
```

The `hooks.json` form matches the Claude Code
JSON with `--client codex`. Codex runs a
non-managed hook only once the person trusts it
in Codex, which records a trusted hash in its
hook state; do not write that state by hand.

</td></tr>
</table>

Sources: Claude Code [hooks reference](https://code.claude.com/docs/en/hooks)
and [tools reference](https://code.claude.com/docs/en/tools-reference); Codex
`rust-v0.159.0`
[hook inputs](https://github.com/openai/codex/blob/rust-v0.159.0/codex-rs/hooks/src/schema.rs),
[hook dispatch](https://github.com/openai/codex/blob/rust-v0.159.0/codex-rs/core/src/hook_runtime.rs),
[hook configuration](https://github.com/openai/codex/blob/rust-v0.159.0/codex-rs/config/src/hook_config.rs)
and [discovery](https://github.com/openai/codex/blob/rust-v0.159.0/codex-rs/hooks/src/engine/discovery.rs).

## Render

```sh
"$APE" flow render --store '<STORE>' --session <session-id-or-hash> --format tree
"$APE" flow render --store '<STORE>' --session <session-id-or-hash> --format mermaid \
  --ledger <private-run>/ledger.jsonl --max-steps 200
```

`--session` takes the client's session id or the stored hash (the file name).
Render only reads. Each agent is a lane: the root is the session, and a
subagent sits under the step that spawned it; a dashed edge in Mermaid. Runs of
the same tool collapse (`Bash ×12 (2 failed)`), statuses read `failed`,
`interrupted` or `incomplete`. `--max-steps` (default 500) counts drawn step
nodes, where a collapsed run is one node, and replaces the rest with a note
naming both the nodes and the steps they held. `--ledger` adds a read-only
`harness` lane from an agent-harness run ledger in time order, showing each
record's type and allowlisted enum fields only; it has its own `--max-steps`
budget and note, so ledger records never displace session steps.

A step pairs its Pre and Post events by `tool_use_id` and keeps the most severe
status, so a repeated or reordered tool or subagent hook gives the same drawing.
Any other event is dropped as a duplicate only when its stored line repeats
exactly, timestamp included, so two compactions or two Stops in one turn both
appear. Steps are ordered by recorder time.

## Linking subagents

- **Claude Code:** the Agent tool's `PostToolUse` `tool_response.agentId` names
  the subagent whose hooks carry it as `agent_id`; the caller's own `agent_id`,
  absent for the main thread, places the spawn step. A background subagent
  links too, because its `PostToolUse` fires at launch with `agentId`. The docs
  do not state that `agentId` equals `agent_id`; their transcript naming
  (`subagents/agent-<id>.jsonl`) implies it, and the recorder drops a leading
  `agent-` from both before hashing.
- **Codex:** `SubagentStart` fires in the child with `agent_id` set to the
  child's thread id, and the child's hooks share the root `session_id`. A v1
  `spawn_agent` result is JSON text whose `agent_id` is that thread id, which
  links the child to the calling step.
- **Cannot link:** a Codex MultiAgentV2 spawn, whose result carries a task name
  rather than a thread id; a subagent started before the hooks were installed;
  and Claude Code's internal agents, which fire `SubagentStop`. These appear
  under `unlinked`. A spawn result naming an agent with no recorded events
  shows an empty lane.

## Limits

- The outline covers only events delivered while the hooks were installed. An
  async Claude Code hook still running when `claude -p` exits is cancelled, so
  the last events of a headless run can be missing.
- Codex has no `PostToolUseFailure` and runs `PostToolUse` only after success:
  a failed Codex tool call shows as `incomplete`, or `interrupted` when its
  turn's `Interrupt` hook fired. Claude Code fires no failure event for a
  permission denial, so that step also shows `incomplete`; a call rejected by
  input validation fires no `PreToolUse` either, so it does not appear.
- Codex reports every `SessionEnd` reason as `other`. Neither client passes its
  version to hooks, so none is recorded.
- Input over 64 MiB is drained and dropped. Hashes are 64-bit and scoped to one
  store; the same session recorded into two stores does not match.
- The harness lane is a separate timeline beside the session; v0 does not align
  the two clocks.
