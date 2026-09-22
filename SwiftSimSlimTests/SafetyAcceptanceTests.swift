import Foundation
import Testing

@testable import SwiftSimSlim

/// Explicit opt-in; this test creates and removes only its own isolated simulator.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTSIMSLIM_SAFETY_ROOT"] != nil))
func isolatedServiceSafetyMatrix() async throws {
  let env = ProcessInfo.processInfo.environment
  let root = URL(fileURLWithPath: try #require(env["SWIFTSIMSLIM_SAFETY_ROOT"])).standardizedFileURL
  guard
    root.deletingLastPathComponent().resolvingSymlinksInPath().path
      == URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path,
    root.lastPathComponent.hasPrefix("SwiftSimSlim-safety-"),
    !FileManager.default.fileExists(atPath: root.path)
  else { throw SimulatorError("Use a new /private/tmp/SwiftSimSlim-safety-<unique> directory.") }
  let fixtureApp = try #require(env["SWIFTSIMSLIM_FIXTURE_APP"])
  let runtime = env["SWIFTSIMSLIM_LIVE_RUNTIME"] ?? "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
  let type =
    env["SWIFTSIMSLIM_LIVE_DEVICE_TYPE"] ?? "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"
  let set = root.appendingPathComponent("Devices").path
  try FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
  let trace = SafetyTrace(url: root.appendingPathComponent("operations.log"))
  let backend = SwiftSimSlimBackend(deviceSets: [set], report: { trace.record($0) })
  let store = ServiceBackupStore(directory: root.appendingPathComponent("Backups"))
  var evidence: [String: Any] = [
    "date": Date().ISO8601Format(), "runtime": runtime, "deviceType": type,
    "requestedDisabledLabels": ServiceCatalog.slimmable.sorted(),
    "requiredEnabledLabels": ServiceCatalog.compatibility.sorted(),
    "settleSeconds": 10,
    "measurement":
      "Sum of top MEM for the simulator launchd process tree; not host-wide RAM savings",
  ]
  for (key, executable, args) in [
    ("xcode", "/usr/bin/xcodebuild", ["-version"]),
    ("macOS", "/usr/bin/sw_vers", []),
    ("chip", "/usr/sbin/sysctl", ["-n", "machdep.cpu.brand_string"]),
    ("hostMemoryBytes", "/usr/sbin/sysctl", ["-n", "hw.memsize"]),
  ] {
    evidence[key] = try await backend.runner.run(executable, args).checked().text
  }
  var created: String?
  var failure: Error?
  do {
    let id = try await backend.runner.run(
      "/usr/bin/xcrun", ["simctl", "--set", set, "create", "SwiftSimSlim Safety QA", type, runtime]
    ).checked().text
    guard UUID(uuidString: id) != nil else { throw SimulatorError("Invalid created UUID.") }
    created = id
    evidence["udid"] = id
    // Keep an exact cleanup target available even if the test runner is interrupted.
    try Data(id.utf8).write(to: root.appendingPathComponent("created-uuid.txt"), options: .atomic)
    _ = try await backend.boot(udid: id)
    let device = try await backend.find(id)
    let bundleID = "com.buildsucceeded.SwiftSimSlim.AcceptanceFixture"
    trace.record(
      .init(kind: .stage, udid: id, message: "Installing acceptance fixture (up to 300 seconds)…"))
    let install = ContinuousClock.now
    try await backend.simctl(device, ["install", id, fixtureApp], timeout: 300)
    evidence["fixtureInstallSeconds"] = seconds(install.duration(to: .now))
    let originalDocument = try await launchSafetyFixture(backend, device, bundleID)
    try #require(try String(contentsOf: originalDocument, encoding: .utf8) == "source-value")
    // A unique value cannot be recreated by the fixture after accidental data loss.
    let sentinelValue = UUID().uuidString
    try Data(sentinelValue.utf8).write(to: originalDocument, options: .atomic)
    evidence["preApplyChecks"] = ["fixture scene ready", "unique durable document written"]
    try await Task.sleep(for: .seconds(10))
    let before = try await backend.measure(udid: id)
    evidence["beforeMemoryBytes"] = before.bytes
    evidence["beforeProcesses"] = before.processes
    let plan = try await backend.previewProfile(udid: id, desired: ServiceCatalog.slimmable)
    evidence["plannedDisableLabels"] = plan.disable
    evidence["plannedEnableLabels"] = plan.enable
    let start = ContinuousClock.now
    try await backend.configureWithBackup(
      udid: id, desired: ServiceCatalog.slimmable, preserveBootState: true,
      expectedCurrent: plan.current, save: { try await store.save($0) })
    evidence["applyTotalSeconds"] = seconds(start.duration(to: .now))
    let backup = try #require(try await store.load(id))
    try backup.exportedData().write(
      to: root.appendingPathComponent("original-state.json"), options: .atomic)
    try #require(before.bytes > 0)
    try #require(
      try await backend.disabled(device).intersection(ServiceCatalog.managed)
        == ServiceCatalog.slimmable)
    // Launch the same app and use the same settle interval before both samples.
    let afterDocument = try await launchSafetyFixture(backend, device, bundleID)
    try #require(try String(contentsOf: afterDocument, encoding: .utf8) == sentinelValue)
    try await Task.sleep(for: .seconds(10))
    let after = try await backend.measure(udid: id)
    try #require(after.bytes > 0)
    evidence["afterMemoryBytes"] = after.bytes
    evidence["afterProcesses"] = after.processes
    _ = try await backend.shutdown(udid: id)
    _ = try await backend.boot(udid: id)
    try #require(
      try await backend.disabled(device).intersection(ServiceCatalog.managed)
        == ServiceCatalog.slimmable)
    let sentinel = try await launchSafetyFixture(backend, device, bundleID)
    try #require(try String(contentsOf: sentinel, encoding: .utf8) == sentinelValue)
    evidence["postApplyChecks"] = [
      "live managed state", "second reboot persistence", "fixture app launch",
      "durable document retained",
    ]
    let restore = ContinuousClock.now
    try await backend.restoreSavedState(backup)
    evidence["restoreTotalSeconds"] = seconds(restore.duration(to: .now))
    try #require(
      try await backend.disabled(device).intersection(ServiceCatalog.managed)
        == backup.disabled.intersection(ServiceCatalog.slimmable))
    try #require(try await backend.find(id).isBooted)
    let restoredDocument = try await launchSafetyFixture(backend, device, bundleID)
    try #require(try String(contentsOf: restoredDocument, encoding: .utf8) == sentinelValue)
    evidence["restoreChecks"] = [
      "saved managed state", "saved boot state", "fixture scene ready", "unique document retained",
    ]
    // Repeat from Shutdown to exercise live capture and final boot-state restoration.
    _ = try await backend.shutdown(udid: id)
    let stopped = ContinuousClock.now
    try await backend.configureWithBackup(
      udid: id, desired: ServiceCatalog.slimmable, preserveBootState: true,
      save: { try await store.save($0) })
    evidence["shutdownApplyTotalSeconds"] = seconds(stopped.duration(to: .now))
    try #require(try await backend.find(id).state == "Shutdown")
    let stoppedBackup = try #require(try await store.load(id))
    try #require(stoppedBackup.bootState == "Shutdown")
    try await backend.restoreSavedState(stoppedBackup)
    try #require(try await backend.find(id).state == "Shutdown")
    evidence["shutdownChecks"] = [
      "live original-state capture", "apply preserves Shutdown", "saved restore preserves Shutdown",
    ]
  } catch {
    failure = error
    evidence["failure"] = error.localizedDescription
  }
  if let created {
    do {
      _ = try await backend.delete(udid: created)
      try #require(try await backend.listRaw().isEmpty)
      evidence["cleanup"] = "isolated device deleted; set empty"
    } catch {
      evidence["cleanupFailure"] = error.localizedDescription
      failure = SimulatorError(
        "\(failure?.localizedDescription ?? "Checks complete"); cleanup failed: \(error.localizedDescription)"
      )
    }
  }
  let data = try JSONSerialization.data(
    withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
  try data.write(to: root.appendingPathComponent("safety-matrix.json"), options: .atomic)
  try Data(trace.text.utf8).write(
    to: root.appendingPathComponent("operations.log"), options: .atomic)
  print("SAFETY EVIDENCE: \(root.path)")
  if let failure { throw failure }
}

/// simctl launch returning a PID is not proof that UIKit finished launching.
private func launchSafetyFixture(
  _ backend: SwiftSimSlimBackend, _ device: RawDevice, _ bundleID: String
) async throws -> URL {
  let probe = UUID().uuidString
  try await backend.simctl(
    device,
    ["launch", "--terminate-running-process", device.udid, bundleID, "--safety-probe", probe])
  let container = try await backend.simctl(
    device, ["get_app_container", device.udid, bundleID, "data"]
  ).text
  let documents = URL(fileURLWithPath: container).appendingPathComponent("Documents")
  let marker = documents.appendingPathComponent("launch-probe.txt")
  let deadline = ContinuousClock.now + .seconds(20)
  while ContinuousClock.now < deadline {
    if (try? String(contentsOf: marker, encoding: .utf8)) == probe {
      return documents.appendingPathComponent("source-document.txt")
    }
    try await Task.sleep(for: .milliseconds(200))
  }
  throw SimulatorError("Fixture did not report scene readiness within 20 seconds.")
}

private func seconds(_ duration: Duration) -> Double {
  Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

private final class SafetyTrace: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []
  private let url: URL
  init(url: URL) {
    self.url = url
    FileManager.default.createFile(atPath: url.path, contents: nil)
  }
  func record(_ event: OperationEvent) {
    lock.withLock {
      let line = "\(Date().ISO8601Format()) [\(event.udid ?? "host")] \(event.message)"
      lines.append(line)
      if let handle = try? FileHandle(forWritingTo: url) {
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data((line + "\n").utf8))
      }
      if event.kind == .stage { print(line) }
    }
  }
  var text: String { lock.withLock { lines.joined(separator: "\n") } }
}
