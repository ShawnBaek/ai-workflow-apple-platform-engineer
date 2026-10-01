import Foundation

public enum FlowRenderFormat: String, Sendable {
  case mermaid, tree
}

public struct FlowRenderOptions: Sendable {
  public var format: FlowRenderFormat
  public var maxSteps: Int
  public var includeLabels: Bool

  public init(format: FlowRenderFormat, maxSteps: Int = 500, includeLabels: Bool = false) {
    self.format = format
    self.maxSteps = maxSteps
    self.includeLabels = includeLabels
  }
}

/// Renders a recorded session, and optionally a read-only harness ledger lane, as a Mermaid
/// flowchart or a compact text tree.
public enum FlowRenderer {
  struct Node {
    var id: String
    var text: String
    var status: String?
    var children: [LanePlan] = []
  }

  struct LanePlan {
    var id: String
    var title: String
    var nodes: [Node]
  }

  struct Plan {
    var header: String
    var root: LanePlan
    var unlinked: [LanePlan]
    var harness: LanePlan?
    var elidedSteps = 0
    var elidedNodes = 0
    var elidedRecords = 0
  }

  public static func render(
    eventLines: [String], ledgerLines: [String]? = nil, options: FlowRenderOptions
  ) -> String {
    let plan = makePlan(
      graph: FlowGraph(lines: eventLines), ledger: ledgerLines.map(FlowLedger.entries),
      options: options)
    switch options.format {
    case .tree: return tree(plan, options: options)
    case .mermaid: return mermaid(plan, options: options)
    }
  }

  // MARK: - Planning

  private struct Group {
    var steps: [FlowGraph.Step]
  }

  static func makePlan(graph: FlowGraph, ledger: [FlowLedger.Entry]?, options: FlowRenderOptions)
    -> Plan
  {
    let owners = graph.spawnOwners()
    var remaining = max(options.maxSteps, 1)
    var elidedSteps = 0
    var elidedNodes = 0
    var visited = Set<String>()

    func laneID(_ lane: String) -> String { lane.isEmpty ? "root" : "a_" + lane }

    func laneTitle(_ lane: String) -> String {
      let record = graph.lanes[lane]
      let type = record.flatMap { typeText($0, options: options) }
      if lane.isEmpty { return ["root", type].compactMap { $0 }.joined(separator: " · ") }
      var title = (type ?? "agent") + " " + short(lane)
      if record?.stopped == true {
        title += " · completed"
      } else if record?.started == true {
        title += " · incomplete"
      }
      return title
    }

    func groups(_ lane: String) -> [Group] {
      var result: [Group] = []
      for step in graph.steps(in: lane) {
        if var last = result.last, let previous = last.steps.last, previous.kind == "tool",
          step.kind == "tool", previous.name == step.name, previous.label == step.label,
          previous.spawns == nil, step.spawns == nil
        {
          last.steps.append(step)
          result[result.count - 1] = last
        } else {
          result.append(Group(steps: [step]))
        }
      }
      return result
    }

    func planLane(_ lane: String) -> LanePlan {
      visited.insert(lane)
      let id = laneID(lane)
      var nodes: [Node] = []
      var elidedHere = 0
      var elidedNodesHere = 0
      var pendingChildren: [String] = []
      for (index, group) in groups(lane).enumerated() {
        let children = group.steps.compactMap { step -> String? in
          guard let child = step.spawns, owners[child] == step.key, !visited.contains(child)
          else { return nil }
          return child
        }
        if remaining > 0 {
          remaining -= 1
          var node = Node(
            id: "\(id)_\(index)", text: groupText(group, graph: graph, options: options),
            status: groupStatus(group))
          for child in children where !visited.contains(child) {
            node.children.append(planLane(child))
          }
          nodes.append(node)
        } else {
          elidedHere += group.steps.count
          elidedNodesHere += 1
          elidedSteps += group.steps.count
          elidedNodes += 1
          pendingChildren += children
        }
      }
      if elidedHere > 0 {
        var node = Node(
          id: "\(id)_more", text: "… " + elisionCount(nodes: elidedNodesHere, steps: elidedHere),
          status: "elided")
        for child in pendingChildren where !visited.contains(child) {
          node.children.append(planLane(child))
        }
        nodes.append(node)
      }
      return LanePlan(id: id, title: laneTitle(lane), nodes: nodes)
    }

    let root = planLane(FlowGraph.rootLane)
    var unlinked: [LanePlan] = []
    let orphans = graph.lanes.values.filter { !visited.contains($0.id) }
      .sorted { ($0.at, $0.order) < ($1.at, $1.order) }
    for lane in orphans where !visited.contains(lane.id) {
      unlinked.append(planLane(lane.id))
    }
    // The harness lane has its own budget, so ledger records never displace session steps.
    var harness: LanePlan?
    var elidedRecords = 0
    if let ledger {
      var nodes: [Node] = []
      var elidedHere = 0
      for (index, entry) in ledger.enumerated() {
        if index < max(options.maxSteps, 1) {
          nodes.append(
            Node(id: "harness_\(index)", text: entry.text, status: entry.failed ? "failed" : nil))
        } else {
          elidedHere += 1
        }
      }
      elidedRecords = elidedHere
      if elidedHere > 0 {
        nodes.append(
          Node(
            id: "harness_more",
            text: "… \(elidedHere) more record\(elidedHere == 1 ? "" : "s") elided",
            status: "elided"))
      }
      harness = LanePlan(id: "harness", title: "harness", nodes: nodes)
    }
    let agents = graph.lanes.count - 1
    let header = [
      "flow \(short(graph.session))", graph.clients.joined(separator: "+"),
      "\(graph.steps.count) step" + (graph.steps.count == 1 ? "" : "s"),
      "\(agents) agent" + (agents == 1 ? "" : "s"),
    ].filter { !$0.isEmpty }.joined(separator: " · ")
    return Plan(
      header: header, root: root, unlinked: unlinked, harness: harness, elidedSteps: elidedSteps,
      elidedNodes: elidedNodes, elidedRecords: elidedRecords)
  }

  static func short(_ hash: String) -> String { String(hash.prefix(8)) }

  static func typeText(_ lane: FlowGraph.Lane, options: FlowRenderOptions) -> String? {
    guard let type = lane.type else { return nil }
    guard type.hasPrefix("custom:") else { return type }
    if options.includeLabels, let label = lane.typeLabel { return FlowNormalizer.label(label) }
    return "custom:" + short(String(type.dropFirst(7)))
  }

  static func stepName(_ step: FlowGraph.Step, options: FlowRenderOptions) -> String {
    if step.name.hasPrefix("mcp:"), let slash = step.name.firstIndex(of: "/") {
      let server = step.name[step.name.index(step.name.startIndex, offsetBy: 4)..<slash]
      let tool = step.name[step.name.index(after: slash)...]
      let shown =
        options.includeLabels
        ? step.label.map(FlowNormalizer.label) ?? short(String(server)) : short(String(server))
      return "mcp:\(shown)/\(tool)"
    }
    if step.name.hasPrefix("tool:") {
      if options.includeLabels, let label = step.label { return FlowNormalizer.label(label) }
      return "tool:" + short(String(step.name.dropFirst(5)))
    }
    return step.name
  }

  private static func groupText(_ group: Group, graph: FlowGraph, options: FlowRenderOptions)
    -> String
  {
    let first = group.steps[0]
    var text = stepName(first, options: options)
    if let detail = first.detail { text += " (\(detail))" }
    if group.steps.count > 1 {
      text += " ×\(group.steps.count)"
      let counts = ["failed", "interrupted", "incomplete"].compactMap { status -> String? in
        let count = group.steps.filter { $0.status == status }.count
        return count > 0 ? "\(count) \(status)" : nil
      }
      if !counts.isEmpty { text += " (" + counts.joined(separator: ", ") + ")" }
    } else if first.status != "completed" {
      text += " (" + first.status + (first.errorClass.map { ": " + $0 } ?? "") + ")"
    }
    if let child = first.spawns, let lane = graph.lanes[child] {
      text += " → " + (typeText(lane, options: options) ?? "agent") + " " + short(child)
    }
    let durations = group.steps.compactMap(\.durationMs)
    if !durations.isEmpty {
      let total = durations.reduce(0, +)
      text +=
        total < 1_000 ? " · \(total) ms" : " · " + String(format: "%.1f s", Double(total) / 1_000)
    }
    return text
  }

  private static func groupStatus(_ group: Group) -> String? {
    let statuses = Set(group.steps.map(\.status))
    return ["failed", "interrupted", "incomplete"].first { statuses.contains($0) }
  }

  /// `--max-steps` counts step nodes, where a collapsed run is one node, so a note names both
  /// the nodes and the steps they held.
  static func elisionCount(nodes: Int, steps: Int) -> String {
    "\(nodes) more node\(nodes == 1 ? "" : "s") (\(steps) step\(steps == 1 ? "" : "s")) elided"
  }

  static func elisionNotes(_ plan: Plan, options: FlowRenderOptions) -> [String] {
    var notes: [String] = []
    if plan.elidedNodes > 0 {
      notes.append(
        "--max-steps \(options.maxSteps) counts step nodes, "
          + elisionCount(nodes: plan.elidedNodes, steps: plan.elidedSteps))
    }
    if plan.elidedRecords > 0 {
      notes.append(
        "--max-steps \(options.maxSteps) counts harness records separately, "
          + "\(plan.elidedRecords) more record\(plan.elidedRecords == 1 ? "" : "s") elided")
    }
    return notes
  }

  // MARK: - Tree

  static func tree(_ plan: Plan, options: FlowRenderOptions) -> String {
    var lines = [plan.header]
    func emit(_ nodes: [Node], prefix: String) {
      for (index, node) in nodes.enumerated() {
        let last = index == nodes.count - 1
        lines.append(prefix + (last ? "└─ " : "├─ ") + node.text)
        let childPrefix = prefix + (last ? "   " : "│  ")
        for (childIndex, child) in node.children.enumerated() {
          let lastChild = childIndex == node.children.count - 1
          lines.append(childPrefix + (lastChild ? "└─ " : "├─ ") + child.title)
          emit(child.nodes, prefix: childPrefix + (lastChild ? "   " : "│  "))
        }
      }
    }
    lines.append(plan.root.title)
    emit(plan.root.nodes, prefix: "")
    if !plan.unlinked.isEmpty {
      lines.append("unlinked")
      for (index, lane) in plan.unlinked.enumerated() {
        let last = index == plan.unlinked.count - 1
        lines.append((last ? "└─ " : "├─ ") + lane.title)
        emit(lane.nodes, prefix: last ? "   " : "│  ")
      }
    }
    if let harness = plan.harness {
      lines.append(harness.title)
      emit(harness.nodes, prefix: "")
    }
    for note in elisionNotes(plan, options: options) { lines.append("note: " + note) }
    return lines.joined(separator: "\n") + "\n"
  }

  // MARK: - Mermaid

  /// Keeps a conservative set of characters and writes everything else as a Mermaid numeric
  /// entity, so a label cannot close its quotes, start a directive or inject markup.
  public static func escapeMermaid(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
      if (scalar.isASCII && CharacterSet.alphanumerics.contains(scalar))
        || " _.,:/()+-×·→…".unicodeScalars.contains(scalar)
      {
        result.unicodeScalars.append(scalar)
      } else {
        result += "#\(scalar.value);"
      }
    }
    return result
  }

  static func mermaid(_ plan: Plan, options: FlowRenderOptions) -> String {
    var lines = ["flowchart TD", "  %% " + escapeMermaid(plan.header)]
    var edges: [String] = []
    var classes: [String: [String]] = [:]
    func emitLane(_ lane: LanePlan, indent: String) {
      lines.append("\(indent)subgraph \(lane.id)[\"\(escapeMermaid(lane.title))\"]")
      lines.append("\(indent)  direction TB")
      if lane.nodes.isEmpty {
        lines.append("\(indent)  \(lane.id)_empty[\"no recorded steps\"]")
      }
      for node in lane.nodes {
        lines.append("\(indent)  \(node.id)[\"\(escapeMermaid(node.text))\"]")
        if let status = node.status { classes[status, default: []].append(node.id) }
      }
      for (previous, next) in zip(lane.nodes, lane.nodes.dropFirst()) {
        lines.append("\(indent)  \(previous.id) --> \(next.id)")
      }
      lines.append("\(indent)end")
      for node in lane.nodes {
        for child in node.children {
          edges.append("  \(node.id) -.-> \(child.id)")
          emitLane(child, indent: indent)
        }
      }
    }
    emitLane(plan.root, indent: "  ")
    if !plan.unlinked.isEmpty {
      lines.append("  subgraph unlinked[\"unlinked\"]")
      lines.append("    direction TB")
      for lane in plan.unlinked { emitLane(lane, indent: "    ") }
      lines.append("  end")
    }
    if let harness = plan.harness { emitLane(harness, indent: "  ") }
    lines += edges
    let styles = [
      "failed": "fill:#fde2e1,stroke:#c0392b",
      "interrupted": "fill:#fff4d6,stroke:#b9770e",
      "incomplete": "stroke-dasharray:4 3",
      "elided": "fill:none,stroke-dasharray:2 2",
    ]
    for status in ["failed", "interrupted", "incomplete", "elided"] {
      guard let ids = classes[status] else { continue }
      lines.append("  classDef \(status) \(styles[status]!)")
      lines.append("  class \(ids.joined(separator: ",")) \(status)")
    }
    for note in elisionNotes(plan, options: options) {
      lines.append("  %% " + escapeMermaid(note))
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

/// A read-only view of an agent-harness run ledger, reduced to allowlisted enum fields.
enum FlowLedger {
  struct Entry {
    var at: Date
    var sequence: Int
    var index: Int
    var text: String
    var failed: Bool
  }

  /// The payload fields shown for each record type; free text such as summaries, paths and
  /// operation inputs is never shown.
  static let fields: [String: [String]] = [
    "node": ["node_id", "status"], "attempt": ["phase", "outcome"], "time_interval": ["kind"],
    "lease": ["action", "resource"], "approval": ["kind", "decision"],
    "grant_reservation": ["phase"], "grant_dispatch": [], "knowledge": ["authority"],
    "evidence": ["evidence_kind", "outcome"], "external_write": ["action", "outcome"],
    "feedback": ["disposition"], "improvement": ["status"], "stop": ["outcome"],
  ]
  static let failures: Set<String> = [
    "failed", "failed_retryable", "failed_terminal", "blocked", "denied", "rejected",
  ]

  static func entries(_ lines: [String]) -> [Entry] {
    var entries: [Entry] = []
    for (index, line) in lines.enumerated() {
      guard
        let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
        let type = object["record_type"] as? String, let shown = fields[type]
      else { continue }
      let payload = object["payload"] as? [String: Any] ?? [:]
      let values = shown.compactMap { key -> String? in
        guard let value = payload[key] as? String, FlowNormalizer.isSafeToken(value) else {
          return nil
        }
        return value
      }
      entries.append(
        Entry(
          at: (object["recorded_at"] as? String).flatMap(FlowTime.parse) ?? .distantPast,
          sequence: object["sequence"] as? Int ?? 0, index: index,
          text: ([type.replacingOccurrences(of: "_", with: " ")] + values).joined(separator: " · "),
          failed: values.contains { failures.contains($0) }))
    }
    return entries.sorted { ($0.at, $0.sequence, $0.index) < ($1.at, $1.sequence, $1.index) }
  }
}
