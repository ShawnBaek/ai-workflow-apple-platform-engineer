# Branch hygiene

A task that ends leaves no branch, worktree or clone behind that only it used.
Apply this after a pull request merges, before starting new work on a branch,
and when the session status reports branches or worktrees from merged PRs.

## After a pull request merges

1. Confirm the merge: `gh pr view '<PR>' --json state,headRefName,headRefOid`
   shows `MERGED`.
2. Stop using that branch. Follow-up work, even on the same feature, starts a
   new branch from the refreshed [intended base](branch-policy.md#default-branch-model).
   Do not merge or rebase the base into the merged branch to keep working on
   it, and do not push more commits to it.
3. Remove what this task created, each step only when its check passes:
   - **Worktree:** `git worktree remove '<path>'` when
     `git -C '<path>' status --porcelain` is empty, its HEAD equals the PR's
     `headRefOid` or `git -C '<path>' log HEAD --not --remotes` is empty, and
     no other session works there. Never `--force`.
   - **Local branch:** from a checkout that is not on it, `git branch -d
     '<branch>'`. After a squash or rebase merge, where `-d` refuses, use
     `git branch -D '<branch>'` only when the local tip equals the PR's
     `headRefOid`.
   - **Remote branch:** when `gh repo view --json deleteBranchOnMerge` is
     `false`, `git push origin --delete '<branch>'` only under recorded
     project policy or the user's approval. Offer once to turn the repository
     setting on with `gh repo edit --delete-branch-on-merge`; it is a
     repository setting, so ask first.
   - **Simulators:** the task's own devices, as [xcodebuild](../../xcodebuild/SKILL.md)
     steps 3 and 8 describe.
4. Report what was removed, and what was kept and why.

Never switch, clean or delete a checkout, worktree or branch that another
session or the user is working in; report it instead. Never create a second
full clone as a working copy: use a linked worktree, so `git worktree list`
shows every copy. Do not prune automatically or delete a branch that has
commits no merged PR or remote contains.

## Sweep report

When the user asks to tidy up, or the status reports merged branches, prepare
a read-only report and delete nothing until the user approves the exact list:

- each linked worktree from `git worktree list --porcelain`, with its branch,
  changed-file count and any session working there;
- each local branch whose latest PR merged
  (`gh pr list --state all --limit 300 --json number,headRefName,state`) or
  whose upstream is gone (`git branch -vv` shows `[gone]`), flagging commits
  missing from the remote;
- other clones of the same remote in the user's project folders
  (`git -C '<folder>' remote get-url origin`).

Group the entries into safe to remove (merged, clean, unused), needs a
decision, and keep. On approval, remove only the approved entries with the
commands above.

In Claude Code, the plugin's session status warns when the session's branch
belongs to a merged PR and counts the local branches and linked worktrees
whose latest PR merged; a branch checked out in a linked worktree counts in
both. It skips pull requests from forks, the remote's default branch, and a
branch an open pull request still targets.
