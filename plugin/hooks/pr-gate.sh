#!/bin/sh
# Claude Code PreToolUse hook: a Bash command that publishes a pull request
# (gh pr create, gh pr edit, gh pr ready, or a branch git push) runs only when it
# names the head code-review approved, APE_REVIEWED_HEAD=<sha> equal to that
# repository's HEAD, or carries the user's explicit APE_REVIEW_OVERRIDE.
# Everything else passes untouched.

input=$(cat)
case "$input" in
  *"gh"*"pr"* | *"git"*"push"*) ;;
  *) exit 0 ;;
esac

field() {
  printf '%s' "$input" | /usr/bin/plutil -extract "$1" raw -o - - 2>/dev/null
}
command=$(field tool_input.command) || command=$input
cwd=$(field cwd) || cwd=$PWD

# Only a command in command position counts: at the start of a line or after
# && ; | or (, optionally behind VAR=value assignments. Text that merely
# mentions one (echo, grep) passes.
prefix="(^|[;&|(])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=('[^']*'|\"[^\"]*\"|[^[:space:]]*)[[:space:]]+)*"
if printf '%s\n' "$command" | grep -Eq "${prefix}gh[[:space:]]+pr[[:space:]]+(create|edit|ready)"; then
  :
elif printf '%s\n' "$command" | grep -Eq "${prefix}git([[:space:]]+-C[[:space:]]+[^[:space:]]+)?[[:space:]]+push"; then
  case "$command" in
    *"--tags"* | *"refs/tags/"*) exit 0 ;;
  esac
else
  exit 0
fi

case "$command" in
  *"APE_REVIEW_OVERRIDE="[!\ \'\"]* | *"APE_REVIEW_OVERRIDE='"[!\']* | *"APE_REVIEW_OVERRIDE=\""[!\"]*) exit 0 ;;
esac

deny() {
  reason="apple-platform-engineer PR gate: $1 Publishing needs an independent code-review approve for the exact head. Load apple-platform-engineer:git-workflow (references/pr-delivery.md) and run apple-platform-engineer:code-review on that head until it returns approve, then rerun this command prefixed with APE_REVIEWED_HEAD=<approved sha>. Only if the user explicitly decides to publish without approve, prefix APE_REVIEW_OVERRIDE='<the user decision>' and disclose it in the PR."
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"%s"}}\n' "$reason"
  exit 0
}

reviewed=$(printf '%s' "$command" | sed -n 's/.*APE_REVIEWED_HEAD=\([0-9a-fA-F]\{7,40\}\).*/\1/p')
[ -n "$reviewed" ] || deny "no reviewed head was named."

dir=$cwd
target=$(printf '%s' "$command" | sed -n "s/^[[:space:]]*cd[[:space:]][[:space:]]*['\"]\{0,1\}\([^'\"&;]*\)['\"]\{0,1\}[[:space:]]*&&.*/\1/p")
[ -n "$target" ] || target=$(printf '%s' "$command" | sed -n "s/.*git[[:space:]][[:space:]]*-C[[:space:]][[:space:]]*['\"]\{0,1\}\([^'\" ]*\)['\"]\{0,1\}.*/\1/p")
target=$(printf '%s' "$target" | sed 's/[[:space:]]*$//')
if [ -n "$target" ]; then
  case "$target" in
    "~"*) target="$HOME${target#\~}" ;;
  esac
  case "$target" in
    /*) dir=$target ;;
    *) dir="$cwd/$target" ;;
  esac
fi

head=$(git -C "$dir" rev-parse HEAD 2>/dev/null) || deny "the repository HEAD could not be read."
case "$head" in
  "$reviewed"*) exit 0 ;;
esac
deny "APE_REVIEWED_HEAD $reviewed is not the current HEAD $head; any later commit, amend, rebase or retarget needs re-review."
