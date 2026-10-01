import Foundation

/// A session's recorded events folded into agent lanes and steps.
///
/// Folding is order-independent for events that carry an identity: a tool step merges its
/// Pre and Post by `tool_use_id` hash and status takes the most severe observation. A repeated
/// delivery is dropped, so repeated or reordered hook deliveries give the same graph, while
/// separate compactions or Stops in one turn stay separate.
struct FlowGraph {
  struct Step {
    var key: String
    var lane: String
    var kind: String
    var name: String
    var label: String?
    var status: String
    var detail: String?
    var errorClass: String?
    var spawns: String?
    var durationMs: Int?
    var turn: String?
    var at: Date
    var order: Int
  }

  struct Lane {
    var id: String
    var type: String?
    var typeLabel: String?
    var started = false
    var stopped = false
    var at: Date
    var order: Int
  }

  var session = ""
  var clients: [String] = []
  var lanes: [String: Lane] = [:]
  var steps: [Step] = []
  var skippedLines = 0

  static let rootLane = ""

  static func statusRank(_ status: String) -> Int {
    ["started": 0, "completed": 1, "interrupted": 2, "failed": 3][status] ?? 0
  }

  init(lines: [String]) {
    let decoder = JSONDecoder()
    var entries: [(event: FlowEvent, at: Date, index: Int)] = []
    for (index, line) in lines.enumerated()
    where !line.trimmingCharacters(in: .whitespaces).isEmpty {
      guard let event = try? decoder.decode(FlowEvent.self, from: Data(line.utf8)),
        event.schemaVersion == FlowEvent.schemaVersion
      else {
        skippedLines += 1
        continue
      }
      entries.append((event, FlowTime.parse(event.at) ?? .distantPast, index))
    }
    entries.sort { ($0.at, $0.index) < ($1.at, $1.index) }
    session = entries.first?.event.session ?? ""
    clients = Set(entries.map(\.event.source.client)).sorted()

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    var seen = Set<Data>()
    var stepIndex: [String: Int] = [:]
    var openCompactions: [String: [Int]] = [:]
    var interruptedTurns = Set<String>()
    for entry in entries {
      // A tool or subagent event has a unique identity; any other event is a duplicate
      // delivery only when its recorded line repeats exactly, timestamp included.
      var key = entry.event
      if entry.event.step.id != nil || entry.event.step.kind == "subagent" { key.at = "" }
      guard seen.insert((try? encoder.encode(key)) ?? Data()).inserted else { continue }
      fold(entry.event, at: entry.at, index: entry.index, &stepIndex, &openCompactions)
      if entry.event.step.name == "Interrupt", let turn = entry.event.turn {
        interruptedTurns.insert(turn)
      }
    }
    for index in steps.indices where steps[index].status == "started" {
      let interrupted = steps[index].turn.map { interruptedTurns.contains($0) } ?? false
      steps[index].status = interrupted ? "interrupted" : "incomplete"
    }
    if lanes[Self.rootLane] == nil {
      lanes[Self.rootLane] = Lane(id: Self.rootLane, at: .distantPast, order: -1)
    }
    // A spawned agent with no recorded events still appears under the step that spawned it.
    for step in steps.sorted(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
      if let child = step.spawns, lanes[child] == nil {
        lanes[child] = Lane(id: child, at: step.at, order: step.order)
      }
    }
  }

  private mutating func fold(
    _ event: FlowEvent, at: Date, index: Int, _ stepIndex: inout [String: Int],
    _ openCompactions: inout [String: [Int]]
  ) {
    let laneID = event.agent?.id ?? Self.rootLane
    if lanes[laneID] == nil { lanes[laneID] = Lane(id: laneID, at: at, order: index) }
    if lanes[laneID]?.type == nil, let type = event.agent?.type {
      lanes[laneID]?.type = type
      lanes[laneID]?.typeLabel = event.agent?.typeLabel
    }
    let step = event.step
    var record = Step(
      key: "line-\(index)", lane: laneID, kind: step.kind, name: step.name, label: step.label,
      status: step.status, detail: step.detail, errorClass: step.errorClass, spawns: step.spawns,
      durationMs: event.durationMs, turn: event.turn, at: at, order: index)
    switch step.kind {
    case "tool":
      let key = step.id.map { "tool-" + $0 } ?? record.key
      guard let existing = stepIndex[key] else {
        record.key = key
        stepIndex[key] = steps.count
        steps.append(record)
        return
      }
      var merged = steps[existing]
      if Self.statusRank(step.status) > Self.statusRank(merged.status) {
        merged.status = step.status
        merged.errorClass = step.errorClass ?? merged.errorClass
      }
      merged.spawns = merged.spawns ?? step.spawns
      merged.label = merged.label ?? step.label
      merged.turn = merged.turn ?? event.turn
      if let duration = event.durationMs {
        merged.durationMs = max(merged.durationMs ?? 0, duration)
      }
      if (at, index) < (merged.at, merged.order) {
        merged.at = at
        merged.order = index
      }
      steps[existing] = merged
    case "subagent":
      if step.name == "SubagentStart" {
        lanes[laneID]?.started = true
      } else {
        lanes[laneID]?.stopped = true
      }
    case "compaction":
      if step.status == "started" {
        openCompactions[laneID, default: []].append(steps.count)
        steps.append(record)
      } else if let open = openCompactions[laneID]?.popLast() {
        steps[open].status = "completed"
        steps[open].detail = steps[open].detail ?? step.detail
      } else {
        steps.append(record)
      }
    default:
      steps.append(record)
    }
  }

  /// Steps of one lane in time order.
  func steps(in lane: String) -> [Step] {
    steps.filter { $0.lane == lane }.sorted { ($0.at, $0.order) < ($1.at, $1.order) }
  }

  /// The step that spawned each linked agent: the earliest one naming it.
  func spawnOwners() -> [String: String] {
    var owners: [String: String] = [:]
    for step in steps.sorted(by: { ($0.at, $0.order) < ($1.at, $1.order) }) {
      if let child = step.spawns, child != step.lane, owners[child] == nil {
        owners[child] = step.key
      }
    }
    return owners
  }
}
