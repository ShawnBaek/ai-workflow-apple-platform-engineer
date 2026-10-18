#!/bin/sh
# Claude Code SessionStart, UserPromptSubmit, PreToolUse and Stop hook: runs
# session_status.swift, compiled once per script revision into the plugin's data
# folder. A failure prints nothing and never blocks the prompt or the turn.

here=$(dirname "$0")
source="$here/session_status.swift"
inventory="$here/../skills/agent-harness/verification/Sources/AppleVerificationCore/SessionInventory.swift"
# The hook and CLI compile this one reader, so metadata handling cannot drift between clients.
if [ "${1:-}" = "--typecheck" ]; then
  cat "$inventory" "$source" | xcrun swiftc -typecheck -
  exit $?
fi
input=$(cat)
# Before a tool call, only builds, tests and Simulator boots are checked.
case "$input" in
  *'"PreToolUse"'*)
    case "$input" in
      *xcodebuild* | *swift* | *simctl* | *gate.sh* | *'"mcp__'*) ;;
      *) exit 0 ;;
    esac
    ;;
esac
# Lets a reason name the deadline wrapper next to this script by its path.
APE_PLUGIN_HOOKS=$here
export APE_PLUGIN_HOOKS
# At session start, compile the deadline wrapper in the background, so its first use in a
# background command never waits on a compile.
case "$input" in
  *'"SessionStart"'*) /bin/sh "$here/deadline.sh" 1s -- true >/dev/null 2>&1 & ;;
esac
cache="${CLAUDE_PLUGIN_DATA:-$HOME/Library/Caches/apple-platform-engineer}"
if [ -r "$inventory" ] && revision=$(cat "$inventory" "$source" | /sbin/md5 -q 2>/dev/null); then
  binary="$cache/session-status-$revision"
  if [ ! -x "$binary" ]; then
    mkdir -p "$cache" 2>/dev/null
    cat "$inventory" "$source" | xcrun swiftc -swift-version 5 -O -o "$binary.$$" - 2>/dev/null && mv -f "$binary.$$" "$binary"
  fi
  if [ -x "$binary" ]; then
    printf '%s' "$input" | "$binary" 2>/dev/null
  fi
fi
exit 0
