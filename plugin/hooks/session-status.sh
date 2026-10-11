#!/bin/sh
# Claude Code SessionStart and UserPromptSubmit hook: runs session_status.swift,
# compiled once per script revision into the plugin's data folder. The status
# is informational, so a failure prints nothing and never blocks the prompt.

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
