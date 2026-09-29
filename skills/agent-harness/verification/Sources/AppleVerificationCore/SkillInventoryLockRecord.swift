import CryptoKit
import Darwin
import Foundation

extension SkillInventory {
  /// A lowercase 40-digit hexadecimal SHA-1 Git object ID.
  static func isGitObjectID(_ value: String) -> Bool {
    value.utf8.count == 40
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  /// Folders and files a skill folder never has in the repository: Git keeps `.git` out of every
  /// tree, and the repository's `.gitignore` excludes the rest, so neither the recorded tree nor
  /// the Skills CLI's copy of it has them. A verifier built inside an installed copy adds `.build`.
  static let untrackedFolders: Set<String> = [".git", ".build", ".swiftpm", "__pycache__"]

  static func isUntrackedFile(_ name: String) -> Bool {
    name == ".DS_Store" || [".pyc", ".pyo", ".pyd"].contains { name.hasSuffix($0) }
  }

  /// The Git tree ID of a skill folder, as `git write-tree` computes it for that folder's files
  /// and as the Skills CLI records it in `skillFolderHash` from GitHub's Trees API: each regular
  /// file is a blob with mode `100755` when its owner may execute it and `100644` otherwise, each
  /// non-empty folder a tree, entries in Git's byte order. The CLI copies the tree's files with
  /// their mode and a link's target, so an unchanged installation reproduces the recorded ID.
  /// Nil when the folder holds a link or a special file (which the CLI never installs), cannot be
  /// read, or exceeds the bounds the collection hash uses.
  static func gitTreeID(_ folder: String) -> String? {
    var budget = (files: 0, bytes: 0)
    guard let id = try? treeObject(folder, budget: &budget) else { return nil }
    return id.map { String(format: "%02x", $0) }.joined()
  }

  /// The tree object ID of `folder`, or nil for a folder with no file, which Git does not record.
  private static func treeObject(_ folder: String, budget: inout (files: Int, bytes: Int)) throws
    -> Data?
  {
    let maximumFileBytes = 64 * 1_024 * 1_024
    var entries = [(key: [UInt8], record: Data)]()
    for name in try FileManager.default.contentsOfDirectory(atPath: folder) {
      let path = (folder as NSString).appendingPathComponent(name)
      var info = stat()
      guard lstat(path, &info) == 0 else { throw VerificationError.invalid("unreadable entry") }
      var key = Array(name.utf8)
      let mode: String
      let id: Data
      switch info.st_mode & S_IFMT {
      case S_IFDIR:
        guard !untrackedFolders.contains(name), let tree = try treeObject(path, budget: &budget)
        else { continue }
        // Git orders a tree as if its name ended with a slash.
        key.append(0x2F)
        mode = "40000"
        id = tree
      case S_IFREG:
        guard !isUntrackedFile(name) else { continue }
        budget.files += 1
        let size = Int(info.st_size)
        guard budget.files <= 10_000, size <= maximumFileBytes,
          budget.bytes <= 256 * 1_024 * 1_024 - size
        else { throw VerificationError.invalid("skill folder exceeds its bounded read limit") }
        let content = try HarnessRuntime.readRegularFile(
          URL(fileURLWithPath: path), maximumBytes: maximumFileBytes)
        budget.bytes += content.count
        mode = info.st_mode & S_IXUSR != 0 ? "100755" : "100644"
        id = gitObject("blob", content)
      default:
        throw VerificationError.invalid("a link or special file has no installed Git tree")
      }
      var record = Data("\(mode) \(name)".utf8)
      record.append(0)
      record.append(id)
      entries.append((key, record))
    }
    guard !entries.isEmpty else { return nil }
    var body = Data()
    for entry in entries.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
      body.append(entry.record)
    }
    return gitObject("tree", body)
  }

  private static func gitObject(_ type: String, _ body: Data) -> Data {
    var hasher = Insecure.SHA1()
    hasher.update(data: Data("\(type) \(body.count)\u{0}".utf8))
    hasher.update(data: body)
    return Data(hasher.finalize())
  }

  /// The commit a Git checkout's `HEAD` names, read from its `.git` folder, or from the folder a
  /// linked worktree's `.git` file names, without running Git: `HEAD`, `commondir`, the one loose
  /// ref `HEAD` names and `packed-refs`. Uncommitted edits are not reflected. Nil for anything
  /// else, such as no checkout, an unborn branch or a reftable repository.
  static func headCommit(_ root: String) -> String? {
    func read(_ path: String) -> String? {
      guard Node(path) == .file,
        let data = try? HarnessRuntime.readRegularFile(
          URL(fileURLWithPath: path), maximumBytes: 16 * 1_024 * 1_024)
      else { return nil }
      return String(decoding: data, as: UTF8.self)
    }
    func resolve(_ path: String, from base: String) -> String {
      path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
    }
    let dotGit = (root as NSString).appendingPathComponent(".git")
    let gitFolder: String
    switch Node(dotGit) {
    case .directory: gitFolder = dotGit
    case .file:
      guard let text = read(dotGit), text.hasPrefix("gitdir: ") else { return nil }
      gitFolder = resolve(
        text.dropFirst(8).trimmingCharacters(in: .whitespacesAndNewlines), from: root)
    case .absent, .other: return nil
    }
    let folder = gitFolder as NSString
    guard
      let head = read(folder.appendingPathComponent("HEAD"))?.trimmingCharacters(
        in: .whitespacesAndNewlines)
    else { return nil }
    if isGitObjectID(head) { return head }
    guard head.hasPrefix("ref: refs/") else { return nil }
    let ref = String(head.dropFirst(5))
    guard !ref.split(separator: "/").contains(where: { $0 == ".." || $0 == "." }) else {
      return nil
    }
    let common =
      read(folder.appendingPathComponent("commondir")).map {
        resolve($0.trimmingCharacters(in: .whitespacesAndNewlines), from: gitFolder)
      } ?? gitFolder
    if let loose = read((common as NSString).appendingPathComponent(ref))?
      .trimmingCharacters(in: .whitespacesAndNewlines), isGitObjectID(loose)
    {
      return loose
    }
    for line in read((common as NSString).appendingPathComponent("packed-refs"))?
      .split(separator: "\n") ?? []
    {
      let parts = line.split(separator: " ", maxSplits: 1)
      if parts.count == 2, parts[1] == ref, isGitObjectID(String(parts[0])) {
        return String(parts[0])
      }
    }
    return nil
  }
}
