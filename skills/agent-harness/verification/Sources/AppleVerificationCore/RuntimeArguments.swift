import Foundation

/// Strict argument values. No shell expansion, implicit booleans, or duplicate options.
public struct RuntimeArguments {
  private var options: [String: [String]] = [:]
  public init(_ arguments: [String], flags: Set<String> = [], repeated: Set<String> = []) throws {
    var i = 0
    while i < arguments.count {
      let key = arguments[i]
      guard key.hasPrefix("--"), repeated.contains(key) || options[key] == nil else {
        throw VerificationError.invalid("Invalid or duplicate option: \(key)")
      }
      if flags.contains(key) {
        options[key] = ["true"]
        i += 1
      } else {
        guard i + 1 < arguments.count, !arguments[i + 1].isEmpty else {
          throw VerificationError.invalid("Missing option value: \(key)")
        }
        options[key, default: []].append(arguments[i + 1])
        i += 2
      }
    }
  }
  public func allow(_ keys: Set<String>) throws {
    guard Set(options.keys).isSubset(of: keys) else {
      throw VerificationError.invalid(
        "Unknown options: \(Set(options.keys).subtracting(keys).sorted())")
    }
  }
  public func required(_ key: String) throws -> String {
    guard let value = options[key]?.first else { throw VerificationError.invalid("Missing \(key)") }
    return value
  }
  public func value(_ key: String) -> String? { options[key]?.first }
  public func values(_ key: String) -> [String] { options[key] ?? [] }
  public func flag(_ key: String) -> Bool { options[key] == ["true"] }
}
