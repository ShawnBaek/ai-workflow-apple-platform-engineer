# Change transfer commands

`<agent>` is the agent workspace root, `<target>` the open checkout's root,
`<out>` a persistent task-output directory outside both checkouts, and `<base>`
the task's base commit. Use absolute paths. `<out>/handoff.patch` is the only
input to the undo: do not put `<out>` in scratch or a sandbox directory that
ends with the session, keep it until the user undoes or adopts the change, and
report its path.

## Check which Xcode the bridge reaches

These are read-only:

```sh
xcode-select -p
ps -axo pid=,comm= | grep '/Contents/MacOS/Xcode$'
xcrun mcp-server status
```

The first shows the Xcode that `xcrun` tools and the bridge use by default. The
second lists running GUI Xcode apps. The third reports whether Xcode's headless
MCP service is running and which workspaces it has open. When the user's GUI
Xcode is a different app, or the headless service answers without the user's
project, the bridge is not bound to the user's window: ask for the container
path instead. Pinning the bridge to that Xcode with `MCP_XCODE_PID=<pid>`
changes the bridge configuration, so it needs approval.

## Classify the workspaces

```sh
git -C <agent>  rev-parse --show-toplevel --git-common-dir HEAD
git -C <target> rev-parse --show-toplevel --git-common-dir HEAD
git -C <agent>  remote get-url origin
git -C <target> remote get-url origin
```

Resolve relative `--git-common-dir` output against each root and compare real
paths. Redact credentials before showing a remote. A clone made from the open
checkout has that checkout's path as its `origin`; that counts as a match.

| Agent workspace | Evidence | Objects for `<base>` and `--3way` |
|---|---|---|
| same checkout | same top level | nothing to transfer |
| linked worktree | same common directory | already shared |
| separate local clone or sandbox copy | different common directory, shared history | `git -C <target> fetch <agent> <agent-branch>` |
| remote or cloud session | pushed branch, PR or patch file | `git -C <target> fetch origin <branch>` |

A fetch that names only a source ref writes objects and `FETCH_HEAD` (and may
update that remote's tracking ref); it never moves local branches or files. Do
not run client pull-back commands that check out a branch or require a clean
tree in the user's checkout without approval. Confirm shared history with
`git -C <target> merge-base <base> HEAD`, after a fetch when needed.

## Freeze the change set

Build the patch with the plumbing commands `diff-index` and `diff-tree`.
Porcelain `git diff` applies the user's `diff.external`, textconv drivers,
color and `diff.noprefix`, which can make the patch fail or land on wrong paths.

### Local source: linked worktree, clone or sandbox copy

List each state separately, in `<agent>`:

```sh
git log --oneline <base>..HEAD
git diff --cached --name-status --no-renames
git diff --name-status --no-renames
git ls-files --others --exclude-standard
```

Then freeze commits, staged, unstaged and untracked changes into one patch
through a temporary index; the agent's real index is not modified:

```sh
GIT_INDEX_FILE=<out>/handoff.index git -C <agent> read-tree HEAD
GIT_INDEX_FILE=<out>/handoff.index git -C <agent> add -A
GIT_INDEX_FILE=<out>/handoff.index git -C <agent> diff-index --cached -p --binary --full-index --no-renames <base> > <out>/handoff.patch
GIT_INDEX_FILE=<out>/handoff.index git -C <agent> diff-index --cached --name-status --no-renames <base> > <out>/handoff.paths
shasum -a 256 <out>/handoff.patch
```

The freeze records the files on disk, including edits made after staging.
`add -A` writes objects into the agent repository's object store, which for a
linked worktree is the shared common directory. Run the git-workflow
[linked-worktree preflight](../../git-workflow/references/linked-worktree-index-recovery.md)
first; if the sandbox cannot write there, the lead or the user runs the freeze.

### Remote or cloud source

Only pushed commits travel: the session must commit and push everything the
user should see. After the fetch in the table above, record the fetched commit
and freeze from it in `<target>`; these commands only read objects:

```sh
git -C <target> rev-parse FETCH_HEAD
git -C <target> log --oneline <base>..<fetched>
git -C <target> diff-tree -r -p --binary --full-index --no-renames <base> <fetched> > <out>/handoff.patch
git -C <target> diff-tree -r --name-status --no-renames <base> <fetched> > <out>/handoff.paths
shasum -a 256 <out>/handoff.patch
```

Use the recorded SHA as `<fetched>`; a later fetch replaces `FETCH_HEAD`.
Without `-r`, `--name-status` lists only top-level entries.

A patch file supplied by the session instead must have been made in the session
with the same plumbing command,
`git diff-tree -r -p --binary --full-index --no-renames <base> <head>`.
Porcelain `git diff` can run a textconv driver on an added file and still
produce a patch that looks valid and passes `apply --check`, yet creates
different bytes. Also check the patch: every header reads
`diff --git a/<path> b/<path>`, `index` lines carry full object names, and there
are no `Binary files ... differ`, `rename from` or `copy from` lines. It must
pass `git -C <target> apply --check --whitespace=nowarn` before the inspection
below. List its paths with
`git -C <target> apply --numstat --summary --whitespace=nowarn`; without
`--whitespace=nowarn`, `apply.whitespace=error` makes the listing fail.

Review `handoff.paths` before transfer: secrets, `xcuserdata`, build products
or files outside the task mean the freeze is wrong.

### Leave a path out

Leaving a path out means a new freeze without it, never
`git apply --exclude` or `--include`: the reported undo reverses
`handoff.patch`, so it must be exactly the applied change. Add a literal
exclude pathspec for each left-out path, or directory, to both freeze commands
of the source, then record the new SHA-256:

```sh
GIT_INDEX_FILE=<out>/handoff.index git -C <agent> diff-index --cached -p --binary --full-index --no-renames <base> -- . ':(exclude,literal)<path>' > <out>/handoff.patch
GIT_INDEX_FILE=<out>/handoff.index git -C <agent> diff-index --cached --name-status --no-renames <base> -- . ':(exclude,literal)<path>' > <out>/handoff.paths
git -C <target> diff-tree -r -p --binary --full-index --no-renames <base> <fetched> -- . ':(exclude,literal)<path>' > <out>/handoff.patch
git -C <target> diff-tree -r --name-status --no-renames <base> <fetched> -- . ':(exclude,literal)<path>' > <out>/handoff.paths
shasum -a 256 <out>/handoff.patch
```

The first two commands refreeze a local source, the next two a remote one.
`literal` keeps `*`, `?` and `[` in a path from matching other paths. A rename
travels as two paths; leave out both or neither. For a supplied patch, the
session reruns its command with the same pathspec.

## Inspect the open checkout

```sh
git -C <target> --no-optional-locks rev-parse --path-format=absolute --git-path MERGE_HEAD --git-path CHERRY_PICK_HEAD --git-path REVERT_HEAD --git-path sequencer --git-path rebase-merge --git-path rebase-apply --git-path BISECT_LOG
git -C <target> --no-optional-locks status --porcelain=v1 --untracked-files=all --no-renames
git -C <target> --no-optional-locks diff --name-status --no-renames <base> HEAD -- <touched paths>
git -C <target> merge-base --is-ancestor <base> HEAD
```

If any path the first command prints exists, a merge, cherry-pick, revert,
rebase, `git am` or bisect is in progress: stop. `sequencer` catches a
multi-commit cherry-pick or revert that stopped and whose resolution was
already committed, which leaves no `CHERRY_PICK_HEAD` or `REVERT_HEAD`. The second command gives the
user's staged, unstaged and untracked paths without refreshing their index. The
third shows drift on touched paths between the base and the user's HEAD.
Overlap is the intersection of `handoff.paths` with the user's changed paths,
plus added paths that already exist. If the last command exits 1, the user's
HEAD lacks commits the agent built on, so the result differs from what the
agent tested even without drift: report it and wait for approval.

Membership is decided per path; a project can mix synchronized folders
(`PBXFileSystemSynchronizedRootGroup` in `project.pbxproj`) and classic groups.
A file added or deleted under a synchronized folder needs no project-file change
unless the folder's exception set (`PBXFileSystemSynchronizedBuildFileExceptionSet`)
must list it. Every other added or deleted project file in `handoff.paths`
needs a matching hunk in the project-file diff.

## Apply, undo and repeat

```sh
git -C <target> apply --check --whitespace=nowarn <out>/handoff.patch
git -C <target> apply --whitespace=nowarn <out>/handoff.patch
```

`--whitespace=nowarn` keeps the bytes exact when the user's config sets
`apply.whitespace=fix`, which would otherwise strip trailing whitespace.

Undo, valid while the touched files are unchanged since the apply:

```sh
git -C <target> apply -R --check --whitespace=nowarn <out>/handoff.patch
git -C <target> apply -R --whitespace=nowarn <out>/handoff.patch
```

If the reverse check fails, someone edited a touched file after the apply.
Report it; do not force the undo with `restore` or `checkout`.

A patch that touches a submodule pointer does not move the submodule: plain
`git apply` ignores submodule commits. Report such a path as not carried over.

`git apply --3way` implies `--index`. It refuses every touched path whose
working-tree file does not match the index, including a file whose content
matches but whose stat data is stale, such as after an earlier apply and undo;
`--no-optional-locks` inspection never refreshes the index. It therefore needs
`git -C <target> update-index --refresh` first, which writes the index. It then
stages every patched path, mixing the agent's change into the user's index, and
can leave conflict markers. Use it only with approval that covers both index
writes, only when the user has no uncommitted changes on touched paths, and
report that its undo is not a plain reverse apply.

## Report template

```text
Source: <kind> <agent path>  base <sha>  head <sha>  commits <n>
Target: <container>  <workspaceIdentifier>  Xcode <version>  <branch|detached> <sha>
Patch: <out>/handoff.patch  sha256:<hash>  A <n> / M <n> / D <n>
Left out: <paths excluded from the freeze and reason, or none>
Your changes: <paths left untouched, or none>
Verification: scheme <name>, destination <title>; issues, build, previews, tests
Undo: git -C <target> apply -R --whitespace=nowarn <out>/handoff.patch
Adopt: commit it yourself, or ask for delivery through git-workflow
```
