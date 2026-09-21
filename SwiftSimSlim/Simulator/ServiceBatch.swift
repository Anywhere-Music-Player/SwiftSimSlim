import Foundation

/// Bounded concurrency without a shell inside the iOS runtime. Recent runtimes
/// contain launchctl but no /bin/sh, so shell-based batches silently fell back
/// to the original serial path. Each transition remains independently checked.
enum ServiceBatch {
  static let concurrency = 8
}

private struct ServiceTransition: Sendable {
  let action: String
  let label: String
}

extension SwiftSimSlimBackend {
  func applyServiceChanges(_ device: RawDevice, disable: [String], enable: [String]) async throws {
    guard UUID(uuidString: device.udid) != nil,
      Set(disable).isSubset(of: ServiceCatalog.slimmable),
      Set(enable).isSubset(of: ServiceCatalog.managed),
      Set(disable).isDisjoint(with: enable)
    else { throw SimulatorError("Invalid service transition batch.") }
    let deadline = ContinuousClock.now + .seconds(600)
    var pending =
      Set(disable).sorted().map { ServiceTransition(action: "disable", label: $0) }
      + Set(enable).sorted().map { ServiceTransition(action: "enable", label: $0) }
    let total = pending.count
    var completed = 0
    var lastFailure = ""
    for attempt in 0...2 where !pending.isEmpty {
      try Task.checkCancellation()
      let retryCount = pending.count
      if attempt > 0 {
        stage("Retrying \(retryCount) failed services · attempt \(attempt)/2…", device)
      } else {
        stage("Updating services 0/\(total) · up to \(ServiceBatch.concurrency) at once…", device)
      }
      pending = try await withThrowingTaskGroup(of: (ServiceTransition, String?).self) { group in
        var iterator = pending.makeIterator()
        var failed: [ServiceTransition] = []
        for _ in 0..<ServiceBatch.concurrency {
          guard let change = iterator.next() else { break }
          group.addTask { try await performServiceChange(change, device, deadline: deadline) }
        }
        while let (change, failure) = try await group.next() {
          try Task.checkCancellation()
          if let failure {
            lastFailure = "\(change.label): \(failure)"
            failed.append(change)
          } else {
            completed += 1
          }
          let suffix = attempt == 0 ? "" : " · retry \(attempt)/2"
          stage("Updated services \(completed)/\(total)\(suffix)…", device)
          if let next = iterator.next() {
            group.addTask { try await performServiceChange(next, device, deadline: deadline) }
          }
        }
        return failed
      }
    }
    guard pending.isEmpty else {
      throw SimulatorError("\(pending.count) service changes failed after retries. \(lastFailure)")
    }
  }

  private func performServiceChange(
    _ change: ServiceTransition, _ device: RawDevice, deadline: ContinuousClock.Instant
  ) async throws -> (ServiceTransition, String?) {
    try Task.checkCancellation()
    let remaining = ContinuousClock.now.duration(to: deadline).components
    let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
    guard seconds > 0 else {
      throw SimulatorError(
        "Service updates exceeded ten minutes. Some changes may already be applied.")
    }
    do {
      try await simctl(
        device,
        ["spawn", device.udid, "launchctl", change.action, "system/" + change.label],
        timeout: min(120, seconds))
      return (change, nil)
    } catch {
      if error is CancellationError { throw error }
      return (change, error.localizedDescription)
    }
  }
}
