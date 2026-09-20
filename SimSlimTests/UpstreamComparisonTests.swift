import Foundation
import Testing

@testable import SimSlim

/// Opt-in comparison of the original GUI's CLI backend and this app's Swift
/// backend. A caller must create a new isolated set and provide its manifest.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTSIMSLIM_COMPARISON_MANIFEST"] != nil))
func isolatedUpstreamComparison() async throws {
  struct Manifest: Decodable {
    let set: String
    let devices: [String: String]
    let upstreamBinary: String
  }
  let path = try #require(ProcessInfo.processInfo.environment["SWIFTSIMSLIM_COMPARISON_MANIFEST"])
  let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
  let root = url.deletingLastPathComponent()
  let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
  guard
    root.deletingLastPathComponent().path
      == URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path,
    root.lastPathComponent.hasPrefix("SwiftSimSlim-comparison-"),
    URL(fileURLWithPath: manifest.set).resolvingSymlinksInPath().path
      == root.appendingPathComponent("Devices").path,
    Set(manifest.devices.keys) == ["upstream", "swift"],
    manifest.devices.values.allSatisfy({ UUID(uuidString: $0) != nil }),
    manifest.upstreamBinary == "/private/tmp/SwiftSimSlim-upstream-4ae1659"
  else { throw SimulatorError("Invalid isolated comparison manifest.") }
  let log = ComparisonLog(root: root)
  let runner = CommandRunner(report: { log.event($0) })
  let backend = SimSlimBackend(runner: runner, deviceSets: [manifest.set])
  let inventory = try await backend.listRaw()
  guard Set(inventory.map(\.udid)) == Set(manifest.devices.values),
    inventory.allSatisfy({ $0.osVersion == "27.0" && $0.name.hasPrefix("SwiftSimSlim Comparison ") }
    )
  else { throw SimulatorError("The comparison set contains unexpected devices.") }
  // Ensure the comparison uses exactly the same default service catalog.
  let profileJSON = try await runner.run(manifest.upstreamBinary, ["profiles", "--json"]).checked()
  let categories = try JSONDecoder().decode([SlimCategory].self, from: profileJSON.data)
  try #require(Set(categories.flatMap(\.labels)) == ServiceCatalog.slimmable)
  let selection = try #require(ProcessInfo.processInfo.environment["SWIFTSIMSLIM_COMPARISON_CASE"])
  let pieces = selection.split(separator: ":").map(String.init)
  guard pieces.count == 2, let id = manifest.devices[pieces[0]],
    ["slim-booted", "same-profile", "restore-booted", "slim-shutdown", "restore-services"].contains(
      pieces[1])
  else { throw SimulatorError("Choose one engine:scenario comparison case.") }
  let engine = pieces[0]
  let scenario = pieces[1]
  guard scenario != "restore-services" || engine == "swift" else {
    throw SimulatorError("Direct service timing is available for the Swift backend only.")
  }
  var failure: Error?
  do {
    // Each invocation prepares its own starting state. A slow upstream command
    // cannot leave a partially applied profile for the following measurement.
    let needsSlim =
      scenario == "same-profile" || scenario == "restore-booted" || scenario == "restore-services"
    _ = try await backend.shutdown(udid: id)
    _ = try await backend.configure(
      udid: id, desired: needsSlim ? ServiceCatalog.slimmable : [], preserveBootState: false)
    try await Task.sleep(for: .seconds(10))
    if scenario == "slim-shutdown" { _ = try await backend.shutdown(udid: id) }
    let restore = scenario == "restore-booted" || scenario == "restore-services"
    let preparedDevice = try await backend.find(id)
    let start = ContinuousClock.now
    var problem: String?
    log.note("START \(engine) \(scenario)")
    do {
      if engine == "upstream" {
        _ = try await runner.run(
          manifest.upstreamBinary,
          [
            "--set", manifest.set, "--boot-timeout", "180s", restore ? "off" : "on", id,
            "--preserve-boot-state",
          ],
          timeout: 210, udid: id
        ).checked()
      } else if scenario == "restore-services" {
        try await backend.applyServiceChanges(
          preparedDevice, disable: [], enable: ServiceCatalog.slimmable.sorted())
      } else if restore {
        _ = try await backend.restore(udid: id, preserveBootState: true)
      } else {
        _ = try await backend.slim(
          udid: id, exceptCategories: [], keepLabels: [], preserveBootState: true)
      }
    } catch {
      if error is CancellationError { throw error }
      problem = error.localizedDescription
    }
    let elapsed = start.duration(to: .now).components
    let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
    if problem == nil {
      if scenario == "restore-services" {
        // Persistence verification is deliberately outside the service timer.
        _ = try await backend.shutdown(udid: id)
        _ = try await backend.boot(udid: id)
      }
      let after = try await backend.find(id)
      try #require(after.state == (scenario == "slim-shutdown" ? "Shutdown" : "Booted"))
      if !after.isBooted { _ = try await backend.boot(udid: id) }
      let desired = restore ? Set<String>() : ServiceCatalog.slimmable
      try #require(
        try await backend.disabled(after).intersection(ServiceCatalog.managed) == desired)
    }
    log.result(engine: engine, scenario: scenario, seconds: seconds, error: problem)
  } catch {
    failure = error
    log.note("FAILURE \(error.localizedDescription)")
  }
  // Stop this fixture even when an operation fails. The caller deletes both
  // manifest UUIDs once the independent comparison cases have been collected.
  _ = try await backend.shutdown(udid: id)
  log.note("CASE_FINISHED \(selection); fixture shut down")
  if let failure { throw failure }

}

private final class ComparisonLog: @unchecked Sendable {
  private let lock = NSLock()
  private let root: URL
  init(root: URL) { self.root = root }
  func event(_ event: OperationEvent) { note("[\(event.kind)] \(event.message)") }
  func note(_ value: String) {
    append(Data("\(Date().ISO8601Format()) \(value)\n".utf8), to: "comparison.log")
  }
  func result(engine: String, scenario: String, seconds: Double, error: String?) {
    let object: [String: Any] = [
      "engine": engine, "scenario": scenario, "seconds": seconds,
      "result": error == nil ? "verified" : "failed", "error": error ?? "",
    ]
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
      append(data + Data("\n".utf8), to: "results.jsonl")
    }
    note("RESULT \(engine) \(scenario) \(seconds)s \(error ?? "verified")")
  }
  private func append(_ data: Data, to filename: String) {
    lock.withLock {
      let url = root.appendingPathComponent(filename)
      if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
      }
      if let file = try? FileHandle(forWritingTo: url) {
        defer { try? file.close() }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: data)
      }
    }
  }
}
