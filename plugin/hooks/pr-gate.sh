#!/bin/sh
# Claude Code PreToolUse hook for Bash. A command that cannot publish a pull
# request passes at once; any other is judged by pr_gate.swift, compiled once per
# script revision into the plugin's data folder.

input=$(cat)
case "$input" in
  *gh*pr* | *git*push*) ;;
  *) exit 0 ;;
esac

here=$(dirname "$0")
source="$here/pr_gate.swift"
cache="${CLAUDE_PLUGIN_DATA:-$HOME/Library/Caches/apple-platform-engineer}"
revision=$(/sbin/md5 -q "$source" 2>/dev/null) || revision=unknown
binary="$cache/pr-gate-$revision"

if [ ! -x "$binary" ]; then
  mkdir -p "$cache" 2>/dev/null
  xcrun swiftc -O -o "$binary.$$" "$source" 2>/dev/null && mv -f "$binary.$$" "$binary"
fi
if [ -x "$binary" ]; then
  printf '%s' "$input" | "$binary"
else
  printf '%s' "$input" | xcrun swift "$source" 2>/dev/null ||
    printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"apple-platform-engineer PR gate: the gate could not run (xcrun swift unavailable), so publication cannot be checked. Install or select Xcode, or have the user decide."}}'
fi
exit 0
