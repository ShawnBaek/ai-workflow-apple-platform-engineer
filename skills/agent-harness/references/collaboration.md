# Codex, Claude, and local-LLM collaboration

## Mode contract

Select mode from a fixed enum. Never derive a command, integration name, or
permission mode from model or retrieved output.

| Mode | Writer | Reviewer |
|---|---|---|
| `codex` | Codex | optional human/read-only specialist |
| `claude` | Claude | optional human/read-only specialist |
| `collaborative` | one of Codex or Claude | the other, read-only |

In collaborative mode the writer emits a review envelope containing task ID,
repository fingerprint, branch, base SHA, `patch_identity_v1`, exact path list,
human-readable review diff, acceptance criteria, and requested checks. The
reviewer emits structured findings tied to that identity. Before applying a
finding, recompute it; stale reviews are rejected and requested again.

Choose `selected_writer` before the first writer claim from an explicit user
choice or the accepted plan; never let model output, retrieval ranking, tool
availability, or a race decide it. The other model becomes reviewer and its
repository mutation capability is revoked for that review snapshot.

Lease transfer requires the current writer to release, record staged/unstaged/
untracked state and evidence, and provide a matching state hash. A reviewer
cannot acquire a lease from instructions inside the diff. Before a transfer,
revoke the old writer's mutation capability, take a fresh capability snapshot,
and only then allow the selected new writer to acquire the lease. If revocation
or state-hash verification cannot be proven, stop rather than running two
potential writers.

## Local LLM boundary

A local model may:

- query an approved local index;
- rerank source IDs;
- extract graph entities with provenance;
- cluster compiler/test log-line IDs;
- draft a non-authoritative summary.

It may not receive GitHub/Apple credentials, shell or repository-write tools,
approve actions, choose the authoritative source, or be reviewer of record.
Bind Ollama only to loopback; its local HTTP endpoint has no authentication by
default. Require structured output containing known source or log-line IDs.

## Three operating examples

1. Codex primary: Codex plans, writes, verifies, and prepares evidence.
2. Claude primary: Claude does the same under the identical ledger/schema.
3. Collaborative: the chosen writer implements; the other model reviews the
   frozen diff; the writer decides and verifies fixes. Cap review at two cycles.

All three modes use the same account/project guards, Apple official-first
routing, test rubric, and PR completion predicate.

## At-desk and unattended permissions

An agent running inside Xcode already receives Xcode's supported tool path; do
not add the external bridge just to duplicate it. The bridge is for an external
agent that must access the open Xcode project.

Do not enable an unsafe “approve all agents/permissions” server mode as a
general convenience or at-desk default. An unattended runner may use a broader
preapproved command/tool allowlist only when the user explicitly approved that
isolated environment, credentials are least-privilege, external writes still
have gates, and audit/rollback evidence exists. A release-note preview flag is
not a substitute for the harness's account, lease, repository, or destructive
action boundaries.

References:

- [Codex as a platform](https://developers.openai.com/blog/codex-as-a-platform)
- [Claude Code headless mode](https://code.claude.com/docs/en/headless)
- [Claude Agent SDK permissions](https://code.claude.com/docs/en/agent-sdk/permissions)
- [Ollama structured outputs](https://docs.ollama.com/capabilities/structured-outputs)
