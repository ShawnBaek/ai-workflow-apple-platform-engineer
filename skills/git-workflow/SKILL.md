---
name: git-workflow
description: Safely prepare Apple-project branches, worktrees, Git metadata recovery, and pull-request delivery without losing index or repository state.
---

# Git Workflow

Use this skill for repository setup, branch work, linked worktrees, Git-index recovery, or a pull request. Project policy and user authorization take precedence.

## Start from the authoritative checkout

- Use the exact repository and Xcode project directory the user identified. Inspect its top level, redacted remote, current branch, working state, and remote default branch before implementation.
- A normal feature starts in that same checkout. Propose a concise branch name and obtain approval before creating or switching branches. `codex/<type>/<slug>` is a useful example, not a replacement for a repository's own naming policy.
- Apply the detailed [branch policy](references/branch-policy.md) before creating or switching a branch.
- Update safely from the remote default branch only when the checkout is clean and the repository policy permits it. Do not use `--force`, reset, automatic pruning, or a replacement clone to work around a problem.
- Before the first commit or push, show the repository name, absolute path, branch, and a credential-redacted remote, then obtain the repository-confirmation gate required by project policy.

## Worktrees and Git metadata

Create a linked worktree only on explicit per-task request. For an Xcode task, require a new Xcode session and re-confirm its authoritative project root. Put it at sibling path `../worktree/<sanitized-branch>`; never place it inside the main checkout or project directory.

Before any operation that writes Git metadata in a linked worktree, run the read-only preflight in [linked-worktree and index recovery](references/linked-worktree-index-recovery.md). It identifies the actual git directory, common directory, index, and lock path rather than assuming `.git` is a directory.

When local state and remote tracking disagree after an otherwise confirmed push, verify the remote branch or pull request first. Then refresh from the normal host terminal with `git fetch origin`, inspect `git status -sb`, and inspect `git branch -vv` before changing tracking configuration.

## Plan phase-sized pull requests

Before implementation, derive an ordered phase map from the dependency graph.
Each PR should answer one reviewer question, carry its own minimum-sufficient
verification, and leave a coherent intermediate state. Split independent
features, infrastructure, migrations, generated changes, and UI evidence work
when they can be reviewed or reverted separately.

Use the repository's size policy when it has one. Otherwise, 400 non-generated
changed lines or 12 changed files is a review checkpoint, not a target: split at
a real phase boundary or record why splitting would create an invalid
intermediate. Never pad a stack with tiny mechanical PRs just to stay under a
number.

When phases depend on each other, use stacked PRs. Obtain approval for every
branch name, base each branch and PR on its approved predecessor, and put the
ordered stack map in every PR body. Each phase gets its own diff, checks,
evidence, and review status. A stacked PR does not grant merge, force-push, or
branch-retarget authority.

## Deliver a reviewable pull request

Keep the PR sequence explicit: inspect scope and status, implement, select minimum-sufficient verification, review the staged diff, commit only after the gate, push only after the gate, open the PR, then verify remote SHA, CI/check status, and PR body/evidence links. Attach requested screenshots or video through a supported, verified evidence path; do not claim an attachment exists until its PR-visible location is checked.

Use exact repository-relative paths after `--` for file-specific operations. Record what was verified, what was intentionally not run, and any remaining risk. Read [PR delivery](references/pr-delivery.md) when opening or updating a PR.

## Sources

- [Git worktree documentation](https://git-scm.com/docs/git-worktree.html)
- [Git restore documentation](https://git-scm.com/docs/git-restore.html)
- [GitHub: creating a pull request](https://docs.github.com/en/pull-requests/collaborating-with-pull-requests/proposing-changes-to-your-work-with-pull-requests/creating-a-pull-request)
