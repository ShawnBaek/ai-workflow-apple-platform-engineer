import AppleVerificationCore
import Foundation

guard CommandLine.arguments.count >= 3 else { exit(3) }
do {
  let authority = try HarnessRuntime.object(URL(fileURLWithPath: CommandLine.arguments[2]))
  let discriminator = CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "e"
  let capacity = CommandLine.arguments.count > 4 && CommandLine.arguments[4] == "capacity"
  let descriptor: [String: Any] =
    capacity
    ? [
      "repository_fingerprint": "sha256:" + String(repeating: discriminator, count: 64),
      "remote_repository": "owner/repo-\(discriminator)",
    ]
    : [
      "identity_version": "github_remote_v2",
      "repository_fingerprint": "sha256:" + String(repeating: "e", count: 64),
    ]
  let admission: [String: Any]? =
    capacity ? ["heavy_jobs": 1, "active_devices": 0, "internal_workers": 1] : nil
  _ = try ResourceCoordinator.acquire(
    statePath: URL(fileURLWithPath: CommandLine.arguments[1]),
    resource: capacity ? ResourceCoordinator.github : ResourceCoordinator.sourceWriter,
    descriptor: descriptor, ownerRunID: "run", ownerActor: "codex", ttlSeconds: 60,
    admission: admission, runAuthority: authority)
  exit(0)
} catch let error as ResourceCoordinatorError {
  exit(["resource_conflict", "capacity_exceeded"].contains(error.code) ? 2 : 3)
} catch { exit(3) }
