# Apple Platform Engineer maintainer guidance

This repository publishes agent-neutral skills for Apple-platform development.
Before changing it, read `skills/agent-harness/SKILL.md` and the reference it
routes to for the task.

Read `CONTRIBUTING.md` when adding a skill or changing a workflow. Reported
collection problems follow `skills/skill-maintenance/SKILL.md` from reproduction
and issue triage through a verified, reviewable fix.

## Boundaries

- Current user and system instructions, account guards, the authoritative
  checkout, and approved repository policy outrank this repository's defaults.
- Keep personal Apple/GitHub account IDs, team IDs, and private guards in a
  project overlay. Canonical coordinates for this public upstream repository
  may appear in installation commands and source references.
- Preserve existing skill IDs and persisted schema/repository identities. Add a new skill only when it has a distinct
  trigger and owner; otherwise update or route through the existing skill.
- Prefer current Apple-authored Xcode skills, Documentation Search, and Xcode
  tools. Do not copy Apple skill bodies into this repository.
- Work in the authoritative checkout. A Git worktree is explicit opt-in only.
- Do not regenerate an open XcodeGen project without explicit approval.
- Do not run Xcode or Simulator commands in a sandboxed process.
- Never delete broad Xcode, Simulator, package, archive, or runner directories.

## Change contract

1. Confirm the remote default branch and start an approved feature branch.
2. Clarify the requested outcome and acceptance criteria before architecture
   or task breakdown. Reuse prior answers; resolve only material uncertainty.
   Read relevant ADRs, creating one only for a significant decision. Use a
   simple plan unless actual dependencies justify graph complexity.
3. Use the smallest affected skill and the harness's risk-derived checks.
4. Keep graph, capability, schema, skill catalog, and version data aligned.
5. Follow the current validation commands in `docs/verification.md` before
   proposing a commit. New custom verification code and tests use Swift;
   keep meaningful behavior and denial coverage when changing the runtime.
6. Before the first commit or push, honor the active project's repository
   confirmation policy. Never infer approval from the task itself.
7. A pull request is ready only when its required evidence is present and all
   omitted checks and their remaining risk are stated. Do not auto-merge.

## Collaboration

Codex-only, Claude-only, and Codex-plus-Claude are supported. At most one agent
may hold a repository-writer lease. Reviewers receive an immutable diff bundle;
local LLMs may retrieve, rerank, or cluster logs but may not write or approve.
Choose model capability from the assigned work, not the agent's title. A
reviewer can exercise a frozen build with separately scoped runtime ownership;
findings need code, reproduction, or applicable references, followed by author
assessment and verification. Follow `skills/code-review/SKILL.md`.
