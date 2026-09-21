import Foundation
import Testing

@testable import SwiftSimSlim

/// An explicit manifest from a newly created isolated set is required. Ordinary
/// Cmd-U never enables this check or mutates an existing simulator.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTSIMSLIM_SPEED_MANIFEST"] != nil))
func isolatedIPhone18ProPerformance() async throws {
  struct Manifest: Decodable {
    let udid: String
    let set: String
  }
  let path = try #require(ProcessInfo.processInfo.environment["SWIFTSIMSLIM_SPEED_MANIFEST"])
  let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
  let root = url.deletingLastPathComponent()
  let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
  guard
    root.deletingLastPathComponent().path
      == URL(fileURLWithPath: "/private/tmp").resolvingSymlinksInPath().path,
    root.lastPathComponent.hasPrefix("SwiftSimSlim-speed-"),
    url.lastPathComponent == "device.json", UUID(uuidString: manifest.udid) != nil,
    URL(fileURLWithPath: manifest.set).resolvingSymlinksInPath().path
      == root.appendingPathComponent("Devices").path
  else { throw SimulatorError("Expected a fresh isolated performance fixture.") }
  let log = PerformanceLog(root: root)
  let backend = SwiftSimSlimBackend(deviceSets: [manifest.set], report: { log.event($0) })
  let devices = try await backend.listRaw()
  let device = try #require(devices.first)
  guard devices.count == 1, device.udid == manifest.udid,
    device.name == "SwiftSimSlim Speed iPhone 18 Pro", device.osVersion == "27.0"
  else { throw SimulatorError("Unexpected performance fixture device.") }
  var failure: Error?
  do {
    _ = try await backend.restore(udid: device.udid, preserveBootState: false)
    if ProcessInfo.processInfo.environment["SWIFTSIMSLIM_SPEED_BASELINE"] == "1" {
      let sample = Array(ServiceCatalog.slimmable.sorted().prefix(8))
      let baseline = ContinuousClock.now
      for label in sample {
        try await backend.simctl(
          device, ["spawn", device.udid, "launchctl", "disable", "system/" + label])
      }
      log.timing("old-serial-8-services", since: baseline)
      _ = try await backend.restore(udid: device.udid, preserveBootState: false)
      let batch = ContinuousClock.now
      try await backend.applyServiceChanges(device, disable: sample, enable: [])
      log.timing("new-parallel-8-services", since: batch)
      _ = try await backend.restore(udid: device.udid, preserveBootState: false)
      #expect(try await backend.disabled(device).intersection(ServiceCatalog.managed).isEmpty)

    }

    let slim = ContinuousClock.now
    _ = try await backend.slim(
      udid: device.udid, exceptCategories: [], keepLabels: [], preserveBootState: true)
    log.timing("slim-booted-170", since: slim)
    #expect(try await backend.find(device.udid).isBooted)
    #expect(
      try await backend.disabled(device).intersection(ServiceCatalog.managed)
        == ServiceCatalog.slimmable)
    let unchanged = ContinuousClock.now
    _ = try await backend.slim(
      udid: device.udid, exceptCategories: [], keepLabels: [], preserveBootState: true)
    log.timing("unchanged-profile", since: unchanged)

    let restore = ContinuousClock.now
    _ = try await backend.restore(udid: device.udid, preserveBootState: true)
    log.timing("restore-170", since: restore)
    #expect(try await backend.disabled(device).intersection(ServiceCatalog.managed).isEmpty)

    // Exercise the same bounded fallback on a live runtime, then verify after
    // reboot. The forced offline-store failure is covered by unit tests.
    let fallbackStart = ContinuousClock.now
    try await backend.applyServiceChanges(
      device, disable: ServiceCatalog.slimmable.sorted(), enable: [])
    log.timing("parallel-fallback-170-commands", since: fallbackStart)
    _ = try await backend.shutdown(udid: device.udid)
    _ = try await backend.boot(udid: device.udid)
    #expect(
      try await backend.disabled(device).intersection(ServiceCatalog.managed)
        == ServiceCatalog.slimmable)
    _ = try await backend.shutdown(udid: device.udid)
    let shutdownRestore = ContinuousClock.now
    _ = try await backend.restore(udid: device.udid, preserveBootState: true)
    log.timing("restore-preserve-shutdown", since: shutdownRestore)
    #expect(try await backend.find(device.udid).state == "Shutdown")
  } catch {
    failure = error
    log.line("FAILURE \(error.localizedDescription)")
  }
  _ = try await backend.delete(udid: manifest.udid)
  #expect(try await backend.listRaw().isEmpty)
  log.line("CLEANUP verified: isolated device deleted")
  if let failure { throw failure }
}

private final class PerformanceLog: @unchecked Sendable {
  private let lock = NSLock()
  let url: URL
  init(root: URL) { url = root.appendingPathComponent("performance.log") }
  func event(_ event: OperationEvent) { line("[\(event.kind)] \(event.message)") }
  func timing(_ name: String, since start: ContinuousClock.Instant) {
    line("TIMING \(name): \(start.duration(to: .now))")
  }
  func line(_ value: String) {
    lock.withLock {
      let line = "\(Date().ISO8601Format()) \(value)\n"
      if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
      }
      if let file = try? FileHandle(forWritingTo: url) {
        defer { try? file.close() }
        _ = try? file.seekToEnd()
        try? file.write(contentsOf: Data(line.utf8))
      }
      if value.hasPrefix("TIMING") || value.hasPrefix("CLEANUP") { print(value) }
    }
  }
}
