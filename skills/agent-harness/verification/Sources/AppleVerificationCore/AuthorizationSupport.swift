import Darwin
import Foundation

/// JSON-value, path and digest checks shared by the authorization envelope, grant, ledger and
/// operation sources. Each replaces identical private copies those files kept before they were
/// split, so every caller applies one definition.
extension Authorization {
  static func objectShape(
    _ value: Any?, required: Set<String>, allowed: Set<String>, label: String
  ) -> [String] {
    guard let object = value as? [String: Any] else { return ["\(label) must be an object"] }
    var result: [String] = []
    let keys = Set(object.keys)
    let missing = required.subtracting(keys)
    let extra = keys.subtracting(allowed)
    if !missing.isEmpty {
      result.append("\(label) is missing fields: \(missing.sorted().joined(separator: ", "))")
    }
    if !extra.isEmpty {
      result.append("\(label) has unsupported fields: \(extra.sorted().joined(separator: ", "))")
    }
    return result
  }
  static func safeRelativePath(_ value: String) -> Bool {
    !value.isEmpty && !value.hasPrefix("/")
      && !value.split(separator: "/", omittingEmptySubsequences: false).contains("..")
  }
  static func pathAllowed(_ path: String, _ allowed: [String]) -> Bool {
    safeRelativePath(path)
      && allowed.contains {
        path == $0.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
          || path.hasPrefix($0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/")
      }
  }

  static func regex(_ value: Any?, _ pattern: String) -> Bool {
    guard let string = value as? String else { return false }
    return string.range(of: pattern, options: .regularExpression) != nil
  }

  static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    return JSONSchemaValidator.equal(lhs, rhs)
  }
  static func text(_ value: Any?) -> String {
    value is NSNull || value == nil ? "" : ((value as? String) ?? String(describing: value!))
  }
  static func jsonInt(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, !HarnessRuntime.isBoolean(number) else { return nil }
    let raw = number.stringValue
    guard let value = Int(raw), raw == String(value) || raw == "-0" else { return nil }
    return value
  }
  static func hash(_ value: Any?) -> Bool {
    (value as? String)?.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil
  }
  static func sha256(_ value: Any?) -> Bool {
    (value as? String)?.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
  }
  static func sha(_ value: Any?) -> Bool {
    (value as? String)?.range(of: #"^[0-9a-f]{40,64}$"#, options: .regularExpression) != nil
  }
  static func uniqueStrings(_ value: Any?) -> Bool {
    guard let values = value as? [String], !values.isEmpty else { return false }
    return Set(values).count == values.count && values.allSatisfy { !$0.isEmpty }
  }

  static func isSymlink(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
  }

  static func errorCode(_ error: Error) -> String {
    (error as? VerificationError)?.description ?? String(describing: error)
  }
}
