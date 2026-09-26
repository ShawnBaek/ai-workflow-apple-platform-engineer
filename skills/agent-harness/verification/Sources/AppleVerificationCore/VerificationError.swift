public enum VerificationError: Error, CustomStringConvertible {
  case invalid(String)
  /// Another holder kept an advisory lock for the whole bounded wait: retryable contention,
  /// not a malformed request.
  case lockTimedOut
  public var description: String {
    switch self {
    case .invalid(let message): return message
    case .lockTimedOut: return "Lock acquisition timed out"
    }
  }
}
