import Foundation

/// The JSON Schema vocabulary used by the checked-in harness contracts.
/// Unsupported assertion keywords fail closed rather than silently succeeding.
public enum JSONSchemaValidator {
  public static func equal(_ lhs: Any, _ rhs: Any) -> Bool {
    if lhs is NSNull || rhs is NSNull { return lhs is NSNull && rhs is NSNull }
    if HarnessRuntime.isBoolean(lhs) || HarnessRuntime.isBoolean(rhs) {
      return HarnessRuntime.isBoolean(lhs) && HarnessRuntime.isBoolean(rhs)
        && (lhs as? NSNumber) == (rhs as? NSNumber)
    }
    if let left = lhs as? NSNumber, let right = rhs as? NSNumber {
      return left.compare(right) == .orderedSame
    }
    if let left = lhs as? String, let right = rhs as? String {
      return left.unicodeScalars.elementsEqual(right.unicodeScalars)
    }
    if let left = lhs as? [Any], let right = rhs as? [Any] {
      return left.count == right.count && zip(left, right).allSatisfy { equal($0, $1) }
    }
    if let left = lhs as? [String: Any], let right = rhs as? [String: Any] {
      return Set(left.keys) == Set(right.keys)
        && left.allSatisfy { equal($0.value, right[$0.key]!) }
    }
    return false
  }

  public static func errors(
    instance: Any, schema: [String: Any], path: String = "$", root: [String: Any]? = nil
  ) -> [String] {
    validate(instance, schema: schema, path: path, root: root ?? schema, depth: 0)
  }

  private static func matchesType(_ value: Any, _ type: String) -> Bool {
    switch type {
    case "null": return value is NSNull
    case "boolean": return HarnessRuntime.isBoolean(value)
    case "string": return value is String
    case "object": return value is [String: Any]
    case "array": return value is [Any]
    case "number":
      return !HarnessRuntime.isBoolean(value) && (value as? NSNumber)?.doubleValue.isFinite == true
    case "integer":
      guard !HarnessRuntime.isBoolean(value), let number = value as? NSNumber else { return false }
      return number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue
    default: return false
    }
  }

  private static func validate(
    _ instance: Any, schema: [String: Any], path: String, root: [String: Any], depth: Int
  ) -> [String] {
    guard depth < 128 else { return ["\(path): schema nesting exceeds 128"] }
    let supported: Set<String> = [
      "$schema", "$id", "$ref", "$defs", "definitions", "$comment", "title", "description",
      "default", "examples", "deprecated", "readOnly", "writeOnly", "type", "const", "enum",
      "minLength", "maxLength", "pattern", "format", "minimum", "maximum", "exclusiveMinimum",
      "exclusiveMaximum", "multipleOf", "minItems", "maxItems", "uniqueItems", "items",
      "prefixItems", "contains", "minContains", "maxContains", "minProperties", "maxProperties",
      "properties", "patternProperties", "additionalProperties", "required", "dependentRequired",
      "allOf", "anyOf", "oneOf", "not", "if", "then", "else",
    ]
    var result = schema.keys.filter { !supported.contains($0) }.sorted().map {
      "\(path): unsupported schema keyword \($0)"
    }
    func child(_ value: Any, _ specification: Any, _ childPath: String) -> [String] {
      if HarnessRuntime.isBoolean(specification), let flag = specification as? Bool {
        return flag ? [] : ["\(childPath): forbidden by schema"]
      }
      guard let specification = specification as? [String: Any] else {
        return ["\(childPath): invalid schema"]
      }
      return validate(value, schema: specification, path: childPath, root: root, depth: depth + 1)
    }
    if let reference = schema["$ref"] as? String {
      if !reference.hasPrefix("#/") {
        result.append("\(path): only local JSON Schema references are supported")
      } else {
        var target: Any = root
        for component in reference.dropFirst(2).split(
          separator: "/", omittingEmptySubsequences: false)
        {
          let key = component.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(
            of: "~0", with: "~")
          guard let next = (target as? [String: Any])?[key] else {
            return result + ["\(path): unresolved schema reference \(reference)"]
          }
          target = next
        }
        result += child(instance, target, path)
      }
    }
    if let type = schema["type"] {
      let types = (type as? [String]) ?? (type as? String).map { [$0] } ?? []
      if !types.contains(where: { matchesType(instance, $0) }) {
        return result + ["\(path): expected type \(types.joined(separator: " or "))"]
      }
    }
    if let constant = schema["const"], !equal(instance, constant) {
      result.append("\(path): does not equal const")
    }
    if let choices = schema["enum"] as? [Any], !choices.contains(where: { equal(instance, $0) }) {
      result.append("\(path): value is not in enum")
    }
    if let string = instance as? String {
      let count = string.unicodeScalars.count
      if let min = schema["minLength"] as? Int, count < min {
        result.append("\(path): string shorter than minLength")
      }
      if let max = schema["maxLength"] as? Int, count > max {
        result.append("\(path): string longer than maxLength")
      }
      if let pattern = schema["pattern"] as? String {
        do {
          if try NSRegularExpression(pattern: pattern).firstMatch(
            in: string, range: NSRange(string.startIndex..., in: string)) == nil
          {
            result.append("\(path): pattern mismatch")
          }
        } catch { result.append("\(path): invalid schema pattern") }
      }
      if let format = schema["format"] as? String {
        switch format {
        case "date-time":
          if (try? HarnessRuntime.parseTimestamp(string)) == nil {
            result.append("\(path): expected RFC3339 date-time")
          }
        case "uri":
          if URL(string: string)?.scheme == nil { result.append("\(path): expected absolute URI") }
        case "uuid": if UUID(uuidString: string) == nil { result.append("\(path): expected UUID") }
        default: result.append("\(path): unsupported schema format \(format)")
        }
      }
    }
    if !HarnessRuntime.isBoolean(instance), let number = instance as? NSNumber {
      let value = number.doubleValue
      if !value.isFinite { result.append("\(path): non-finite JSON number") }
      for (key, comparison) in [
        ("minimum", { (a: Double, b: Double) in a < b }), ("maximum", { a, b in a > b }),
        ("exclusiveMinimum", { a, b in a <= b }), ("exclusiveMaximum", { a, b in a >= b }),
      ] {
        if let limit = schema[key] as? NSNumber, comparison(value, limit.doubleValue) {
          result.append("\(path): violates \(key)")
        }
      }
      if let divisor = schema["multipleOf"] as? NSNumber {
        let quotient = value / divisor.doubleValue
        if divisor.doubleValue <= 0 || !quotient.isFinite || quotient.rounded() != quotient {
          result.append("\(path): violates multipleOf")
        }
      }
    }
    if let array = instance as? [Any] {
      if let min = schema["minItems"] as? Int, array.count < min {
        result.append("\(path): fewer than minItems")
      }
      if let max = schema["maxItems"] as? Int, array.count > max {
        result.append("\(path): more than maxItems")
      }
      if schema["uniqueItems"] as? Bool == true {
        var duplicate = false
        for i in array.indices {
          if array[..<i].contains(where: { equal($0, array[i]) }) {
            duplicate = true
            break
          }
        }
        if duplicate { result.append("\(path): items must be unique") }
      }
      let prefixes = schema["prefixItems"] as? [Any] ?? []
      for (i, value) in array.enumerated() {
        if i < prefixes.count {
          result += child(value, prefixes[i], "\(path)[\(i)]")
        } else if let items = schema["items"] {
          result += child(value, items, "\(path)[\(i)]")
        }
      }
      if let contains = schema["contains"] {
        let count = array.filter { child($0, contains, path).isEmpty }.count
        if count < (schema["minContains"] as? Int ?? 1)
          || count > (schema["maxContains"] as? Int ?? Int.max)
        {
          result.append("\(path): contains count outside required bounds")
        }
      }
    }
    if let object = instance as? [String: Any] {
      if let min = schema["minProperties"] as? Int, object.count < min {
        result.append("\(path): fewer than minProperties")
      }
      if let max = schema["maxProperties"] as? Int, object.count > max {
        result.append("\(path): more than maxProperties")
      }
      for key in schema["required"] as? [String] ?? [] where object[key] == nil {
        result.append("\(path): missing required property \(key)")
      }
      let properties = schema["properties"] as? [String: Any] ?? [:]
      let patterns = schema["patternProperties"] as? [String: Any] ?? [:]
      for key in object.keys.sorted() {
        let value = object[key]!
        var matched = false
        if let specification = properties[key] {
          matched = true
          result += child(value, specification, "\(path).\(key)")
        }
        for pattern in patterns.keys.sorted() {
          guard let expression = try? NSRegularExpression(pattern: pattern) else {
            result.append("\(path): invalid patternProperties expression")
            continue
          }
          if expression.firstMatch(in: key, range: NSRange(key.startIndex..., in: key)) != nil {
            matched = true
            result += child(value, patterns[pattern]!, "\(path).\(key)")
          }
        }
        if !matched, let additional = schema["additionalProperties"] {
          result += child(value, additional, "\(path).\(key)")
        }
      }
      for (key, dependencies) in schema["dependentRequired"] as? [String: [String]] ?? [:]
      where object[key] != nil {
        for dependency in dependencies where object[dependency] == nil {
          result.append("\(path): \(key) requires \(dependency)")
        }
      }
    }
    for branch in schema["allOf"] as? [Any] ?? [] { result += child(instance, branch, path) }
    for key in ["oneOf", "anyOf"] {
      if let branches = schema[key] as? [Any] {
        let count = branches.filter { child(instance, $0, path).isEmpty }.count
        if (key == "oneOf" && count != 1) || (key == "anyOf" && count == 0) {
          result.append("\(path): violates \(key) (matched \(count))")
        }
      }
    }
    if let forbidden = schema["not"], child(instance, forbidden, path).isEmpty {
      result.append("\(path): matches forbidden schema")
    }
    if let condition = schema["if"],
      let branch = schema[child(instance, condition, path).isEmpty ? "then" : "else"]
    {
      result += child(instance, branch, path)
    }
    return result
  }
}
