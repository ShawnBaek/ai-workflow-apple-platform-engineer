import Darwin
import Foundation

// Runs a command with a deadline: `deadline.sh <duration> [--] <command> [arguments...]`, the
// duration as `90s`, `30m` or `2h`, at most 24 hours. The command runs in its own process group
// with this process's standard streams. When it outlives the deadline, the whole group gets
// SIGTERM, then SIGKILL ten seconds later, and this process exits 124 after saying so on
// standard error. SIGTERM, SIGINT or SIGHUP to this process stops the group the same way and
// exits 128 plus the signal. Otherwise the command's own exit status is returned.
//
// Limits: SIGKILL to this process alone cannot be passed on, so stop this process with SIGTERM,
// or kill its whole process tree. Processes that launchd starts for the
// command, such as a Simulator's services, are outside the group: a `simctl boot` stopped at the
// deadline can leave its device booting.

/// The signal that asked this process to stop, 0 until one arrives.
var stopSignal: Int32 = 0

func say(_ text: String) {
  FileHandle.standardError.write(Data("deadline: \(text)\n".utf8))
}

/// Seconds in a duration such as `90s`, `30m` or `2h`; nil when it is not one.
func seconds(_ text: String) -> Double? {
  guard let unit = text.last, let value = Double(text.dropLast()), value.isFinite, value > 0
  else { return nil }
  let factor: Double
  switch unit {
  case "s": factor = 1
  case "m": factor = 60
  case "h": factor = 3600
  default: return nil
  }
  return value * factor <= 24 * 3600 ? value * factor : nil
}

var arguments = Array(CommandLine.arguments.dropFirst())
guard let duration = arguments.first.flatMap(seconds) else {
  say("usage: deadline.sh <duration: 90s, 30m or 2h, at most 24h> [--] <command> [arguments...]")
  exit(125)
}
let durationText = arguments.removeFirst()
if arguments.first == "--" { arguments.removeFirst() }
guard !arguments.isEmpty else {
  say("no command to run")
  exit(125)
}

// Installed before the command starts, so no signal can leave it running unseen.
for signal in [SIGTERM, SIGINT, SIGHUP] {
  Darwin.signal(signal) { received in stopSignal = received }
}

var attributes: posix_spawnattr_t?
posix_spawnattr_init(&attributes)
posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
posix_spawnattr_setpgroup(&attributes, 0)
var child: pid_t = 0
let argv = arguments.map { strdup($0) } + [nil]
let spawned = posix_spawnp(&child, arguments[0], nil, &attributes, argv, environ)
posix_spawnattr_destroy(&attributes)
guard spawned == 0 else {
  say("cannot start \(arguments[0]): \(String(cString: strerror(spawned)))")
  exit(127)
}

/// The command's exit code once it ended, or nil while it runs.
func finished() -> Int32? {
  var status: Int32 = 0
  guard waitpid(child, &status, WNOHANG) == child else { return nil }
  let signal = status & 0x7f
  return signal == 0 ? (status >> 8) & 0xff : 128 + signal
}

/// Stops the command's whole group: SIGTERM, then SIGKILL after ten seconds.
func stopGroup() {
  killpg(child, SIGTERM)
  killpg(child, SIGCONT)
  let grace = Date().addingTimeInterval(10)
  while Date() < grace {
    if finished() != nil { break }
    usleep(200_000)
  }
  killpg(child, SIGKILL)
  _ = finished()
}

let end = Date().addingTimeInterval(duration)
while Date() < end && stopSignal == 0 {
  if let code = finished() { exit(code) }
  usleep(200_000)
}
if stopSignal != 0 {
  let received = stopSignal
  stopGroup()
  exit(128 + received)
}
say("\(arguments[0]) outlived its \(durationText) deadline and was stopped")
stopGroup()
exit(124)
