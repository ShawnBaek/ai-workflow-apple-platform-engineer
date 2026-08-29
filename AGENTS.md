# iOS-experts maintainer harness

This repository publishes agent-neutral skills for Apple-platform development.
Before changing it, read `skills/agent-harness/SKILL.md` and the reference it
routes to for the task.

## Boundaries

- Current user and system instructions, account guards, the authoritative
  checkout, and approved repository policy outrank this repository's defaults.
- Keep personal Apple/GitHub account IDs, team IDs, and private guards in a
  project overlay. Canonical coordinates for this public upstream repository
  may appear in installation commands and source references.
- Preserve existing skill IDs. Add a new skill only when it has a distinct
  trigger and owner; otherwise update or route through the existing skill.
- Prefer current Apple-authored Xcode skills, Documentation Search, and Xcode
  tools. Do not copy Apple skill bodies into this repository.
- Work in the authoritative checkout. A Git worktree is explicit opt-in only.
- Do not regenerate an open XcodeGen project without explicit approval.
- Do not run Xcode or Simulator commands in a sandboxed process.
- Never delete broad Xcode, Simulator, package, archive, or runner directories.

## Change contract

1. Confirm the remote default branch and start an approved feature branch.
2. Use the smallest affected skill and the harness's risk-derived checks.
3. Keep graph, capability, schema, README inventory, and version data aligned.
4. Run `python3 scripts/validate_repository.py` before proposing a commit.
5. Before the first commit or push, honor the active project's repository
   confirmation policy. Never infer approval from the task itself.
6. A pull request is ready only when its required evidence is present and all
   omitted checks and their remaining risk are stated. Do not auto-merge.

## Collaboration

Codex-only, Claude-only, and Codex-plus-Claude are supported. At most one agent
may hold a repository-writer lease. Reviewers receive an immutable diff bundle;
local LLMs may retrieve, rerank, or cluster logs but may not write or approve.
