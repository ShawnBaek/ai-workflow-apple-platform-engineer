import Foundation
import Testing

@testable import AppleVerificationCore

@Test func canonicalIdentityVectorsAndSchemaTypes() throws {
  let value: [String: Any] = ["z": NSNull(), "a": "é🧭\n", "bool": true, "int": 1]
  #expect(
    String(decoding: try HarnessRuntime.canonicalJSON(value), as: UTF8.self)
      == #"{"a":"\u00e9\ud83e\udded\n","bool":true,"int":1,"z":null}"#)
  #expect(
    String(decoding: try HarnessRuntime.canonicalJSON(value, ensureASCII: false), as: UTF8.self)
      .contains("é🧭"))
  #expect(
    HarnessRuntime.sha256(Data("abc".utf8))
      == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  #expect(!JSONSchemaValidator.equal(true, 1))
  #expect(JSONSchemaValidator.equal(1, 1.0))
  #expect(!JSONSchemaValidator.errors(instance: true, schema: ["type": "integer"]).isEmpty)
  #expect(JSONSchemaValidator.errors(instance: [true, 1], schema: ["uniqueItems": true]).isEmpty)
  #expect(!JSONSchemaValidator.errors(instance: [1, 1.0], schema: ["uniqueItems": true]).isEmpty)
  let schema: [String: Any] = [
    "type": "object", "required": ["mode"],
    "properties": ["mode": ["enum": ["local", "remote"]], "receipt": ["type": "string"]],
    "additionalProperties": false, "if": ["properties": ["mode": ["const": "remote"]]],
    "then": ["required": ["receipt"]],
  ]
  #expect(JSONSchemaValidator.errors(instance: ["mode": "local"], schema: schema).isEmpty)
  #expect(!JSONSchemaValidator.errors(instance: ["mode": "remote"], schema: schema).isEmpty)
  #expect(
    !JSONSchemaValidator.errors(instance: ["mode": "local", "extra": true], schema: schema).isEmpty)
  #expect(!JSONSchemaValidator.errors(instance: 1, schema: ["madeUpAssertion": 1]).isEmpty)
}

@Test func processOutputTimeoutAndArgumentBoundaries() throws {
  let result = try HarnessRuntime.run(
    executable: "/usr/bin/printf", arguments: ["%s", "literal $(false); é"], timeout: 3)
  #expect(result.exitCode == 0)
  #expect(result.stdout == "literal $(false); é")
  #expect(!result.timedOut)
  let noisy = try HarnessRuntime.run(
    executable: "/usr/bin/yes", arguments: ["bounded"], timeout: 0.08, maxOutputBytes: 1_024)
  #expect(noisy.timedOut)
  #expect(noisy.truncated)
  #expect(noisy.stdout.utf8.count == 1_024)
  let sleeping = try HarnessRuntime.run(
    executable: "/bin/sh", arguments: ["-c", "sleep 5"], timeout: 0.08)
  #expect(sleeping.timedOut)
  #expect(sleeping.exitCode != 0)
}

@Test func atomicOutputAndLockOwnership() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    .resolvingSymlinksInPath()
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let output = root.appendingPathComponent("state.json")
  let lock = root.appendingPathComponent("state.lock")
  try HarnessRuntime.withFileLock(at: lock) {
    try HarnessRuntime.atomicWriteJSON(["generation": 1], to: output)
    #expect(throws: VerificationError.self) {
      try HarnessRuntime.withFileLock(at: lock, timeout: 0.02) {}
    }
  }
  try HarnessRuntime.withFileLock(at: lock) {
    try HarnessRuntime.atomicWriteJSON(["generation": 2], to: output)
  }
  #expect(try HarnessRuntime.object(output)["generation"] as? Int == 2)
  #expect(try HarnessRuntime.sha256File(output) == HarnessRuntime.sha256(Data(contentsOf: output)))
  let alias = root.appendingPathComponent("alias.json")
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: output)
  #expect(throws: VerificationError.self) {
    try HarnessRuntime.atomicWriteJSON(["generation": 3], to: alias)
  }
  #expect(try HarnessRuntime.object(output)["generation"] as? Int == 2)
}

@Test func boundedInputsRejectSymlinksAndOversizeBeforeReading() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("input.json")
  let alias = root.appendingPathComponent("alias.json")
  try Data("{\"n\":1}".utf8).write(to: file)
  #expect(try HarnessRuntime.readRegularFile(file, maximumBytes: 7).count == 7)
  #expect(throws: VerificationError.self) {
    try HarnessRuntime.readRegularFile(file, maximumBytes: 6)
  }
  try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
  #expect(throws: (any Error).self) { try HarnessRuntime.loadJSON(alias) }
}
