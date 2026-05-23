# commit-message

Writes good git commit messages for indie Swift / Apple-platform projects. Reads the staged diff and produces a properly-formatted, useful message instead of "wip" or "updated files".

Supports three styles:
1. **Conventional Commits** (default for new repos) — `feat(editor): ...`
2. **Swift-style `[area]` prefix** — `[Editor] Fix crash when ...`
3. **Plain imperative** (classic Pro Git) — `Add per-note color tags`

The agent detects which style the repo already uses from `git log --oneline -20` and matches it.

## What it does

- Reads `git diff --staged` before writing anything.
- Classifies the change: `feat` / `fix` / `perf` / `refactor` / `style` / `docs` / `test` / `build` / `ci` / `chore`.
- Picks the scope from the file paths touched.
- Writes a subject ≤ 72 chars, imperative, no trailing period.
- Adds a body **only if there's a *why* worth recording** — trivial changes get no body.
- Adds a footer like `Closes #42` / `Fixes #87` when a tracker reference is obvious.
- Outputs a ready-to-paste `git commit -m` (with HEREDOC for multi-line bodies).

## What it deliberately doesn't do

- Write a message without reading the staged diff first.
- Lie about scope (won't call a behavior change a "refactor").
- Pad the body for a trivial change — a 40-line body for a typo fix is noise.
- Mix styles in one message.
- Auto-commit. You run `git commit`.
- Add `Co-Authored-By` lines unless you explicitly ask.

## The 7 rules every style enforces

1. Imperative, present tense — "Add login screen", not "Added".
2. Subject ≤ 72 chars (ideally ≤ 50).
3. Subject capitalized.
4. No trailing period on the subject.
5. Blank line between subject and body.
6. Body wraps at 72.
7. Body explains *why*, not *what* (the diff shows what).

## Hard "stop and ask" cases

The agent refuses to write a message when:

- The diff touches 3+ unrelated areas → suggests how to split.
- The diff contains what looks like a secret → flags the line.
- The diff is huge and you haven't said what changed → asks for one sentence.
- Nothing is staged → asks to stage or to look at unstaged.

## When to use

- "Write me a commit message for this."
- "What should this commit say?"
- Right before running `git commit` on a non-trivial change.
- When you've been writing "wip" all week and want to amend a real message in.

## Install

```bash
npx claude-plugins install @shawnbaek/agent-design/commit-message
```

Requires Claude Code v2.0.12+. Or interactively inside Claude Code:

```text
/plugin marketplace add shawnbaek/agent-design
/plugin install commit-message@indie-native-app
```

## Companion agents in this marketplace

- [`apple-platform-ui`](../apple-platform-ui/README.md) — produces the SwiftUI code you're about to commit.
- [`xcodebuild`](../xcodebuild/README.md) — runs the tests that should pass before you commit.
- [`apple-platform-performance`](../apple-platform-performance/README.md) — catches the perf regressions you'd otherwise notice in review.
