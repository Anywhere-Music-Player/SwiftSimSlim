import Foundation
import Testing

@testable import SimSlim

/// Opt in explicitly. Each run creates an entirely new simulator set, never
/// accepts an existing UUID, and records cleanup targets as they are created.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTSIMSLIM_LIVE_TEST_ROOT"] != nil))
func isolatedSimulatorAcceptance() async throws {
  let env = ProcessInfo.processInfo.environment
  let root = URL(fileURLWithPath: try #require(env["SWIFTSIMSLIM_LIVE_TEST_ROOT"]))
  guard !FileManager.default.fileExists(atPath: root.path) else {
    throw SimulatorError("Live test root must not already exist.")
  }
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  let set = root.appendingPathComponent("Devices").path
  try FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
  let log = LiveLog(root: root)
  let backend = SimSlimBackend(deviceSets: [set], report: { log.record($0) })
  let runtime = env["SWIFTSIMSLIM_LIVE_RUNTIME"] ?? "com.apple.CoreSimulator.SimRuntime.iOS-26-5"
  let type = "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"
  var created: [String] = []
  var failure: Error?
  do {
    let result = try await backend.runner.run(
      "/usr/bin/xcrun", ["simctl", "--set", set, "create", "SwiftSimSlim QA", type, runtime]
    ).checked()
    let sourceID = result.text
    guard UUID(uuidString: sourceID) != nil else { throw SimulatorError("Invalid created UUID.") }
    created.append(sourceID)
    log.created(created)
    log.checkpoint("created", sourceID)
    _ = try await backend.boot(udid: sourceID)
    var source = try await backend.find(sourceID)
    #expect(source.isBooted)
    let fixtureApp = try #require(env["SWIFTSIMSLIM_FIXTURE_APP"])
    let bundleID = "com.anywhere.SwiftSimSlim.AcceptanceFixture"
    try await backend.simctl(source, ["install", sourceID, fixtureApp])
    try await backend.simctl(source, ["launch", sourceID, bundleID])
    let container = try await backend.simctl(
      source, ["get_app_container", sourceID, bundleID, "data"]
    ).text
    let appDocument = URL(fileURLWithPath: container).appendingPathComponent(
      "Documents/source-document.txt")
    for _ in 0..<50 {
      if DiskStore.exists(appDocument) { break }
      try await Task.sleep(for: .milliseconds(200))
    }
    #expect(try String(contentsOf: appDocument, encoding: .utf8) == "source-value")
    log.checkpoint("fixture-app-installed", bundleID)
    let stock = try await backend.measure(udid: sourceID)
    log.checkpoint("stock-memory", "\(stock.bytes) bytes; \(stock.processes) processes")
    _ = try await backend.rename(udid: sourceID, name: "SwiftSimSlim QA Source")
    #expect(try await backend.find(sourceID).name == "SwiftSimSlim QA Source")
    _ = try await backend.shutdown(udid: sourceID)
    // Seed disposable and durable content only inside this newly created data tree.
    source = try await backend.find(sourceID)
    let data = try DiskStore.dataDirectory(source)
    let sentinels = ["Documents/keep.txt", "Media/keep.txt", "Documents/Caches/keep.txt"]
    for relative in sentinels { try log.seed(data.appendingPathComponent(relative), bytes: 64) }
    let cache = data.appendingPathComponent("Library/Caches/SwiftSimSlimAcceptance/disposable.bin")
    try log.seed(cache, bytes: 1_048_576)
    log.checkpoint("offline-slim-start", sourceID)
    _ = try await backend.slim(
      udid: sourceID, exceptCategories: [], keepLabels: [], preserveBootState: true)
    #expect(try await backend.find(sourceID).state == "Shutdown")
    _ = try await backend.boot(udid: sourceID)
    source = try await backend.find(sourceID)
    let slimmed = try await backend.disabled(source)
    #expect(slimmed.intersection(ServiceCatalog.managed) == ServiceCatalog.slimmable)
    let slimMemory = try await backend.measure(udid: sourceID)
    log.checkpoint("slim-memory", "\(slimMemory.bytes) bytes; \(slimMemory.processes) processes")
    log.checkpoint(
      "offline-slim-verified", "\(slimmed.intersection(ServiceCatalog.managed).count) disabled")
    let listed = try await backend.devices()
    #expect(listed.count == 1)
    #expect(listed.first?.managedDisabled == ServiceCatalog.slimmable.count)
    // A booted profile change exercises the supported launchctl/reboot path.
    let except: Set<String> = ["store"]
    let desired = try ServiceCatalog.desired(except: except, keep: [])
    _ = try await backend.slim(
      udid: sourceID, exceptCategories: except, keepLabels: [], preserveBootState: true)
    #expect(try await backend.disabled(source).intersection(ServiceCatalog.managed) == desired)
    #expect(try await backend.find(sourceID).isBooted)
    log.checkpoint("booted-profile-verified", "\(desired.count) disabled")
    // Clone a booted source and verify its state is restored.
    let clone = try await backend.clone(udid: sourceID, name: "SwiftSimSlim QA Clone")
    created.append(clone.udid)
    log.created(created)
    #expect(try await backend.find(sourceID).isBooted)
    let cloneDevice = try await backend.find(clone.udid)
    #expect(cloneDevice.state == "Shutdown")
    let cloneData = try DiskStore.dataDirectory(cloneDevice)
    for relative in sentinels {
      #expect(DiskStore.exists(cloneData.appendingPathComponent(relative)))
    }
    try Data("clone-only".utf8).write(to: cloneData.appendingPathComponent(sentinels[0]))
    #expect(
      try Data(contentsOf: data.appendingPathComponent(sentinels[0])) != Data("clone-only".utf8))
    _ = try await backend.boot(udid: clone.udid)
    #expect(try await backend.disabled(cloneDevice).intersection(ServiceCatalog.managed) == desired)
    _ = try await backend.shutdown(udid: clone.udid)
    _ = try await backend.boot(udid: clone.udid)
    try await backend.simctl(cloneDevice, ["launch", clone.udid, bundleID])
    let clonedContainer = try await backend.simctl(
      cloneDevice, ["get_app_container", clone.udid, bundleID, "data"]
    ).text
    let clonedDocument = URL(fileURLWithPath: clonedContainer).appendingPathComponent(
      "Documents/source-document.txt")
    #expect(try String(contentsOf: clonedDocument, encoding: .utf8) == "source-value")
    try Data("clone-only".utf8).write(to: clonedDocument)
    #expect(try String(contentsOf: appDocument, encoding: .utf8) == "source-value")
    _ = try await backend.shutdown(udid: clone.udid)
    log.checkpoint("clone-verified", clone.udid)
    // Restore through the offline path, then verify after another boot.
    _ = try await backend.restore(udid: clone.udid, preserveBootState: true)
    #expect(try await backend.find(clone.udid).state == "Shutdown")
    _ = try await backend.boot(udid: clone.udid)
    #expect(try await backend.disabled(cloneDevice).intersection(ServiceCatalog.managed).isEmpty)
    log.checkpoint("restore-verified", clone.udid)
    _ = try await backend.shutdown(udid: sourceID)
    try log.seed(cache, bytes: 1_048_576)
    let plan = try await backend.diskCleanupPlan(udid: sourceID)
    #expect(plan.bytes(for: "caches") >= 1_048_576)
    let cleaned = try await backend.cleanDisk(
      udid: sourceID, categoryIDs: ["caches", "logs", "temporary"], preserveBootState: true)
    #expect(!DiskStore.exists(cache))
    for relative in sentinels { #expect(DiskStore.exists(data.appendingPathComponent(relative))) }
    #expect(try await backend.find(sourceID).state == "Shutdown")
    #expect(try String(contentsOf: appDocument, encoding: .utf8) == "source-value")
    log.checkpoint(
      "cleanup-verified", "\(cleaned.reclaimedBytes) bytes reclaimed; durable sentinels preserved")
    _ = try await backend.erase(udid: clone.udid)
    #expect(try await backend.find(clone.udid).state == "Shutdown")
    #expect(!DiskStore.exists(cloneData.appendingPathComponent(sentinels[0])))
    _ = try await backend.boot(udid: clone.udid)
    #expect(try await backend.disabled(cloneDevice).intersection(ServiceCatalog.managed).isEmpty)
    log.checkpoint("erase-verified", clone.udid)
  } catch {
    failure = error
    log.checkpoint("failure", error.localizedDescription)
  }
  // Scope cleanup to devices inside this freshly created, unique set. This also
  // catches an incomplete clone if the operation could not return its UUID.
  do {
    let remaining = try await backend.listRaw()
    for device in remaining {
      guard device.set == set else { throw SimulatorError("Unexpected device set during cleanup.") }
      _ = try await backend.delete(udid: device.udid)
      log.checkpoint("deleted-test-device", device.udid)
    }
    #expect(try await backend.listRaw().isEmpty)
  } catch {
    log.checkpoint("cleanup-failure", error.localizedDescription)
    throw SimulatorError(
      "\(failure?.localizedDescription ?? "Tests finished.") Cleanup failed: \(error.localizedDescription)"
    )
  }
  if let failure { throw failure }
  log.checkpoint("finished", "All isolated simulator acceptance checks completed")
}

private final class LiveLog: @unchecked Sendable {
  private let lock = NSLock()
  let root: URL
  init(root: URL) { self.root = root }
  func record(_ event: OperationEvent) {
    append("[\(event.kind)] \(event.udid ?? "") \(event.message)")
  }
  func checkpoint(_ name: String, _ detail: String) {
    let text = "CHECKPOINT \(name): \(detail)"
    append(text)
    print(text)
  }
  func created(_ ids: [String]) {
    try? Data(ids.joined(separator: "\n").utf8).write(
      to: root.appendingPathComponent("created-udids.txt"), options: .atomic)
  }
  func seed(_ url: URL, bytes: Int) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 0x61, count: bytes).write(to: url)
  }
  private func append(_ line: String) {
    lock.withLock {
      let url = root.appendingPathComponent("operations.log")
      if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
      }
      guard let handle = try? FileHandle(forWritingTo: url) else { return }
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: Data(("\(Date().ISO8601Format()) \(line)\n").utf8))
    }
  }
}
