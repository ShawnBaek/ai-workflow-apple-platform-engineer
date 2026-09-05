import CryptoKit
import Foundation

public struct RepositoryReport: Encodable, Sendable {
  public let check = "repository-contracts-and-documents-v2"
  public let status: String
  public let skillNames: [String]
  public let documentsChecked: Int
  public let localLinksChecked: Int
  public let validatedDocumentDigest: String
  public let errors: [String]
  public let limitations = [
    "External URLs and Markdown anchors are not fetched or validated",
    "No app, Simulator, model-quality, or performance claim",
  ]
}

public enum RepositoryValidation {
  private static let excluded = Set([".git", ".build", ".swiftpm", "node_modules", "__pycache__"])
  private static let maxDocumentBytes = 4 * 1024 * 1024

  /// Validates repository metadata, documentation and the shipped runtime contracts.
  public static func validate(root: URL, includeContracts: Bool = true) throws -> RepositoryReport {
    let root = root.standardizedFileURL.resolvingSymlinksInPath()
    let manager = FileManager.default
    let skills = root.appendingPathComponent("skills", isDirectory: true)
    var errors = [String]()
    var names = [String]()
    var links = 0
    var texts = [String: String]()
    var digest = SHA256()
    guard manager.fileExists(atPath: skills.path) else {
      throw VerificationError.invalid("Repository root has no skills directory")
    }
    let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
    var enumerationFailure: Error?
    guard
      let enumerator = manager.enumerator(
        at: root, includingPropertiesForKeys: keys,
        errorHandler: { _, error in
          enumerationFailure = error
          return false
        })
    else {
      throw VerificationError.invalid("Cannot enumerate repository")
    }
    var documents = [URL]()
    for case let enumerated as URL in enumerator {
      let file = enumerated.standardizedFileURL
      let values = try file.resourceValues(forKeys: Set(keys))
      if values.isDirectory == true {
        if excluded.contains(file.lastPathComponent) { enumerator.skipDescendants() }
        continue
      }
      guard ["md", "json", "jsonl"].contains(file.pathExtension) else { continue }
      if values.isSymbolicLink == true {
        errors.append("Document symlink requires explicit review: \(relative(file, to: root))")
        continue
      }
      guard (values.fileSize ?? Int.max) <= maxDocumentBytes else {
        errors.append("Document exceeds 4 MiB: \(relative(file, to: root))")
        continue
      }
      documents.append(file.resolvingSymlinksInPath())
      guard documents.count <= 4096 else { throw VerificationError.invalid("Too many documents") }
    }
    if let enumerationFailure { throw enumerationFailure }
    for file in documents.sorted(by: { $0.path < $1.path }) {
      let path = relative(file, to: root)
      let data = try Data(contentsOf: file, options: [.mappedIfSafe])
      guard data.count <= maxDocumentBytes else {
        throw VerificationError.invalid("Document grew beyond limit: \(path)")
      }
      digest.update(data: Data(path.utf8))
      digest.update(data: Data([0]))
      digest.update(data: Data(SHA256.hash(data: data)))
      digest.update(data: Data([0]))
      guard let text = String(data: data, encoding: .utf8) else {
        errors.append("Not UTF-8: \(path)")
        continue
      }
      texts[path] = text
      if file.pathExtension == "json" {
        do { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch
        { errors.append("Invalid JSON: \(path)") }
      } else if file.pathExtension == "jsonl" {
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false)
          .enumerated() where !line.trimmingCharacters(in: .whitespaces).isEmpty
        {
          do {
            _ = try JSONSerialization.jsonObject(
              with: Data(line.utf8), options: [.fragmentsAllowed])
          } catch { errors.append("Invalid JSONL: \(path):\(index + 1)") }
        }
      } else {
        let parsed = markdownBody(text)
        if parsed.unclosedFence { errors.append("Unclosed code fence: \(path)") }
        for destination in try matches(#"\]\(([^)\n]+)\)"#, in: parsed.prose) {
          guard let target = localDestination(destination) else { continue }
          links += 1
          let decoded = target.removingPercentEncoding ?? target
          let targetURL =
            decoded.hasPrefix("/")
            ? root.appendingPathComponent(String(decoded.dropFirst()))
            : file.deletingLastPathComponent().appendingPathComponent(decoded)
          let resolved = targetURL.standardizedFileURL.resolvingSymlinksInPath()
          if resolved.path != root.path && !resolved.path.hasPrefix(root.path + "/") {
            errors.append("Local link escapes repository: \(path) -> \(target)")
          } else if !manager.fileExists(atPath: resolved.path) {
            errors.append("Missing local link: \(path) -> \(target)")
          }
        }
      }
    }
    let folders = try manager.contentsOfDirectory(
      at: skills, includingPropertiesForKeys: [.isDirectoryKey])
    for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
    where try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
      let name = folder.lastPathComponent
      let path = "skills/\(name)/SKILL.md"
      guard let text = texts[path] else {
        errors.append("Missing skill entry point: \(path)")
        continue
      }
      let lines = text.components(separatedBy: "\n")
      guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else {
        errors.append("Missing frontmatter: \(path)")
        continue
      }
      let frontmatter = lines[1..<end].joined(separator: "\n")
      let declared = try matches(#"(?m)^name:\s*([a-z0-9]+(?:-[a-z0-9]+)*)\s*$"#, in: frontmatter)
      if declared != [name] || name.count > 64 {
        errors.append("Invalid skill name/folder: \(path)")
      }
      let descriptions = try matches(#"(?m)^description:\s*(.+)$"#, in: frontmatter)
      if descriptions.count != 1
        || ([">", ">-", "|", "|-"].contains(descriptions.first ?? "")
          && !lines[1..<end].contains(where: {
            $0.hasPrefix("  ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty
          }))
      {
        errors.append("Missing description: \(path)")
      }
      names.append(name)
    }
    if names.isEmpty { errors.append("No skills discovered") }
    let catalog = texts["docs/skills.md"] ?? ""
    for name in names where !catalog.contains("../skills/\(name)/SKILL.md") {
      errors.append("Skill catalog missing \(name)")
    }
    let version = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if version.isEmpty || !(texts["README.md"] ?? "").contains("**Version:** \(version)") {
      errors.append("README version must match VERSION")
    }
    if includeContracts {
      errors += ContractValidation.validateRepository(
        context: RuntimeContext(
          repositoryRoot: root, harnessRoot: root.appendingPathComponent("skills/agent-harness")))
    }
    return RepositoryReport(
      status: errors.isEmpty ? "passed" : "failed", skillNames: names,
      documentsChecked: documents.count, localLinksChecked: links,
      validatedDocumentDigest: digest.finalize().map { String(format: "%02x", $0) }.joined(),
      errors: errors.sorted())
  }

  private static func relative(_ url: URL, to root: URL) -> String {
    String(url.path.dropFirst(root.path.count + 1))
  }

  private static func matches(_ pattern: String, in text: String) throws -> [String] {
    let regex = try NSRegularExpression(pattern: pattern)
    let source = text as NSString
    return regex.matches(in: text, range: NSRange(location: 0, length: source.length)).map {
      source.substring(with: $0.range(at: 1))
    }
  }

  private static func localDestination(_ raw: String) -> String? {
    var value = raw.trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("<"), let end = value.firstIndex(of: ">") {
      value = String(value[value.index(after: value.startIndex)..<end])
    } else if let title = value.range(of: #"\s+[\"']"#, options: .regularExpression) {
      value = String(value[..<title.lowerBound])
    }
    if value.isEmpty || value.hasPrefix("#") || value.contains("://") || value.hasPrefix("mailto:")
    {
      return nil
    }
    value = String(value.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0])
    return value.isEmpty ? nil : value
  }

  private static func markdownBody(_ text: String) -> (prose: String, unclosedFence: Bool) {
    var delimiter: Character?
    var count = 0
    var prose = [String]()
    for line in text.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let first = trimmed.first, first == "`" || first == "~" {
        let length = trimmed.prefix(while: { $0 == first }).count
        if length >= 3 {
          if delimiter == nil {
            delimiter = first
            count = length
          } else if delimiter == first && length >= count
            && trimmed.dropFirst(length).trimmingCharacters(in: .whitespaces).isEmpty
          {
            delimiter = nil
          }
          continue
        }
      }
      if delimiter == nil { prose.append(line) }
    }
    return (prose.joined(separator: "\n"), delimiter != nil)
  }
}

public enum VerificationError: Error, CustomStringConvertible {
  case invalid(String)
  public var description: String {
    switch self {
    case .invalid(let message): return message
    }
  }
}
