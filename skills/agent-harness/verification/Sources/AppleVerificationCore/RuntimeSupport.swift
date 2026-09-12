import CoreFoundation
import CryptoKit
import Darwin
import Foundation

public struct RuntimeContext {
  public let repositoryRoot: URL
  public let harnessRoot: URL
  public init(repositoryRoot: URL, harnessRoot: URL) {
    self.repositoryRoot = repositoryRoot
    self.harnessRoot = harnessRoot
  }
}

public struct ProcessResult: Sendable {
  public let stdout: String
  public let stderr: String
  public let exitCode: Int32
  public let timedOut: Bool
  public let truncated: Bool
}

/// Small synchronous primitives shared by the command modules. No shell, daemon,
/// global working-directory changes, package dependencies, or unbounded output.
public enum HarnessRuntime {
  public static func loadJSON(_ url: URL) throws -> Any {
    let data = try readRegularFile(url, maximumBytes: 32 * 1_024 * 1_024)
    return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
  }

  /// Read a bounded snapshot without following a replaced final symlink or
  /// allocating from an unchecked file size. Callers parse these same bytes.
  public static func readRegularFile(_ url: URL, maximumBytes: Int) throws -> Data {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw systemError("open input") }
    defer { close(fd) }
    var before = stat()
    guard maximumBytes >= 0, fstat(fd, &before) == 0,
      before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0,
      before.st_size <= maximumBytes
    else { throw VerificationError.invalid("Input must be a bounded regular non-symlink file") }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = read(fd, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw systemError("read input")
      }
      guard count <= maximumBytes - data.count else {
        throw VerificationError.invalid("Input grew beyond its bound")
      }
      data.append(contentsOf: buffer.prefix(count))
    }
    var after = stat()
    var path = stat()
    guard fstat(fd, &after) == 0, lstat(url.path, &path) == 0,
      path.st_dev == before.st_dev, path.st_ino == before.st_ino,
      after.st_size == before.st_size, data.count == before.st_size,
      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
      after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
    else { throw VerificationError.invalid("Input changed while reading") }
    return data
  }

  public static func object(_ url: URL) throws -> [String: Any] {
    guard let value = try loadJSON(url) as? [String: Any] else {
      throw VerificationError.invalid("Expected a JSON object: \(url.lastPathComponent)")
    }
    return value
  }

  public static func isBoolean(_ value: Any) -> Bool {
    guard let number = value as? NSNumber else { return false }
    return CFGetTypeID(number) == CFBooleanGetTypeID()
  }

  /// Preserve the compact sorted JSON contract, including ASCII escaping and
  /// surrogate pairs. Patch identities explicitly opt into UTF-8 strings.
  public static func canonicalJSON(_ value: Any, ensureASCII: Bool = true) throws -> Data {
    func quoted(_ value: String) -> String {
      var output = "\""
      for scalar in value.unicodeScalars {
        switch scalar.value {
        case 0x22: output += "\\\""
        case 0x5c: output += "\\\\"
        case 8: output += "\\b"
        case 9: output += "\\t"
        case 10: output += "\\n"
        case 12: output += "\\f"
        case 13: output += "\\r"
        case 0..<32: output += String(format: "\\u%04x", scalar.value)
        case 128... where ensureASCII:
          if scalar.value <= 0xffff {
            output += String(format: "\\u%04x", scalar.value)
          } else {
            let offset = scalar.value - 0x10000
            output += String(
              format: "\\u%04x\\u%04x", 0xd800 + (offset >> 10), 0xdc00 + (offset & 0x3ff))
          }
        default: output.unicodeScalars.append(scalar)
        }
      }
      return output + "\""
    }
    func encode(_ value: Any, depth: Int) throws -> String {
      guard depth <= 128 else { throw VerificationError.invalid("JSON nesting exceeds 128") }
      if value is NSNull { return "null" }
      if let text = value as? String { return quoted(text) }
      if let number = value as? NSNumber {
        if isBoolean(number) { return number.boolValue ? "true" : "false" }
        let kind = String(cString: number.objCType)
        if kind == "d" || kind == "f" {
          let double = number.doubleValue
          guard double.isFinite else { throw VerificationError.invalid("Non-finite JSON number") }
          return String(double)
        }
        return number.stringValue
      }
      if let list = value as? [Any] {
        return "[" + (try list.map { try encode($0, depth: depth + 1) }).joined(separator: ",")
          + "]"
      }
      if let object = value as? [String: Any] {
        // Unicode scalar ordering matches Python, including non-BMP keys.
        let keys = object.keys.sorted {
          $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars)
        }
        return "{"
          + (try keys.map { quoted($0) + ":" + (try encode(object[$0]!, depth: depth + 1)) })
          .joined(separator: ",") + "}"
      }
      throw VerificationError.invalid("Value is not JSON serializable")
    }
    return Data(try encode(value, depth: 0).utf8)
  }

  public static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }

  public static func sha256File(_ url: URL) throws -> String {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw systemError("open hash input") }
    defer { close(fd) }
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw VerificationError.invalid("Hash input must be a regular file")
    }
    var digest = SHA256()
    var bytes = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      let count = read(fd, &bytes, bytes.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw systemError("read hash input")
      }
      digest.update(data: Data(bytes.prefix(count)))
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
  }

  public static func atomicWriteJSON(_ value: Any, to url: URL) throws {
    var data = try canonicalJSON(value)
    data.append(10)
    try atomicWrite(data, to: url)
  }

  public static func atomicWrite(_ data: Data, to url: URL) throws {
    let parent = url.deletingLastPathComponent()
    var info = stat()
    guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
      throw VerificationError.invalid("Output parent must be an existing non-symlink directory")
    }
    if lstat(url.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG {
      throw VerificationError.invalid("Output must be a regular non-symlink file")
    }
    let temporary = parent.appendingPathComponent(".apple-verify-\(UUID().uuidString)")
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw systemError("create atomic output") }
    defer {
      close(fd)
      unlink(temporary.path)
    }
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count < 0 {
          if errno == EINTR { continue }
          throw systemError("write atomic output")
        }
        guard count > 0 else { throw VerificationError.invalid("Atomic write made no progress") }
        offset += count
      }
    }
    guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
      throw systemError("publish atomic output")
    }
    let directoryFD = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    if directoryFD >= 0 {
      defer { close(directoryFD) }
      guard fsync(directoryFD) == 0 else { throw systemError("sync output directory") }
    }
  }

  public static func timestamp(_ date: Date = Date()) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
  }

  public static func parseTimestamp(_ string: String) throws -> Date {
    guard
      string.range(of: #"^\d{4}-\d{2}-\d{2}T.+(?:Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression)
        != nil
    else {
      throw VerificationError.invalid("Timestamp requires an explicit timezone")
    }
    let formatter = ISO8601DateFormatter()
    for options: ISO8601DateFormatter.Options in [
      [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
    ] {
      formatter.formatOptions = options
      if let date = formatter.date(from: string) { return date }
    }
    throw VerificationError.invalid("Invalid timestamp")
  }

  /// OS advisory locking; callers must hold this across read/check/write.
  public static func withFileLock<T>(at url: URL, timeout: TimeInterval = 5, _ body: () throws -> T)
    throws -> T
  {
    guard timeout.isFinite, timeout >= 0, timeout <= 300 else {
      throw VerificationError.invalid("Invalid lock timeout")
    }
    let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw systemError("open lock") }
    defer { close(fd) }
    var info = stat()
    var namedInfo = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
      throw VerificationError.invalid("Lock must be a regular file")
    }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
      guard errno == EWOULDBLOCK || errno == EINTR else { throw systemError("acquire lock") }
      guard ProcessInfo.processInfo.systemUptime < deadline else {
        throw VerificationError.invalid("Lock acquisition timed out")
      }
      usleep(10_000)
    }
    defer { flock(fd, LOCK_UN) }
    guard lstat(url.path, &namedInfo) == 0, namedInfo.st_dev == info.st_dev,
      namedInfo.st_ino == info.st_ino
    else {
      throw VerificationError.invalid("Lock pathname was replaced")
    }
    return try body()
  }

  /// Spawn an owned process group, drain both pipes, and bound output and time.
  /// Timeout signals only this group, never a name-based host-wide process set.
  public static func run(
    executable: String, arguments: [String], directory: URL? = nil,
    environment: [String: String]? = nil, timeout: TimeInterval = 15,
    maxOutputBytes: Int = 1_048_576
  ) throws -> ProcessResult {
    guard timeout.isFinite, timeout > 0, timeout <= 3_600, maxOutputBytes > 0,
      maxOutputBytes <= 64 * 1_024 * 1_024,
      !executable.isEmpty, !([executable] + arguments).contains(where: { $0.utf8.contains(0) })
    else {
      throw VerificationError.invalid("Invalid process bounds or arguments")
    }
    var outputPipe: [Int32] = [-1, -1]
    var errorPipe: [Int32] = [-1, -1]
    guard pipe(&outputPipe) == 0 else { throw systemError("create stdout pipe") }
    defer { for fd in outputPipe where fd >= 0 { close(fd) } }
    guard pipe(&errorPipe) == 0 else { throw systemError("create stderr pipe") }
    defer { for fd in errorPipe where fd >= 0 { close(fd) } }
    for fd in outputPipe + errorPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    guard posix_spawn_file_actions_init(&actions) == 0, posix_spawnattr_init(&attributes) == 0
    else { throw VerificationError.invalid("Cannot initialize process attributes") }
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    func checked(_ result: Int32) throws {
      if result != 0 { throw VerificationError.invalid("Process setup failed: \(result)") }
    }
    try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
    try checked(posix_spawn_file_actions_adddup2(&actions, outputPipe[1], STDOUT_FILENO))
    try checked(posix_spawn_file_actions_adddup2(&actions, errorPipe[1], STDERR_FILENO))
    for fd in outputPipe + errorPipe {
      try checked(posix_spawn_file_actions_addclose(&actions, fd))
    }
    if let directory { try checked(posix_spawn_file_actions_addchdir_np(&actions, directory.path)) }
    try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP)))
    try checked(posix_spawnattr_setpgroup(&attributes, 0))
    let variables = environment ?? ProcessInfo.processInfo.environment
    guard
      variables.allSatisfy({
        !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0)
      })
    else { throw VerificationError.invalid("Invalid process environment") }
    var argv = ([executable] + arguments).map { strdup($0) } + [nil]
    var envp = variables.keys.sorted().map { strdup("\($0)=\(variables[$0]!)") } + [nil]
    defer { for pointer in argv + envp { free(pointer) } }
    var pid: pid_t = 0
    try checked(posix_spawnp(&pid, executable, &actions, &attributes, &argv, &envp))
    close(outputPipe[1])
    outputPipe[1] = -1
    close(errorPipe[1])
    errorPipe[1] = -1
    for fd in [outputPipe[0], errorPipe[0]] { _ = fcntl(fd, F_SETFL, O_NONBLOCK) }
    var out = Data()
    var err = Data()
    var status: Int32 = 0
    var timedOut = false
    var truncated = false
    var reaped = false
    var terminatedAt: TimeInterval?
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
    func drain(_ fd: Int32, to data: inout Data) {
      while true {
        let count = read(fd, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        if count <= 0 { break }
        let available = max(0, maxOutputBytes - data.count)
        data.append(contentsOf: buffer.prefix(min(count, available)))
        if count > available { truncated = true }
        // Yield to deadline handling even if a child continuously writes.
        if count == buffer.count { break }
      }
    }
    while !reaped {
      drain(outputPipe[0], to: &out)
      drain(errorPipe[0], to: &err)
      let waited = waitpid(pid, &status, WNOHANG)
      if waited == pid {
        reaped = true
        break
      }
      if waited < 0, errno != EINTR { throw systemError("wait for owned child") }
      let now = ProcessInfo.processInfo.systemUptime
      if now >= deadline, terminatedAt == nil {
        timedOut = true
        terminatedAt = now
        kill(-pid, SIGTERM)
      }
      if let terminatedAt, now - terminatedAt >= 0.25 { kill(-pid, SIGKILL) }
      usleep(5_000)
    }
    // A child can exit while a descendant still owns a pipe. Do not hang
    // awaiting EOF. On timeout terminate remaining owned group members.
    if timedOut { kill(-pid, SIGKILL) }
    for _ in 0..<((maxOutputBytes / buffer.count) + 2) {
      drain(outputPipe[0], to: &out)
      drain(errorPipe[0], to: &err)
    }
    let signal = status & 0x7f
    let exitCode = signal == 0 ? (status >> 8) & 0xff : 128 + signal
    return ProcessResult(
      stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self),
      exitCode: exitCode, timedOut: timedOut, truncated: truncated)
  }

  private static func systemError(_ operation: String) -> VerificationError {
    .invalid("\(operation): \(String(cString: strerror(errno)))")
  }
}
