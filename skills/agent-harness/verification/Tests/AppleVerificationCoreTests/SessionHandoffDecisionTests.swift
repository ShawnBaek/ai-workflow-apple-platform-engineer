import Foundation
import Testing
import os

@testable import AppleVerificationCore

private struct DecisionFixture {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  let repo: URL
  let place: SessionHandoff.Place
  let thread: String
  let continuation: String

  init(writer: String = "codex") throws {
    repo = root.appendingPathComponent("app")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try Self.git(["init", "-q", "-b", "main"], in: repo)
    try Self.git(["commit", "-q", "--allow-empty", "-m", "initial"], in: repo)
    place = try SessionHandoff.place(repo.path)
    let handoff = try SessionHandoff.create(
      place: place, from: writer, to: writer == "codex" ? "claude" : "codex",
      task: "Deliver one shared outcome", brief: "Completed: discovery. Remaining: peer decisions.",
      session: "writer-native", targetSession: "peer-native", surface: "desktop",
      targetSurface: "desktop")
    thread = handoff.thread
    continuation = try #require(handoff.id)
  }

  static func git(_ args: [String], in repo: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments =
      ["-C", repo.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com"] + args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
  }

  func proposal(writer: String = "codex", supersedes: String? = nil) throws -> SessionHandoff.Event
  {
    try SessionHandoff.propose(
      place: place, thread: thread, from: writer, to: writer == "codex" ? "claude" : "codex",
      task: "Agree on the implementation method",
      brief: "Use distinct proposal and decision events.",
      session: "writer-native", surface: "desktop", targetSession: "peer-native",
      targetSurface: "desktop", supersedes: supersedes)
  }

  func shown(_ current: SessionHandoff.Place? = nil) throws -> String {
    let events = try SessionHandoff.read(place.ledger).events.filter { $0.thread == thread }
    return SessionHandoff.decisionSummary(events, place: current ?? place)
  }
}

private func expectDecisionError(_ fragment: String, _ operation: () throws -> Void) {
  do {
    try operation()
    Issue.record("Expected rejection containing \(fragment)")
  } catch { #expect(String(describing: error).contains(fragment)) }
}

@Test(arguments: ["claude", "codex"])
func liveProtocolPhasesKeepPendingWorkAndSeparateAgreementFromImplementation(writer: String) throws
{
  let f = try DecisionFixture(writer: writer)
  defer { try? FileManager.default.removeItem(at: f.root) }
  let peer = writer == "codex" ? "claude" : "codex"
  let v1 = try f.proposal(writer: writer)
  #expect(v1.event == "proposal" && v1.proposalRevision == 1)
  #expect(v1.id?.hasPrefix("p-") == true)
  var events = try SessionHandoff.read(f.place.ledger).events
  #expect(SessionHandoff.pending(events, for: peer).compactMap(\.id) == [f.continuation])
  let unchanged = try Data(contentsOf: f.place.ledger)
  #expect(throws: VerificationError.self) {
    try SessionHandoff.resume(
      place: f.place, as: peer, id: v1.id, session: "peer-native", executable: "/ape")
  }
  #expect(try Data(contentsOf: f.place.ledger) == unchanged)
  let actualReply = "phase=approach\nchanges-requested: preserve waiting handoffs.\n"
  let requested = try SessionHandoff.respond(
    place: f.place, id: try #require(v1.id), as: peer, session: "peer-native", surface: "desktop",
    recordedBy: writer, decision: "changes-requested", brief: actualReply)
  #expect(requested.brief == actualReply)
  #expect(requested.respondent == peer && requested.recordedBy == writer && requested.by == nil)
  #expect(requested.id?.hasPrefix("d-") == true)
  let v2 = try f.proposal(writer: writer, supersedes: v1.id)
  #expect(v2.proposalRevision == 2 && v2.supersedes == v1.id)
  #expect(try f.shown().contains("Approach: pending"))
  _ = try SessionHandoff.respond(
    place: f.place, id: try #require(v2.id), as: peer, session: "peer-native", surface: "desktop",
    recordedBy: writer, decision: "approve", brief: "Approve the exact revised method only.")
  #expect(try f.shown().contains("Approach: approve"))
  #expect(try f.shown().contains("Implementation verification: no peer verdict recorded"))
  events = try SessionHandoff.read(f.place.ledger).events
  #expect(SessionHandoff.pending(events, for: peer).compactMap(\.id) == [f.continuation])
  try DecisionFixture.git(["commit", "-q", "--allow-empty", "-m", "implementation"], in: f.repo)
  let implemented = try SessionHandoff.place(f.repo.path)
  #expect(try f.shown(implemented).contains("Approach: approve"))
  let review = try SessionHandoff.create(
    place: implemented, from: writer, to: peer, task: "Verify the implemented method",
    brief: "Review the frozen implementation.",
    thread: f.thread, session: "writer-native", purpose: "review", targetSession: "peer-native",
    reviewBase: f.place.head, surface: "desktop", targetSurface: "desktop")
  let verdict = try SessionHandoff.respond(
    place: implemented, id: try #require(review.id), as: peer, session: "peer-native",
    surface: "desktop",
    recordedBy: writer, decision: "approve", brief: "Verified this exact implementation HEAD.")
  #expect(verdict.purpose == "implementation-verification" && verdict.head == implemented.head)
  #expect(try f.shown(implemented).contains("Implementation verification: approve"))
  _ = try SessionHandoff.create(
    place: implemented, from: peer, to: writer, task: "Continue after verified work",
    brief: "The exact implementation remains verified.", thread: f.thread,
    session: "peer-native", surface: "desktop")
  #expect(try f.shown(implemented).contains("Implementation verification: approve"))
  try DecisionFixture.git(["commit", "-q", "--allow-empty", "-m", "later change"], in: f.repo)
  let moved = try SessionHandoff.place(f.repo.path)
  #expect(try f.shown(moved).contains("Implementation verification: stale"))
  #expect(try f.shown(moved).contains("Approach: approve"))
}

@Test func supersededUnansweredProposalRejectsApprovalForSupersessionSpecifically() throws {
  let f = try DecisionFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let first = try f.proposal()
  let next = try f.proposal(supersedes: first.id)
  let bytes = try Data(contentsOf: f.place.ledger)
  expectDecisionError("superseded") {
    _ = try SessionHandoff.respond(
      place: f.place, id: try #require(first.id), as: "claude", session: "peer-native",
      surface: "desktop",
      recordedBy: "codex", decision: "approve", brief: "Delayed response")
  }
  #expect(try Data(contentsOf: f.place.ledger) == bytes)
  expectDecisionError("--supersedes") { _ = try f.proposal(supersedes: first.id) }
  #expect(try Data(contentsOf: f.place.ledger) == bytes)
  #expect(next.proposalRevision == 2)
}

@Test func peerDecisionRejectsWrongIdentityDuplicateAndContinuationWithoutAppending() throws {
  let f = try DecisionFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let proposal = try f.proposal()
  let id = try #require(proposal.id)
  let before = try Data(contentsOf: f.place.ledger)
  for (peer, session, surface) in [
    ("codex", "writer-native", "desktop"), ("claude", "someone-else", "desktop"),
    ("claude", "peer-native", "cli"),
  ] {
    expectDecisionError("addressed peer") {
      _ = try SessionHandoff.respond(
        place: f.place, id: id, as: peer, session: session, surface: surface,
        recordedBy: "codex", decision: "approve", brief: "Not from the addressed native peer")
    }
    #expect(try Data(contentsOf: f.place.ledger) == before)
  }
  expectDecisionError("Continuation") {
    _ = try SessionHandoff.respond(
      place: f.place, id: f.continuation, as: "claude", session: "peer-native", surface: "desktop",
      recordedBy: "codex", decision: "approve", brief: "Pickup is not agreement")
  }
  #expect(try Data(contentsOf: f.place.ledger) == before)
  _ = try SessionHandoff.respond(
    place: f.place, id: id, as: "claude", session: "peer-native", surface: "desktop",
    recordedBy: "codex", decision: "approve", brief: "Actual peer agreement")
  let decided = try Data(contentsOf: f.place.ledger)
  expectDecisionError("already has a decision") {
    _ = try SessionHandoff.respond(
      place: f.place, id: id, as: "claude", session: "peer-native", surface: "desktop",
      recordedBy: "user", decision: "changes-requested", brief: "A new verdict needs a new request")
  }
  #expect(try Data(contentsOf: f.place.ledger) == decided)
}

@Test func proposalDecisionRejectsDirtyMovedAndClosedContextWithoutAppending() throws {
  let f = try DecisionFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let proposal = try f.proposal()
  let id = try #require(proposal.id)
  let before = try Data(contentsOf: f.place.ledger)
  try Data("work in progress".utf8).write(to: f.repo.appendingPathComponent("new.txt"))
  let dirty = try SessionHandoff.place(f.repo.path)
  expectDecisionError("snapshot changed") {
    _ = try SessionHandoff.respond(
      place: dirty, id: id, as: "claude", session: "peer-native", surface: "desktop",
      recordedBy: "codex", decision: "approve", brief: "Cannot approve changed context")
  }
  #expect(try Data(contentsOf: f.place.ledger) == before)
  try DecisionFixture.git(["add", "new.txt"], in: f.repo)
  try DecisionFixture.git(["commit", "-q", "-m", "changed context"], in: f.repo)
  let moved = try SessionHandoff.place(f.repo.path)
  expectDecisionError("snapshot changed") {
    _ = try SessionHandoff.respond(
      place: moved, id: id, as: "claude", session: "peer-native", surface: "desktop",
      recordedBy: "codex", decision: "approve", brief: "Cannot approve changed context")
  }
  #expect(try Data(contentsOf: f.place.ledger) == before)
  _ = try SessionHandoff.execute(
    arguments: ["close", "--repo", f.place.top, "--thread", f.thread, "--by", "codex"],
    executable: "/ape")
  let closed = try Data(contentsOf: f.place.ledger)
  expectDecisionError("closed") { _ = try f.proposal(supersedes: id) }
  #expect(try Data(contentsOf: f.place.ledger) == closed)
}

@Test func proposalReplacementAndResponseSerializeAndNeverLeaveStaleEffectiveApproval() throws {
  let f = try DecisionFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let first = try f.proposal()
  let id = try #require(first.id)
  let place = f.place
  let thread = f.thread
  let result = OSAllocatedUnfairLock(initialState: [String]())
  let ready = DispatchGroup()
  let finished = DispatchGroup()
  let start = DispatchSemaphore(value: 0)
  for operation in 0..<2 {
    ready.enter()
    finished.enter()
    DispatchQueue.global().async {
      ready.leave()
      _ = start.wait(timeout: .now() + 10)
      defer { finished.leave() }
      do {
        if operation == 0 {
          _ = try SessionHandoff.propose(
            place: place, thread: thread, from: "codex", to: "claude", task: "Revised method",
            brief: "New method", session: "writer-native", surface: "desktop",
            targetSession: "peer-native",
            targetSurface: "desktop", supersedes: id)
          result.withLock { $0.append("replacement") }
        } else {
          _ = try SessionHandoff.respond(
            place: place, id: id, as: "claude", session: "peer-native", surface: "desktop",
            recordedBy: "codex", decision: "approve", brief: "Actual old-method response")
          result.withLock { $0.append("old decision") }
        }
      } catch { result.withLock { $0.append(String(describing: error)) } }
    }
  }
  #expect(ready.wait(timeout: .now() + 10) == .success)
  start.signal()
  start.signal()
  #expect(finished.wait(timeout: .now() + 10) == .success)
  let outcomes = result.withLock { $0 }
  #expect(outcomes.contains("replacement"))
  #expect(
    outcomes.contains("old decision") || outcomes.contains(where: { $0.contains("superseded") }))
  let ledger = try SessionHandoff.read(place.ledger)
  #expect(ledger.unreadable == 0)
  #expect(ledger.events.filter { $0.event == "proposal" }.count == 2)
  #expect(try f.shown().contains("Approach: pending"))
}

@Test func decisionCommandsPreserveActualReplyAndUnknownEventsRenderNeutrally() throws {
  let f = try DecisionFixture()
  defer { try? FileManager.default.removeItem(at: f.root) }
  let brief = f.root.appendingPathComponent("proposal.md")
  try "Method text".write(to: brief, atomically: true, encoding: .utf8)
  let (prompt, _) = try SessionHandoff.execute(
    arguments: [
      "propose", "--repo", f.place.top, "--thread", f.thread, "--from", "codex", "--to", "claude",
      "--task", "Method", "--brief-file", brief.path, "--session", "writer-native", "--surface",
      "desktop",
      "--target-session", "peer-native", "--target-surface", "desktop",
    ], executable: "/ape")
  #expect(prompt.contains("before EACH review message"))
  #expect(prompt.contains("not a writer handoff or implementation verdict"))
  let proposal = try #require(try SessionHandoff.read(f.place.ledger).events.last)
  try "Actual peer reply\nwith limitations.\n".write(to: brief, atomically: true, encoding: .utf8)
  let (recorded, _) = try SessionHandoff.execute(
    arguments: [
      "respond", "--repo", f.place.top, "--id", try #require(proposal.id), "--as", "claude",
      "--session", "peer-native", "--surface", "desktop", "--by", "codex", "--decision", "approve",
      "--brief-file", brief.path,
    ], executable: "/ape")
  #expect(recorded.contains("Decision d-"))
  try SessionHandoff.append(
    .init(event: "future-event", thread: f.thread, at: "2026-10-18T00:00:00Z"), to: f.place.ledger)
  let (shown, _) = try SessionHandoff.execute(
    arguments: ["show", "--repo", f.place.top, "--thread", f.thread], executable: "/ape")
  #expect(shown.contains("Actual peer reply\nwith limitations.\n"))
  #expect(shown.contains("recorded event future-event"))
  #expect(!shown.contains("closed the thread"))
  let bytes = try Data(contentsOf: f.place.ledger)
  let handle = try FileHandle(forWritingTo: f.place.ledger)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data("broken ledger line\n".utf8))
  try handle.close()
  expectDecisionError("Unreadable") { _ = try f.proposal(supersedes: proposal.id) }
  #expect(try Data(contentsOf: f.place.ledger) == bytes + Data("broken ledger line\n".utf8))
}

@Test func decisionTransactionsRefreshCapturedPlaceAfterCheckoutChanges() throws {
  for commit in [false, true] {
    let f = try DecisionFixture()
    defer { try? FileManager.default.removeItem(at: f.root) }
    let proposal = try f.proposal()
    let bytes = try Data(contentsOf: f.place.ledger)
    try Data("changed after capture".utf8).write(to: f.repo.appendingPathComponent("changed.txt"))
    if commit {
      try DecisionFixture.git(["add", "changed.txt"], in: f.repo)
      try DecisionFixture.git(["commit", "-q", "-m", "moved after capture"], in: f.repo)
    }
    // Deliberately pass the original clean Place, as execute() can capture before waiting.
    expectDecisionError("snapshot changed") {
      _ = try SessionHandoff.respond(
        place: f.place, id: try #require(proposal.id), as: "claude", session: "peer-native",
        surface: "desktop", recordedBy: "codex", decision: "approve", brief: "Late response")
    }
    #expect(try Data(contentsOf: f.place.ledger) == bytes)
    expectDecisionError("snapshot changed") { _ = try f.proposal(supersedes: proposal.id) }
    #expect(try Data(contentsOf: f.place.ledger) == bytes)
  }
}
