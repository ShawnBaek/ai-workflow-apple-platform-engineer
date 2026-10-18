import Foundation
import Testing

@testable import AppleVerificationCore

private struct TransportFixture {
  let root: URL
  let repository: URL

  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    repository = root.appendingPathComponent("app")
    try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
    try git(["init", "-q", "-b", "main"])
    try git(["commit", "-q", "--allow-empty", "-m", "fixture"])
  }

  func git(_ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments =
      ["-C", repository.path, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.com"]
      + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
  }

  func request() throws -> (SessionHandoff.Place, SessionHandoff.Event) {
    let place = try SessionHandoff.place(repository.path)
    let root = try SessionHandoff.create(
      place: place, from: "claude", to: "codex", task: "Shared goal", brief: "Start here.",
      session: "claudeDesktop", targetSession: "codexDesktop", surface: "desktop",
      targetSurface: "desktop")
    let proposal = try SessionHandoff.propose(
      place: place, thread: root.thread, from: "claude", to: "codex", task: "Review method",
      brief: "Use the existing queue.", session: "claudeDesktop", surface: "desktop",
      targetSession: "codexDesktop", targetSurface: "desktop")
    return (place, proposal)
  }

  func queue(_ place: SessionHandoff.Place) -> URL {
    URL(fileURLWithPath: place.common).appendingPathComponent("ape-handoffs/transport/queue.json")
  }
}

private func transport(_ arguments: [String]) throws -> [String: Any] {
  let (output, warning) = try SessionHandoff.execute(
    arguments: ["transport"] + arguments, executable: "/opt/ape")
  #expect(warning == nil)
  return try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
}

private func transportOutput(_ arguments: [String]) throws -> String {
  let (output, warning) = try SessionHandoff.execute(
    arguments: ["transport"] + arguments, executable: "/opt/ape")
  #expect(warning == nil)
  return output
}

private func command(_ action: String, place: SessionHandoff.Place, _ values: [String]) -> [String]
{
  [action, "--repo", place.top] + values
}

@discardableResult
private func register(
  _ place: SessionHandoff.Place, dispatcher: String = "dispatcher", host: String = "host",
  target: String = "codexDesktop", sender: String = "claudeDesktop"
) throws -> [String: Any] {
  try transport(
    command(
      "register", place: place,
      [
        "--dispatcher", dispatcher, "--host", host, "--target-session", target,
        "--sender-session", sender, "--authorization", "user-authorized-test",
        "--ttl", "3600", "--limit", "10",
      ]))
}

@Test func transportRegistersDispatcherQueuesIdempotentlyAndCompletesVerbatimReply() throws {
  let fixture = try TransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let (place, request) = try fixture.request()

  #expect(throws: VerificationError.self) {
    _ = try transportOutput(
      command(
        "next", place: place,
        [
          "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
          "--wait", "0",
        ]))
  }
  #expect((try register(place))["status"] as? String == "registered")
  let idle = try transport(
    command(
      "next", place: place,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  #expect(idle["status"] as? String == "idle")
  let first = try transport(
    command(
      "send", place: place,
      [
        "--id", request.id!, "--as", "claude", "--session", "claudeDesktop", "--surface", "desktop",
        "--host", "host", "--timeout", "0",
      ]))
  let deliveryID = try #require(first["id"] as? String)
  #expect(first["status"] as? String == "queued")
  let duplicate = try transport(
    command(
      "send", place: place,
      [
        "--id", request.id!, "--as", "claude", "--session", "claudeDesktop", "--surface", "desktop",
        "--host", "host", "--timeout", "0",
      ]))
  #expect(duplicate["id"] as? String == deliveryID)

  let claimed = try transport(
    command(
      "next", place: place,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  let claim = try #require(claimed["claimToken"] as? String)
  #expect(claimed["status"] as? String == "claimed")
  #expect((claimed["prompt"] as? String)?.contains("APE-Delivery: \(deliveryID)") == true)
  let secondNext = try transport(
    command(
      "next", place: place,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  #expect(secondNext["status"] as? String == "idle")

  let beforeInvalid = try Data(contentsOf: fixture.queue(place))
  #expect(throws: VerificationError.self) {
    _ = try transportOutput(
      command("sent", place: place, ["--id", deliveryID, "--claim", claim, "--turn", "turn-1"]))
  }
  #expect(try Data(contentsOf: fixture.queue(place)) == beforeInvalid)
  #expect(throws: VerificationError.self) {
    _ = try transportOutput(
      command(
        "begin", place: place, ["--id", deliveryID, "--claim", "wrong", "--baseline", "baseline"]))
  }
  #expect(try Data(contentsOf: fixture.queue(place)) == beforeInvalid)
  let begun = try transport(
    command(
      "begin", place: place, ["--id", deliveryID, "--claim", claim, "--baseline", "baseline"]))
  #expect(begun["status"] as? String == "delivery-unknown")
  let beforeWrongTurn = try Data(contentsOf: fixture.queue(place))
  #expect(throws: VerificationError.self) {
    _ = try transportOutput(
      command("sent", place: place, ["--id", deliveryID, "--claim", claim, "--turn", "baseline"]))
  }
  #expect(try Data(contentsOf: fixture.queue(place)) == beforeWrongTurn)
  let sent = try transport(
    command("sent", place: place, ["--id", deliveryID, "--claim", claim, "--turn", "turn-1"]))
  #expect(sent["status"] as? String == "sent")
  let status = try transport(command("status", place: place, ["--id", deliveryID]))
  #expect(status["id"] as? String == deliveryID)
  #expect(status["requestID"] as? String == request.id)
  #expect(status["host"] as? String == "host")
  #expect(status["targetSession"] as? String == "codexDesktop")
  let reply = fixture.root.appendingPathComponent("reply.txt")
  let actual = "approve\nChecked exact frozen snapshot.\n"
  try Data(actual.utf8).write(to: reply)
  let beforeBadCompletion = try Data(contentsOf: fixture.queue(place))
  #expect(throws: VerificationError.self) {
    _ = try transportOutput(
      command(
        "complete", place: place,
        ["--id", deliveryID, "--claim", "wrong", "--turn", "turn-1", "--reply-file", reply.path]))
  }
  #expect(try Data(contentsOf: fixture.queue(place)) == beforeBadCompletion)

  let beforeWrongCompletionTurn = try Data(contentsOf: fixture.queue(place))
  #expect(throws: VerificationError.self) {
    _ = try transportOutput(
      command(
        "complete", place: place,
        ["--id", deliveryID, "--claim", claim, "--turn", "other-turn", "--reply-file", reply.path]))
  }
  #expect(try Data(contentsOf: fixture.queue(place)) == beforeWrongCompletionTurn)
  let complete = try transport(
    command(
      "complete", place: place,
      ["--id", deliveryID, "--claim", claim, "--turn", "turn-1", "--reply-file", reply.path]))
  #expect(complete["status"] as? String == "reply-complete")
  #expect(complete["response"] as? String == actual)
  #expect(complete["snapshotCurrent"] as? Bool == true)
  #expect((complete["meaning"] as? String)?.contains("no user authority") == true)
  #expect(try SessionHandoff.read(place.ledger).events.filter { $0.event == "decision" }.isEmpty)
}

@Test func transportRejectsMissingDispatcherContinuationsAndSupersededRequestsWithoutQueueMutation()
  throws
{
  let fixture = try TransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let (place, proposal) = try fixture.request()

  #expect(throws: VerificationError.self) {
    _ = try transportOutput(
      command(
        "send", place: place,
        [
          "--id", proposal.id!, "--as", "claude", "--session", "claudeDesktop", "--surface",
          "desktop", "--host", "host", "--timeout", "0",
        ]))
  }
  #expect(!FileManager.default.fileExists(atPath: fixture.queue(place).path))
  _ = try register(place)
  #expect(throws: VerificationError.self) {
    _ = try transportOutput(
      command(
        "next", place: place,
        [
          "--dispatcher", "dispatcher", "--host", "host", "--target-session", "otherCodex",
          "--wait", "0",
        ]))
  }
  _ = try transport(
    command(
      "next", place: place,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  let oldQueue = try Data(contentsOf: fixture.queue(place))
  let replacement = try SessionHandoff.propose(
    place: place, thread: proposal.thread, from: "claude", to: "codex", task: "Replacement",
    brief: "New method.", session: "claudeDesktop", surface: "desktop",
    targetSession: "codexDesktop", targetSurface: "desktop", supersedes: proposal.id)
  #expect(replacement.id != proposal.id)
  #expect(throws: VerificationError.self) {
    _ = try transportOutput(
      command(
        "send", place: place,
        [
          "--id", proposal.id!, "--as", "claude", "--session", "claudeDesktop", "--surface",
          "desktop", "--host", "host", "--timeout", "0",
        ]))
  }
  #expect(try Data(contentsOf: fixture.queue(place)) == oldQueue)

  let continuation = try SessionHandoff.create(
    place: place, from: "claude", to: "codex", task: "Continue", brief: "Writer work.",
    session: "claudeDesktop", targetSession: "codexDesktop", surface: "desktop",
    targetSurface: "desktop")
  #expect(throws: VerificationError.self) {
    _ = try transportOutput(
      command(
        "send", place: place,
        [
          "--id", continuation.id!, "--as", "claude", "--session", "claudeDesktop", "--surface",
          "desktop", "--host", "host", "--timeout", "0",
        ]))
  }
  #expect(try Data(contentsOf: fixture.queue(place)) == oldQueue)
}

@Test func transportRejectsRegistrationBoundToAnotherClaudeSender() throws {
  let fixture = try TransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let (place, proposal) = try fixture.request()
  _ = try register(place, sender: "otherClaude")
  _ = try transport(
    command(
      "next", place: place,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  #expect(throws: VerificationError.self) {
    _ = try transportOutput(
      command(
        "send", place: place,
        [
          "--id", proposal.id!, "--as", "claude", "--session", "claudeDesktop", "--surface",
          "desktop", "--host", "host", "--timeout", "0",
        ]))
  }
}

@Test func transportFailsBeforeDispatchAndRecoversExpiredClaimWithoutResending() throws {
  let fixture = try TransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let (place, request) = try fixture.request()
  _ = try register(place)
  _ = try transport(
    command(
      "next", place: place,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  let queued = try transport(
    command(
      "send", place: place,
      [
        "--id", request.id!, "--as", "claude", "--session", "claudeDesktop", "--surface", "desktop",
        "--host", "host", "--timeout", "0",
      ]))
  let deliveryID = try #require(queued["id"] as? String)
  let claimed = try transport(
    command(
      "next", place: place,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  let claim = try #require(claimed["claimToken"] as? String)
  let failed = try transport(
    command(
      "fail", place: place,
      ["--id", deliveryID, "--claim", claim, "--note", "Native target is busy"]))
  #expect(failed["status"] as? String == "failed")
  let review = try SessionHandoff.create(
    place: place, from: "claude", to: "codex", task: "Read-only review",
    brief: "Review the committed work.",
    thread: request.thread, session: "claudeDesktop", purpose: "review",
    targetSession: "codexDesktop",
    reviewBase: place.head, surface: "desktop", targetSurface: "desktop")
  let reviewQueued = try transport(
    command(
      "send", place: place,
      [
        "--id", review.id!, "--as", "claude", "--session", "claudeDesktop", "--surface", "desktop",
        "--host", "host", "--timeout", "0",
      ]))
  #expect(reviewQueued["status"] as? String == "queued")

  let second = try TransportFixture()
  defer { try? FileManager.default.removeItem(at: second.root) }
  let (secondPlace, secondRequest) = try second.request()
  _ = try register(secondPlace)
  _ = try transport(
    command(
      "next", place: secondPlace,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  let secondQueued = try transport(
    command(
      "send", place: secondPlace,
      [
        "--id", secondRequest.id!, "--as", "claude", "--session", "claudeDesktop", "--surface",
        "desktop", "--host", "host", "--timeout", "0",
      ]))
  let secondID = try #require(secondQueued["id"] as? String)
  let recoveryClaim = try transport(
    command(
      "next", place: secondPlace,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  let recoveryToken = try #require(recoveryClaim["claimToken"] as? String)
  _ = try transport(
    command(
      "begin", place: secondPlace,
      ["--id", secondID, "--claim", recoveryToken, "--baseline", "baseline"]))
  try SessionHandoffTransport.withState(secondPlace) { state in
    let index = try #require(state.deliveries.firstIndex { $0.id == secondID })
    state.deliveries[index].claimExpires = Date.distantPast
  }
  let expiredAfterIntent = try transport(command("status", place: secondPlace, ["--id", secondID]))
  #expect(expiredAfterIntent["status"] as? String == "delivery-unknown")
  let noAutoReclaim = try transport(
    command(
      "next", place: secondPlace,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  #expect(noAutoReclaim["status"] as? String == "idle")
  _ = try register(secondPlace, dispatcher: "wrong-sender", sender: "otherClaude")
  #expect(throws: VerificationError.self) {
    _ = try transport(
      command("recover", place: secondPlace, ["--id", secondID, "--dispatcher", "wrong-sender"]))
  }
  let recovered = try transport(
    command("recover", place: secondPlace, ["--id", secondID, "--dispatcher", "dispatcher"]))
  #expect(recovered["status"] as? String == "delivery-unknown")
  #expect((recovered["note"] as? String)?.contains("never resend") == true)
}

@Test func transportRecordsNoReplyAndNeverAutoReclaimsExpiredDelivery() throws {
  let fixture = try TransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let (place, request) = try fixture.request()
  _ = try register(place)
  _ = try transport(
    command(
      "next", place: place,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  let queued = try transport(
    command(
      "send", place: place,
      [
        "--id", request.id!, "--as", "claude", "--session", "claudeDesktop", "--surface", "desktop",
        "--host", "host", "--timeout", "0",
      ]))
  let id = try #require(queued["id"] as? String)
  let claimed = try transport(
    command(
      "next", place: place,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  let claim = try #require(claimed["claimToken"] as? String)
  _ = try transport(
    command("begin", place: place, ["--id", id, "--claim", claim, "--baseline", "baseline"]))
  _ = try transport(
    command("sent", place: place, ["--id", id, "--claim", claim, "--turn", "turn-1"]))
  let noReply = try transport(
    command(
      "no-reply", place: place,
      [
        "--id", id, "--claim", claim, "--turn", "turn-1", "--note",
        "Native turn finished without a reply",
      ]))
  #expect(noReply["status"] as? String == "no-final-reply")

  let beforeIntent = try TransportFixture()
  defer { try? FileManager.default.removeItem(at: beforeIntent.root) }
  let (beforePlace, beforeRequest) = try beforeIntent.request()
  _ = try register(beforePlace)
  _ = try transport(
    command(
      "next", place: beforePlace,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  let beforeQueued = try transport(
    command(
      "send", place: beforePlace,
      [
        "--id", beforeRequest.id!, "--as", "claude", "--session", "claudeDesktop", "--surface",
        "desktop", "--host", "host", "--timeout", "0",
      ]))
  let beforeID = try #require(beforeQueued["id"] as? String)
  try SessionHandoffTransport.withState(beforePlace) { state in
    let index = try #require(state.deliveries.firstIndex { $0.id == beforeID })
    state.deliveries[index].expires = Date.distantPast
  }
  _ = try transport(
    command(
      "next", place: beforePlace,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  let abandoned = try transport(command("status", place: beforePlace, ["--id", beforeID]))
  #expect(abandoned["status"] as? String == "abandoned-unsent")
  let next = try transport(
    command(
      "next", place: beforePlace,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  #expect(next["status"] as? String == "idle")
}

@Test func transportRechecksAuthorizationAtIntentAndLinksExactReceiptBytes() throws {
  let fixture = try TransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let (place, proposal) = try fixture.request()
  _ = try register(place)
  let queued = try transport(
    command(
      "send", place: place,
      [
        "--id", proposal.id!, "--as", "claude", "--session", "claudeDesktop", "--surface",
        "desktop", "--host", "host", "--timeout", "0",
      ]))
  let id = try #require(queued["id"] as? String)
  let claimed = try transport(
    command(
      "next", place: place,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  let token = try #require(claimed["claimToken"] as? String)
  try SessionHandoffTransport.withState(place) { state in
    #expect(state.dispatchers[0].remaining == 10)
    state.dispatchers[0].expires = Date.distantPast
  }
  let denied = try Data(contentsOf: fixture.queue(place))
  #expect(throws: VerificationError.self) {
    _ = try transport(
      command("begin", place: place, ["--id", id, "--claim", token, "--baseline", "baseline"]))
  }
  #expect(try Data(contentsOf: fixture.queue(place)) == denied)
  try SessionHandoffTransport.withState(place) {
    $0.dispatchers[0].expires = Date().addingTimeInterval(60)
  }
  _ = try transport(
    command("begin", place: place, ["--id", id, "--claim", token, "--baseline", "baseline"]))
  try SessionHandoffTransport.withState(place) { #expect($0.dispatchers[0].remaining == 9) }
  _ = try transport(
    command("sent", place: place, ["--id", id, "--claim", token, "--turn", "new-turn"]))
  let reply = "approve: e\u{301}\n".replacingOccurrences(of: "\\u{301}", with: "\u{301}")
  let replyFile = fixture.root.appendingPathComponent("actual.txt")
  try reply.write(to: replyFile, atomically: true, encoding: .utf8)
  _ = try transport(
    command(
      "complete", place: place,
      ["--id", id, "--claim", token, "--turn", "new-turn", "--reply-file", replyFile.path]))
  let ledger = try Data(contentsOf: place.ledger)
  #expect(throws: VerificationError.self) {
    _ = try SessionHandoff.respond(
      place: place, id: proposal.id!, as: "codex", session: "codexDesktop", surface: "desktop",
      recordedBy: "claude", decision: "approve", brief: "modified reply", deliveryID: id)
  }
  #expect(try Data(contentsOf: place.ledger) == ledger)
  let decision = try SessionHandoff.respond(
    place: place, id: proposal.id!, as: "codex", session: "codexDesktop", surface: "desktop",
    recordedBy: "claude", decision: "approve", brief: reply, deliveryID: id)
  #expect(decision.deliveryID == id && Data(decision.brief!.utf8) == Data(reply.utf8))
}

@Test func transportExpiredClaimWithoutIntentIsFinalAndUncertainCanBeResolved() throws {
  let fixture = try TransportFixture()
  defer { try? FileManager.default.removeItem(at: fixture.root) }
  let (place, proposal) = try fixture.request()
  _ = try register(place)
  let sendArgs = command(
    "send", place: place,
    [
      "--id", proposal.id!, "--as", "claude", "--session", "claudeDesktop", "--surface", "desktop",
      "--host", "host", "--timeout", "0",
    ])
  let queued = try transport(sendArgs)
  let id = try #require(queued["id"] as? String)
  let claimed = try transport(
    command(
      "next", place: place,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  let oldToken = try #require(claimed["claimToken"] as? String)
  try SessionHandoffTransport.withState(place) { $0.deliveries[0].claimExpires = Date.distantPast }
  let status = try transport(command("status", place: place, ["--id", id]))
  #expect(status["status"] as? String == "abandoned-unsent")
  #expect((try transport(sendArgs))["status"] as? String == "abandoned-unsent")
  #expect(throws: VerificationError.self) {
    _ = try transport(command("recover", place: place, ["--id", id, "--dispatcher", "dispatcher"]))
  }
  #expect(throws: VerificationError.self) {
    _ = try transport(
      command(
        "sent", place: place, ["--id", id, "--claim", oldToken, "--turn", "later-unrelated-turn"]))
  }
  let review = try SessionHandoff.create(
    place: place, from: "claude", to: "codex", task: "Next review", brief: "Same goal",
    thread: proposal.thread, session: "claudeDesktop", purpose: "review",
    targetSession: "codexDesktop", reviewBase: place.head, surface: "desktop",
    targetSurface: "desktop")
  let nextSend = command(
    "send", place: place,
    [
      "--id", review.id!, "--as", "claude", "--session", "claudeDesktop", "--surface", "desktop",
      "--host", "host", "--timeout", "0",
    ])
  let nextQueued = try transport(nextSend)
  let nextID = try #require(nextQueued["id"] as? String)
  let nextClaim = try transport(
    command(
      "next", place: place,
      [
        "--dispatcher", "dispatcher", "--host", "host", "--target-session", "codexDesktop",
        "--wait", "0",
      ]))
  let token = try #require(nextClaim["claimToken"] as? String)
  _ = try transport(
    command("begin", place: place, ["--id", nextID, "--claim", token, "--baseline", "baseline"]))
  let resolved = try transport(
    command(
      "resolve", place: place,
      [
        "--id", nextID, "--dispatcher", "dispatcher", "--note",
        "Native marker absent; explicitly close as unresolved, never retry",
      ]))
  #expect(resolved["status"] as? String == "unresolved")
  #expect(resolved["resolvedBy"] as? String == "dispatcher")
  #expect((try transport(nextSend))["status"] as? String == "unresolved")
  #expect(throws: VerificationError.self) {
    _ = try transport(
      command("sent", place: place, ["--id", nextID, "--claim", token, "--turn", "late-turn"]))
  }
}
