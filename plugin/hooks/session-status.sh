#!/bin/sh
# Claude Code SessionStart, UserPromptSubmit, PreToolUse and Stop hook: runs
# session_status.swift, compiled once per script revision into the plugin's data
# folder. A failure prints nothing and never blocks the prompt or the turn.

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
here=$(dirname "$0")
# Lets a reason name the deadline wrapper next to this script by its path.
APE_PLUGIN_HOOKS=$here
export APE_PLUGIN_HOOKS
# At session start, compile the deadline wrapper in the background, so its first use in a
# background command never waits on a compile.
case "$input" in
  *'"SessionStart"'*) /bin/sh "$here/deadline.sh" 1s -- true >/dev/null 2>&1 & ;;
esac
source="$here/session_status.swift"
cache="${CLAUDE_PLUGIN_DATA:-$HOME/Library/Caches/apple-platform-engineer}"
if revision=$(/sbin/md5 -q "$source" 2>/dev/null); then
  binary="$cache/session-status-$revision"
  if [ ! -x "$binary" ]; then
    mkdir -p "$cache" 2>/dev/null
    xcrun swiftc -swift-version 5 -O -o "$binary.$$" "$source" 2>/dev/null && mv -f "$binary.$$" "$binary"
  fi
  if [ -x "$binary" ]; then
    printf '%s' "$input" | "$binary" 2>/dev/null
  fi
fi
exit 0
