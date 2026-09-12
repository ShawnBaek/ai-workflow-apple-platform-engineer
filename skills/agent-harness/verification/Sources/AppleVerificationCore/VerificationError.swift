public enum VerificationError: Error, CustomStringConvertible {
  case invalid(String)
  public var description: String {
    switch self {
    case .invalid(let message): return message
    }
  }
}
