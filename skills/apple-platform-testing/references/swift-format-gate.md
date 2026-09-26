# Swift format gate commands

Commands for [Swift format and compile acceptance](../SKILL.md#swift-format-and-compile-acceptance).
They were verified with swift-format 604.0.0 and the `xcrun swift-format` in
Xcode 27.1, which produce identical output, in bash and zsh on macOS. Run them
from the repository root. `BASE` is the task's base commit, `F` is a
repository-relative Swift file the task changed, and `SCRATCH` is a directory
outside the repository.

## Resolve the configuration

swift-format walks from each file up to `/` and silently uses the first
`.swift-format` it finds, including one in `$HOME` or a parent monorepo
directory. Only a file inside the repository is the project's configuration:

```sh
root="$(git rev-parse --show-toplevel)"; dir="$(dirname "$F")"; CONF=""
while :; do
  if [ -f "$root/$dir/.swift-format" ]; then CONF="$root/$dir/.swift-format"; break; fi
  [ "$dir" = . ] && break; dir="$(dirname "$dir")"
done
echo "${CONF:-no project configuration}"
```

Without one, set `CONF` to inline JSON that matches the file: the indentation
unit it already uses (Xcode's default is 4 spaces; use `{"tabs":1}` and
`"tabWidth"` for tabs), and the project's documented line limit or, if none, at
least the file's longest line (`awk '{ if (length > m) m = length } END { print m }' "$F"`).
Unset keys take swift-format's defaults.

```sh
CONF='{"version":1,"indentation":{"spaces":4},"lineLength":120}'
```

Pass `--configuration "$CONF"` to every format and lint command so a stray
configuration cannot apply.

## Choose the mode

Whole-file mode needs a project configuration file and a base version that is
already conformant under it:

```sh
git show "$BASE:$F" | xcrun swift-format format --configuration "$CONF" --assume-filename "$F" - \
  | cmp -s - <(git show "$BASE:$F") && echo whole-file || echo changed-ranges
```

An inline configuration always means changed-ranges mode. A file absent from
`BASE` (`git cat-file -e "$BASE:$F"` fails) is entirely the task's: format it
whole with `CONF`. A renamed file is not new: set `OLD` to its path at `BASE`,
read the base as `"$BASE:$OLD"` in these commands, and after `git mv` give the
range diff both paths with rename detection:
`git diff --no-ext-diff -M -U0 --no-color "$BASE" -- "$OLD" "$F"`. A diff limited
to the new path shows every line as added, which would format the whole file.

## Format

Whole file:

```sh
xcrun swift-format format --in-place --configuration "$CONF" "$F"
```

Changed ranges: one `--lines start:end` per added or modified hunk. Recompute
the ranges on every rerun; a pure deletion has none and skips the formatter.

```sh
git diff --no-ext-diff -U0 --no-color "$BASE" -- "$F" \
  | awk '/^@@/ { split($3, a, ","); s = substr(a[1], 2); n = (a[2] == "" ? 1 : a[2]);
                 if (n > 0) printf "--lines=%d:%d\n", s, s + n - 1 }' \
  | xargs -r xcrun swift-format format --in-place --configuration "$CONF" "$F"
```

In a scratch repository, a 4-space file without a `.swift-format` received a
one-line edit and one added function. Plain `format --in-place` reindented every
indented line to 2 spaces and reordered the imports. The changed-ranges command above
reformatted only the added function and left every other line, including the
unsorted imports and a `case let` pattern, byte-identical. Formatting only
`--lines` with swift-format's defaults still put the edited lines at 2 spaces
inside the 4-space file, which is why the inline configuration is required.

## Lint against the base

`--lines` does not narrow `lint` output, so compare the whole file with its base
revision by rule and message:

```sh
norm() { sed -E 's/^.*:[0-9]+:[0-9]+: (warning|error)/\1/' | sort; }
git show "$BASE:$F" | xcrun swift-format lint --configuration "$CONF" --assume-filename "$F" - 2>&1 \
  | norm > "$SCRATCH/base.lint"
xcrun swift-format lint --configuration "$CONF" "$F" 2>&1 | norm > "$SCRATCH/final.lint"
comm -13 "$SCRATCH/base.lint" "$SCRATCH/final.lint"   # new findings
```

Use an empty `base.lint` for an added file. Every new finding blocks completion
like a task-introduced warning; fix it and rerun the whole gate. That includes a
finding reported outside the task's lines: the comparison ignores location, and
with the same tool and configuration only the task's change can add one.
Baseline findings are disclosed, not fixed, because fixing them is unrelated
churn.

## Snippets and Xcode editor tools

A documentation snippet the task adds or changes follows the same mode rule as a
file. Resolve `CONF` with the document's path as `F`, and always pass it
explicitly, because a scratch path finds no project configuration. Save the
snippet's text at `BASE` (empty for a new snippet) and the task's edited text,
without the fences or any indentation the Markdown adds, to
`$SCRATCH/base.swift` and `$SCRATCH/edited.swift`. With a project configuration
file, choose the mode; an inline `CONF` always means changed ranges:

```sh
xcrun swift-format format --configuration "$CONF" "$SCRATCH/base.swift" \
  | cmp -s - "$SCRATCH/base.swift" && echo whole-snippet || echo changed-ranges
```

A new snippet's empty base is conformant, so it is formatted whole:

```sh
xcrun swift-format format --in-place --configuration "$CONF" "$SCRATCH/edited.swift"
```

Otherwise format only the changed lines, with a `CONF` that matches the
snippet's indentation and longest line (inline JSON when the project
configuration does not):

```sh
git diff --no-index --no-ext-diff -U0 --no-color "$SCRATCH/base.swift" "$SCRATCH/edited.swift" \
  | awk '/^@@/ { split($3, a, ","); s = substr(a[1], 2); n = (a[2] == "" ? 1 : a[2]);
                 if (n > 0) printf "--lines=%d:%d\n", s, s + n - 1 }' \
  | xargs -r xcrun swift-format format --in-place --configuration "$CONF" "$SCRATCH/edited.swift"
```

Copy `edited.swift` back into the fence, restoring the Markdown's indentation,
then type-check a scratch copy with the minimum scaffolding it needs. In this
repository, formatting an existing 4-space snippet whole with the 2-space root
configuration rewrote 8 of its 11 lines; with
`{"version":1,"indentation":{"spaces":4},"lineLength":91}` the command above
formatted two added lines and left every other line byte-identical.

When edits go through Xcode's editor (`XcodeWrite`, `XcodeUpdate`), format only
after those edits are saved to disk, and confirm with `XcodeRead` that the open
document shows the formatted file. Xcode saves open documents when it builds, so
record `shasum -a 256 "$F"` after formatting and again after the build. A
mismatch means a stale editor buffer was built; rerun the gate.

## Report

Record:

- the toolchain: `xcodebuild -version` and `xcrun swift-format --version`.
  Xcode's bundled swift-format prints `main`, so the Xcode version and build
  identify it; a standalone binary prints its release, so record its path too;
- for each file, the resolved configuration path (or "no project configuration"
  with the inline JSON), the mode with its line ranges, and whether formatting
  changed it;
- new lint findings with rule, message and location, and the number of baseline
  findings left as they were;
- each compile command or official tool call, with scheme, configuration and
  destination where they apply, and its result and log or result-bundle path.
  `swift build` and an app scheme's build leave test targets out, so changed
  test sources get their own entry: `swift build --build-tests` or `swift test`
  for a package, and for an Xcode test target `xcodebuild build-for-testing`
  with a scheme whose Test action contains it, or an official Xcode test run
  that includes it. In a scratch package, `swift build` exited 0 over a test
  file that did not compile; `swift build --build-tests` reported the error.

A structured completion report has `name`, `result` and `summary` in each
`checks` entry:

- `swift-format`: `passed` when every file was formatted and no new lint
  findings remain, with the toolchain, per-file configuration and mode, and lint
  counts in the summary; `failed` while new findings remain; `not_run` with
  summary `Format Unverified: <reason>` when swift-format could not run.
- `compile`: `passed` when every changed target compiled, test targets
  included, with each exact command or tool call and its result;
  `failed` with summary `Build Failed: <first error>`; `not_run` with
  `Build Unverified: <reason>` when the build was not allowed or blocked.
