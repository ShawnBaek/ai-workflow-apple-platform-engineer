# Branch policy

Repository policy and an explicit user instruction take precedence over this
default. Before editing, verify the exact repository path, credential-redacted
remote, and current branch. Identify the remote default branch when the
requested branch workflow depends on it. Derive and create a branch from the
assigned task without a separate branch-name approval. Honor an explicit user
branch name and base. When the user explicitly continues an existing PR, retain
that PR's branch and base unless the user directs otherwise.

For a fresh task without an explicit base or planned stack dependency, refresh
the [intended base](#default-branch-model) safely and create the branch from
that revision in the same checkout. Do not branch from an unrelated current HEAD merely
because it is checked out. Resolve existing changes as described below before
updating or switching; verify the repository path, branch and base afterward.
A local-only [small change](../../agent-harness/references/small-change-path.md)
is edited in place on the current branch instead; it takes a branch this way
only when it will be committed or delivered as a PR, and is never committed to
the default or integration branch directly.

Branch-name selection is routine. It differs from a meaningful uncertainty
about the base branch, an overlap with existing work, or whether the task is a
continuation of a PR. Resolve that uncertainty before creating or switching a
branch; do not disguise it as a name-approval request.

If staged, unstaged, or untracked changes already exist, inspect them read-only
before checkout mutation. An in-place small change lists those that do not
touch its file and continues; the rest of this paragraph applies to those that
do. Report the assigned outcome and intended edit scope,
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

## Default branch model

Read the branch rule from the repository's instructions or the recorded
project policy. When neither defines one, ask the user once which rule the
repository follows, offering this default, and record the answer in the
project overlay. Do not ask again for each task or branch name.

| Branch | Role |
|---|---|
| `main` | Stable branch; always releasable. Never commit to it directly. |
| `feature/<slug>` | One task or one stacked phase. |
| `release/<version>` | Release candidate for a marketing version, such as `release/1.4.0`. |

The default flow is `feature/<slug>` → PR into `release/<version>` → verify
the release candidate → PR from `release/<version>` into `main`. The
**intended base** of a new branch or PR is the remote default branch unless
the recorded rule names an integration branch; under this model it is the
current `release/<version>` for the target version. When none exists, ask which
version the work targets. Creating or pushing a `release/<version>` branch and
every merge remain human gates.

GitHub closing keywords act only on a merge into the default branch, so a PR
into `release/<version>` uses `Refs #<issue>`; the issue closes when the
release reaches `main`.

Convert slashes, spaces, and other path-unsafe characters in the requested
name to hyphens; keep the slug concise and descriptive, for example
`feature/123-simulator-timeout`. A recorded repository rule, such as
`codex/<type>/<slug>` or a `develop` branch, replaces this default entirely.
