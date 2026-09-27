import Darwin
import Foundation

public protocol HealthProbeRunning {
  func run(
    executable: String, arguments: [String], directory: URL?, environment: [String: String]?,
    timeout: TimeInterval, maxOutputBytes: Int
  ) -> ProcessResult
}

public struct HealthMCPProbeResult {
  public let passed: Bool
  public let material: [String: Any]
  public init(passed: Bool, material: [String: Any]) {
    self.passed = passed
    self.material = material
  }
}

/// The transport is injectable so tests never need a live MCP server. The system
/// implementation performs only initialize, notifications/initialized, tools/list,
/// and AppleSampleCode get_status. `probeXcode` starts its own `xcrun mcpbridge`, which Xcode
/// reports as one more external agent, so the evaluator calls it only on explicit opt-in.
public protocol HealthMCPProbing {
  func probeXcode(timeout: TimeInterval) -> HealthMCPProbeResult
  func probeAppleSampleCode(endpoint: URL, timeout: TimeInterval) -> HealthMCPProbeResult
}

enum HealthMCPResponseValidation {
  static func hasResponseID(_ value: [String: Any], _ expected: Int) -> Bool {
    guard let number = value["id"] as? NSNumber, !HarnessRuntime.isBoolean(number) else {
      return false
    }
    return number.stringValue == String(expected)
  }
  static func hasUsableToolResult(_ value: [String: Any]) -> Bool {
    guard value["error"] == nil, let result = value["result"] as? [String: Any],
      result["isError"] as? Bool != true
    else { return false }
    if let structured = result["structuredContent"] as? [String: Any], !structured.isEmpty {
      return true
    }
    guard let content = result["content"] as? [[String: Any]], !content.isEmpty else {
      return false
    }
    return content.contains { item in
      if let text = item["text"] as? String {
        return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }
      return item["data"] != nil || item["resource"] != nil
    }
  }
}

/// The coordinator must execute the inventory while its CoreSimulator registry lease is live.
/// A health evaluator never falls back to an uncoordinated runtime inventory.
public protocol RuntimeRegistryCoordinating {
  func withRuntimeRegistryAdmission<T>(scope: RuntimeProbeScope, body: ([String: Any]) throws -> T)
    throws -> T
}

public struct SystemHealthRunner: HealthProbeRunning {
  public init() {}
  public func run(
    executable: String, arguments: [String], directory: URL?, environment: [String: String]?,
    timeout: TimeInterval, maxOutputBytes: Int
  ) -> ProcessResult {
    (try? HarnessRuntime.run(
      executable: executable, arguments: arguments, directory: directory, environment: environment,
      timeout: timeout, maxOutputBytes: maxOutputBytes))
      ?? ProcessResult(
        stdout: "", stderr: "probe invocation failed", exitCode: 127, timedOut: false,
        truncated: false)
  }
}

public struct SystemHealthMCPProbe: HealthMCPProbing {
  public init() {}

  public func probeXcode(timeout: TimeInterval) -> HealthMCPProbeResult {
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["mcpbridge"]
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    do {
      try process.run()
      let messages: [[String: Any]] = [
        [
          "jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": [
            "protocolVersion": "2025-06-18", "capabilities": [String: Any](),
            "clientInfo": ["name": "ios-experts-health", "version": "1.0.0"],
          ],
        ],
        ["jsonrpc": "2.0", "method": "notifications/initialized"],
        ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [String: Any]()],
      ]
      var request = Data()
      for message in messages {
        request.append(try HarnessRuntime.canonicalJSON(message))
        request.append(10)
      }
      try input.fileHandleForWriting.write(contentsOf: request)
      let descriptor = output.fileHandleForReading.fileDescriptor
      _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
      let deadline = Date().addingTimeInterval(timeout)
      var pending = Data()
      var responses: [[String: Any]] = []
      while responses.count < 2, Date() < deadline, process.isRunning {
        var bytes = [UInt8](repeating: 0, count: 16_384)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count > 0 {
          pending.append(contentsOf: bytes.prefix(count))
          guard pending.count <= 1_048_576 else { throw MCPFailure.response }
          while let newline = pending.firstIndex(of: 10) {
            let line = pending[..<newline]
            pending.removeSubrange(...newline)
            if let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
              value["id"] != nil
            {
              responses.append(value)
            }
          }
        } else if count < 0, errno != EAGAIN, errno != EWOULDBLOCK, errno != EINTR {
          throw MCPFailure.io
        }
        if responses.count < 2 { usleep(10_000) }
      }
      guard responses.count == 2 else { throw MCPFailure.timeout }
      let initialized = responses[0]
      let listed = responses[1]
      guard HealthMCPResponseValidation.hasResponseID(initialized, 1),
        HealthMCPResponseValidation.hasResponseID(listed, 2), initialized["error"] == nil,
        listed["error"] == nil,
        let tools = (listed["result"] as? [String: Any])?["tools"] as? [[String: Any]],
        !tools.isEmpty
      else { throw MCPFailure.response }
      stop(process)
      return .init(
        passed: true,
        material: [
          "server": (initialized["result"] as? [String: Any])?["serverInfo"] ?? NSNull(),
          "tool_count": tools.count,
        ])
    } catch {
      stop(process)
      return .init(passed: false, material: ["error_class": errorClass(error)])
    }
  }

  public func probeAppleSampleCode(endpoint: URL, timeout: TimeInterval) -> HealthMCPProbeResult {
    do {
      let initialized = try post(
        endpoint: endpoint,
        payload: [
          "jsonrpc": "2.0", "id": 1, "method": "initialize",
          "params": [
            "protocolVersion": "2025-06-18", "capabilities": [String: Any](),
            "clientInfo": ["name": "ios-experts-health", "version": "1.0.0"],
          ],
        ], sessionID: nil, timeout: timeout)
      guard HealthMCPResponseValidation.hasResponseID(initialized.value, 1),
        initialized.value["error"] == nil, initialized.value["result"] != nil
      else { throw MCPFailure.response }
      _ = try post(
        endpoint: endpoint, payload: ["jsonrpc": "2.0", "method": "notifications/initialized"],
        sessionID: initialized.sessionID, timeout: timeout)
      let listed = try post(
        endpoint: endpoint,
        payload: ["jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [String: Any]()],
        sessionID: initialized.sessionID, timeout: timeout)
      let names = Set(
        ((listed.value["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []).compactMap
        { $0["name"] as? String })
      let required = Set(["search_samples", "get_sample", "compare_samples", "get_status"])
      guard HealthMCPResponseValidation.hasResponseID(listed.value, 2),
        listed.value["error"] == nil, required.isSubset(of: names)
      else { throw MCPFailure.response }
      let status = try post(
        endpoint: endpoint,
        payload: [
          "jsonrpc": "2.0", "id": 3, "method": "tools/call",
          "params": ["name": "get_status", "arguments": ["refresh": false]],
        ], sessionID: listed.sessionID, timeout: timeout)
      guard HealthMCPResponseValidation.hasResponseID(status.value, 3),
        HealthMCPResponseValidation.hasUsableToolResult(status.value)
      else { throw MCPFailure.response }
      return .init(
        passed: true,
        material: [
          "endpoint": endpoint.absoluteString,
          "server": (initialized.value["result"] as? [String: Any])?["serverInfo"] ?? NSNull(),
          "tools": required.sorted(), "status": status.value["result"] ?? NSNull(),
        ])
    } catch { return .init(passed: false, material: ["error_class": errorClass(error)]) }
  }

  private enum MCPFailure: Error { case timeout, io, response }
  private final class HTTPDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0), limit: Int
    let lock = NSLock()
    var data = Data()
    var response: HTTPURLResponse?
    var error: Error?
    init(limit: Int) { self.limit = limit }
    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
      completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
      lock.lock()
      self.response = response as? HTTPURLResponse
      lock.unlock()
      completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive bytes: Data) {
      lock.lock()
      if data.count + bytes.count > limit {
        error = MCPFailure.response
        lock.unlock()
        dataTask.cancel()
        return
      }
      data.append(bytes)
      lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
      lock.lock()
      if self.error == nil { self.error = error }
      lock.unlock()
      semaphore.signal()
    }
  }
  private func post(
    endpoint: URL, payload: [String: Any], sessionID: String?, timeout: TimeInterval
  ) throws -> (value: [String: Any], sessionID: String?) {
    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.timeoutInterval = timeout
    request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("2025-06-18", forHTTPHeaderField: "MCP-Protocol-Version")
    if let sessionID { request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id") }
    request.httpBody = try HarnessRuntime.canonicalJSON(payload)
    let delegate = HTTPDelegate(limit: 2_000_000)
    let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
    let task = session.dataTask(with: request)
    task.resume()
    guard delegate.semaphore.wait(timeout: .now() + timeout + 1) == .success else {
      task.cancel()
      session.invalidateAndCancel()
      throw MCPFailure.timeout
    }
    session.finishTasksAndInvalidate()
    guard delegate.error == nil, let response = delegate.response,
      (200..<300).contains(response.statusCode), delegate.data.count <= 2_000_000,
      !task.progress.isCancelled,
      let body = String(data: delegate.data, encoding: .utf8), let value = extractJSONRPC(body)
    else { throw MCPFailure.response }
    return (value, response.value(forHTTPHeaderField: "Mcp-Session-Id") ?? sessionID)
  }
  private func extractJSONRPC(_ body: String) -> [String: Any]? {
    let stripped = body.trimmingCharacters(in: .whitespacesAndNewlines)
    if stripped.isEmpty { return [:] }
    let lines = stripped.split(whereSeparator: \.isNewline).compactMap { raw -> String? in
      var value = raw.trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("data:") {
        value = String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces)
      }
      return value.hasPrefix("{") ? value : nil
    }
    for candidate in (lines.isEmpty ? [stripped] : lines).reversed() {
      if let value = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) as? [String: Any]
      {
        return value
      }
    }
    return nil
  }
  private func stop(_ process: Process) {
    if process.isRunning {
      process.terminate()
      let deadline = Date().addingTimeInterval(2)
      while process.isRunning, Date() < deadline { usleep(10_000) }
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      process.waitUntilExit()
    }
  }
  private func errorClass(_ error: Error) -> String {
    guard let failure = error as? MCPFailure else { return String(describing: type(of: error)) }
    switch failure {
    case .timeout: return "timeout"
    case .io: return "io_error"
    case .response: return "invalid_response"
    }
  }
}

public struct ResourceCoordinatorRuntimeAdmission: RuntimeRegistryCoordinating {
  public init() {}
  public func withRuntimeRegistryAdmission<T>(
    scope: RuntimeProbeScope, body: ([String: Any]) throws -> T
  ) throws -> T {
    try ResourceCoordinator.withRuntimeRegistryAdmission(
      statePath: scope.statePath, descriptor: scope.descriptor, ownerRunID: scope.ownerRunID,
      ownerActor: scope.ownerActor, ttlSeconds: scope.ttlSeconds, runAuthority: scope.runAuthority,
      body: body
    )
  }
}
