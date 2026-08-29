# Linked Worktree and Index Recovery

Use this only when Git reports an index/lock write failure, a linked worktree behaves unexpectedly, or status shows a staged addition whose working-tree file is deleted.

## Read-only preflight

From the exact checkout, resolve paths rather than inferring them from `.git`:

```sh
git rev-parse --show-toplevel
git rev-parse --path-format=absolute --git-dir --git-common-dir
git rev-parse --path-format=absolute --git-path index
git rev-parse --path-format=absolute --git-path index.lock
git --no-optional-locks status --porcelain=v2 --branch
git diff --name-status
git diff --cached --name-status
git rev-parse HEAD
git symbolic-ref --quiet --short HEAD
git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}'
```

The last two commands may exit nonzero: record that as detached HEAD or no
configured upstream rather than treating it as an index failure. For automation,
parse `git --no-optional-locks status --porcelain=v2 -z --branch`; use the
human-readable form only for display.

Check whether the exact resolved lock path exists without modifying it:

```sh
git_index_lock_path="$(git rev-parse --path-format=absolute --git-path index.lock)"
if [ -e "$git_index_lock_path" ]; then
  printf 'present: %s\n' "$git_index_lock_path"
else
  printf 'absent: %s\n' "$git_index_lock_path"
fi
```

If a command is unavailable on the installed Git version, obtain its path with the equivalent `git rev-parse --git-dir`, `--git-common-dir`, and `--git-path` commands; do not guess from the worktree path.

Keep these states separate in the report:

- working tree (`git diff --name-status`),
- index (`git diff --cached --name-status`),
- local branch/upstream relationship, and
- remote branch SHA (`git ls-remote origin refs/heads/<exact-branch>` when authorized).

An `AD` entry means the index contains an added path while the working tree has deleted it. It is not a clean repository, even if the file no longer exists in the worktree.

## Decide what blocked the write

If `index.lock` is absent and a Git command fails with `Operation not permitted` or `Permission denied`, treat it as a sandbox or host-permission boundary—not lock contention. Do not retry from the sandbox, delete a lock, alter ownership or permissions, use an alternate index, create a clone, or move the checkout. Escalate to the normal logged-in host terminal for the same checkout.

If a lock exists, do not delete it automatically. First establish that no Git process owns it and that it is genuinely stale; obtain the approval required by the project policy before any destructive recovery.

## Host-terminal remedy for an unintended staged addition

After the preflight identifies the exact affected repository-relative path and confirms that preserving its deletion is intended, show `git --no-optional-locks status --short` to the user and run this in the normal host terminal from the same checkout:

```sh
git restore --staged -- '<exact-path-from-status>'
```

This changes only the index. It does not restore a deleted working-tree file. Re-run the four-state checks above and report the result; do not substitute a filename from an example or operate on a broad path.

`<exact-path-from-status>` is a schematic placeholder, not text to replace by
manual concatenation. An automation must pass the NUL-delimited path as one argv
element after `--`. A displayed host-shell command must use a trusted
shell-escaping routine so spaces, quotes, leading dashes, and unusual characters
cannot change the command.
