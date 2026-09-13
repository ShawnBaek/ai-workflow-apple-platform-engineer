# Branch policy

Repository policy and an explicit user instruction take precedence over this
default. Before editing, verify the exact repository path, credential-redacted
remote, and current branch. Identify the remote default branch when the
requested branch workflow depends on it. Derive and create a branch from the
assigned task without a separate branch-name approval. Honor an explicit user
branch name and base. When the user explicitly continues an existing PR, retain
that PR's branch and base unless the user directs otherwise.

For a fresh task without an explicit base or planned stack dependency, refresh
the verified remote default safely and create the branch from that revision
in the same checkout. Do not branch from an unrelated current HEAD merely
because it is checked out. Resolve existing changes as described below before
updating or switching; verify the repository path, branch and base afterward.

Branch-name selection is routine. It differs from a meaningful uncertainty
about the base branch, an overlap with existing work, or whether the task is a
continuation of a PR. Resolve that uncertainty before creating or switching a
branch; do not disguise it as a name-approval request.

If staged, unstaged, or untracked changes already exist, inspect them read-only
before checkout mutation. Report the assigned outcome and intended edit scope,
then list the changed paths, staged/unstaged/untracked state and actual content
changes. Distinguish behavior/configuration changes from formatting or ordering
only when the diff or a semantic comparison supports that conclusion. Explain
their likely relationship to the task (or state that the relationship is
unknown), and the exact proposed preservation/exclusion handling. Do not infer
authorship from a filename. Wait for an
explicit user approval or rejection before switching branches, updating,
stashing, discarding, or editing over those changes. Silence is not approval;
read-only analysis may continue. Once the user approves that exact handling,
carry it forward for the task and do not re-ask before the agent's own edits.
If handling is rejected, preserve the files and wait for a different agreed
approach. Approval for one file or operation is not approval to stash, discard
or include other changes. Reinspect before acting; new external changes or a
different handling proposal need a new summary and decision.

When the repository has no naming rule, use:

```
codex/<type>/<slug>
```

Allowed default types are `feat`, `fix`, `chore`, `docs`, and `release`. An
optional issue reference may appear in the slug, for example
`codex/fix/123-simulator-timeout`. Convert slashes, spaces, and other
path-unsafe characters in the requested name to hyphens; keep the resulting
slug concise and descriptive.

Release branches follow the repository's release policy when one exists. Do
not invent a release branch convention or replace a repository-defined naming
scheme with this default.
