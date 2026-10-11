#!/bin/sh
# Runs a command with a deadline: deadline.sh <duration> [--] <command> [arguments...].
# deadline.swift, compiled once per script revision into a fixed cache folder, stops
# the command's whole process group when it outlives the deadline and exits 124.

here=$(dirname "$0")
source="$here/deadline.swift"
# One fixed cache, not CLAUDE_PLUGIN_DATA: an agent's Bash commands do not get that variable, so
# the binary compiled at session start must be the one the agent's call finds.
cache="${APE_DEADLINE_CACHE:-$HOME/Library/Caches/apple-platform-engineer}"
if revision=$(/sbin/md5 -q "$source" 2>/dev/null); then
  binary="$cache/deadline-$revision"
  if [ ! -x "$binary" ]; then
    mkdir -p "$cache" 2>/dev/null
    xcrun swiftc -swift-version 5 -O -o "$binary.$$" "$source" 2>/dev/null && mv -f "$binary.$$" "$binary"
  fi
  if [ -x "$binary" ]; then
    exec "$binary" "$@"
  fi
fi
echo "deadline: cannot compile $source; select a full Xcode for xcrun swiftc" >&2
exit 125
