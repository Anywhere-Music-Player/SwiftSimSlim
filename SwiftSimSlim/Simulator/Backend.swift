import Foundation

struct RawDevice: Sendable, Decodable {
  let udid: String
  let name: String
  let state: String
  let isAvailable: Bool?
  let dataPath: String?
  var set: String = ""
  var osVersion: String = ""
  var isBooted: Bool { state == "Booted" }
  enum CodingKeys: String, CodingKey { case udid, name, state, isAvailable, dataPath }
}

/// In-process Swift implementation. No bundled CLI, daemon, or helper service.
struct SwiftSimSlimBackend: Sendable {
  let runner: CommandRunner
  let deviceSets: [String]
  let writeOverrides: @Sendable (String, Set<String>) async throws -> Void
  init(deviceSets: [String] = ["", "testing"], report: @escaping OperationReporter = { _ in }) {
    self.deviceSets = deviceSets
    runner = CommandRunner(report: report)
    writeOverrides = { try DisabledStore.merge(udid: $0, desired: $1) }
  }

  init(
    runner: CommandRunner, deviceSets: [String] = ["", "testing"],
    writeOverrides: @escaping @Sendable (String, Set<String>) async throws -> Void = {
      try DisabledStore.merge(udid: $0, desired: $1)
    }
  ) {
    self.runner = runner
    self.writeOverrides = writeOverrides
    self.deviceSets = deviceSets
  }

  func stage(_ message: String, _ device: RawDevice) {
    runner.report(.init(kind: .stage, udid: device.udid, message: message))
  }

  func listRaw(set: String? = nil) async throws -> [RawDevice] {
    struct Response: Decodable { let devices: [String: [RawDevice]] }
    var all: [RawDevice] = []
    for token in set.map({ [$0] }) ?? deviceSets {
      do {
        let args =
          ["simctl"] + (token.isEmpty ? [] : ["--set", token]) + ["list", "devices", "-j"]
        let result = try await readDeviceList(args)
        let response = try JSONDecoder().decode(Response.self, from: result.data)
        for (runtime, devices) in response.devices where runtime.contains("iOS-") {
          for var device in devices where device.isAvailable != false {
            guard UUID(uuidString: device.udid) != nil else { continue }
            device.set = token
            device.osVersion = runtime.components(separatedBy: "iOS-").last!.replacingOccurrences(
              of: "-", with: ".")
            all.append(device)
          }
        }
      } catch {
        if token.isEmpty || set != nil || deviceSets.count == 1 { throw error }
      }
    }
    return all.sorted { ($0.osVersion, $0.name, $0.udid) < ($1.osVersion, $1.name, $1.udid) }
  }

  private func readDeviceList(_ args: [String]) async throws -> CommandResult {
    do { return try await runner.run("/usr/bin/xcrun", args, log: false).checked() } catch let error
      as SimulatorError where error.isTimeout
    {
      // A busy CoreSimulator service can stall a read immediately after boot.
      // Retrying the read is safe; simulator mutations are never retried here.
      runner.report(
        .init(
          kind: .output, udid: nil, message: "CoreSimulator is busy; retrying the device list once…"
        ))
      try await Task.sleep(for: .milliseconds(500))
      return try await runner.run("/usr/bin/xcrun", args, log: false).checked()
    }
  }

  func find(_ udid: String, set: String? = nil) async throws -> RawDevice {
    guard UUID(uuidString: udid) != nil else {
      throw SimulatorError("An exact simulator UUID is required.")
    }
    let devices = try await listRaw(set: set)
    guard let device = devices.first(where: { $0.udid == udid }) else {
      throw SimulatorError("Simulator \(udid) was not found.")
    }
    return device
  }

  @discardableResult
  func simctl(
    _ device: RawDevice, _ arguments: [String], timeout: TimeInterval = 120, log: Bool = true
  ) async throws -> CommandResult {
    let args = ["simctl"] + (device.set.isEmpty ? [] : ["--set", device.set]) + arguments
    return try await runner.run(
      "/usr/bin/xcrun", args, timeout: timeout, udid: device.udid, log: log
    ).checked()
  }

  func disabled(_ device: RawDevice, log: Bool = false) async throws -> Set<String> {
    let start = ContinuousClock.now
    defer { if log { timing("service-state-read", start, device.udid) } }
    let output = try await simctl(
      device, ["spawn", device.udid, "launchctl", "print-disabled", "system"], log: log)
    if output.text == "disabled services = (no disabled services)" { return [] }
    guard output.text.contains("disabled services = {"), output.text.hasSuffix("}") else {
      throw SimulatorError(
        "CoreSimulator returned an incomplete launchd service state. No profile changes were applied from this response."
      )
    }
    return ServiceCatalog.parseDisabled(output.text)
  }

  func devices() async throws -> [SimulatorDevice] {
    let raw = try await listRaw()
    let memory = await measurements(raw.filter(\.isBooted))
    var devices: [SimulatorDevice] = []
    for device in raw {
      var count: Int?
      var statusError: String?
      if device.isBooted {
        do { count = try await disabled(device).intersection(ServiceCatalog.slimmable).count } catch
        { statusError = error.localizedDescription }
      }
      devices.append(
        .init(
          udid: device.udid, name: device.name, state: device.state, osVersion: device.osVersion,
          managedDisabled: count, managedTotal: ServiceCatalog.slimmable.count,
          statusError: statusError,
          memory: memory.values[device.udid], memoryError: memory.errors[device.udid]))
    }
    return devices
  }
  func categories() async throws -> [SlimCategory] { ServiceCatalog.categories }
  func diskCleanupCategories() async throws -> [DiskCleanupCategory] { DiskStore.categories }

  func bootAndWait(_ device: RawDevice) async throws {
    let start = ContinuousClock.now
    defer { timing("boot-and-readiness", start, device.udid) }
    stage("Booting simulator…", device)
    do { try await simctl(device, ["boot", device.udid]) } catch {
      let current = try await find(device.udid, set: device.set)
      guard current.isBooted else { throw error }
    }
    try await simctl(device, ["bootstatus", device.udid, "-b"], timeout: 600)
  }

  func stop(_ device: RawDevice) async throws {
    let start = ContinuousClock.now
    defer { timing("shutdown", start, device.udid) }
    stage("Shutting down…", device)
    do { try await simctl(device, ["shutdown", device.udid], timeout: 30) } catch {
      let current = try await find(device.udid, set: device.set)
      guard current.state == "Shutdown" else { throw error }
    }
    let deadline = Date().addingTimeInterval(30)
    repeat {
      let current = try await find(device.udid, set: device.set)
      if current.state == "Shutdown" { return }
      try await Task.sleep(for: .milliseconds(500))
    } while Date() < deadline
    throw SimulatorError("Timed out waiting for the simulator to shut down.")
  }

  func boot(udid: String) async throws -> SimulatorMutationResult {
    let device = try await find(udid)
    try await bootAndWait(device)
    return .init(action: "boot", udid: udid, name: device.name, sourceUdid: nil)
  }
  func shutdown(udid: String) async throws -> SimulatorMutationResult {
    let device = try await find(udid)
    try await stop(device)
    return .init(action: "shutdown", udid: udid, name: device.name, sourceUdid: nil)
  }
  static func normalizedName(_ name: String) throws -> String {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.unicodeScalars.count <= 128,
      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      throw SimulatorError("Use a name of 1–128 characters without control characters.")
    }
    return name
  }
  func rename(udid: String, name: String) async throws -> String {
    let name = try Self.normalizedName(name)
    let device = try await find(udid)
    try await simctl(device, ["rename", device.udid, name])
    return "Renamed to \(name)."
  }
  func erase(udid: String) async throws -> String {
    let device = try await find(udid)
    try await stop(device)
    try await simctl(device, ["erase", device.udid], timeout: 600)
    // launchd overrides live outside the data erased by simctl.
    try await ensure(try await find(udid), desired: [])
    try await stop(device)
    return "Erased simulator and restored managed services."
  }
  func delete(udid: String) async throws -> String {
    let device = try await find(udid)
    try await stop(device)
    try await simctl(device, ["delete", device.udid])
    return "Deleted simulator."
  }

  func slim(
    udid: String, exceptCategories: Set<String>, keepLabels: Set<String>, preserveBootState: Bool
  ) async throws -> String {
    let desired = try ServiceCatalog.desired(except: exceptCategories, keep: keepLabels)
    return try await configure(udid: udid, desired: desired, preserveBootState: preserveBootState)
  }
  func restore(udid: String, preserveBootState: Bool) async throws -> String {
    try await configure(udid: udid, desired: [], preserveBootState: preserveBootState)
  }
  func configure(udid: String, desired: Set<String>, preserveBootState: Bool) async throws -> String
  {
    let device = try await find(udid)
    guard desired.isEmpty || ServiceCatalog.supportsPersistence(device.osVersion) else {
      throw SimulatorError("Persistent slimming requires iOS 18.5 or newer.")
    }
    guard ["Booted", "Shutdown"].contains(device.state) else {
      throw SimulatorError("Wait for the simulator to finish changing state.")
    }
    var failure: Error?
    do { try await ensure(device, desired: desired) } catch { failure = error }
    if preserveBootState && !device.isBooted {
      do { try await stop(device) } catch {
        throw SimulatorError(
          "\(failure?.localizedDescription ?? "Profile applied.")\nCould not restore shutdown state: \(error.localizedDescription)"
        )
      }
    }
    if let failure { throw failure }
    return desired.isEmpty
      ? "Managed services restored and verified." : "Service profile applied and verified."
  }

  func ensure(_ device: RawDevice, desired: Set<String>) async throws {
    guard desired.isSubset(of: ServiceCatalog.slimmable),
      desired.isDisjoint(with: ServiceCatalog.compatibility)
    else {
      throw SimulatorError("Profile contains services that cannot be disabled.")
    }
    guard desired.isEmpty || ServiceCatalog.supportsPersistence(device.osVersion) else {
      throw SimulatorError(
        "Persistent slimming requires iOS 18.5 or newer. This simulator uses iOS \(device.osVersion)."
      )
    }
    try Task.checkCancellation()
    var isBooted = device.isBooted
    var current: Set<String> = []
    if isBooted {
      // simctl can report Booted before launchd is ready to answer queries.
      stage("Waiting for simulator readiness…", device)
      try await simctl(device, ["bootstatus", device.udid, "-b"], timeout: 600)
      try Task.checkCancellation()
      stage("Checking current service profile…", device)
      current = try await disabled(device, log: true)
      let delta = ServiceCatalog.delta(current: current, desired: desired)
      if delta.disable.isEmpty && delta.enable.isEmpty {
        stage("Service profile is already applied", device)
        return
      }
    }
    if ServiceCatalog.supportsPersistence(device.osVersion) {
      // A changed profile already requires a restart. Stop first so all overrides
      // can be merged at once, even when the user started with a booted device.
      if isBooted { try await stop(device) }
      try Task.checkCancellation()
      var wroteOverrides = false
      do {
        let start = ContinuousClock.now
        defer { timing("offline-override-write", start, device.udid) }
        stage("Applying service profile while shut down…", device)
        try await writeOverrides(device.udid, desired)
        wroteOverrides = true
      } catch {
        if error is CancellationError { throw error }
        stage("Offline changes unavailable; using service batches…", device)
        runner.report(.init(kind: .output, udid: device.udid, message: error.localizedDescription))
      }
      // Boot/read errors must surface, not trigger another blind boot and retry.
      try Task.checkCancellation()
      try await bootAndWait(device)
      isBooted = true
      stage("Verifying service state…", device)
      current = try await disabled(device, log: true)
      let remaining = ServiceCatalog.delta(current: current, desired: desired)
      if remaining.disable.isEmpty && remaining.enable.isEmpty { return }
      if wroteOverrides {
        stage("Runtime did not retain all offline changes; using service batches…", device)
      }
    } else if !isBooted {
      try await bootAndWait(device)
      current = try await disabled(device, log: true)
    }
    let delta = ServiceCatalog.delta(current: current, desired: desired)
    if delta.disable.isEmpty && delta.enable.isEmpty { return }
    try await applyServiceChanges(device, disable: delta.disable, enable: delta.enable)
    stage("Restarting to apply changes…", device)
    try await stop(device)
    try await bootAndWait(device)
    stage("Verifying service state…", device)
    let after = try await disabled(device, log: true)
    let remaining = ServiceCatalog.delta(current: after, desired: desired)
    guard remaining.disable.isEmpty && remaining.enable.isEmpty else {
      throw SimulatorError("Service changes did not survive the restart.")
    }
  }
}

enum DisabledStore {
  static func read(udid: String, root: URL = URL(fileURLWithPath: "/private/var/tmp")) throws
    -> Set<String>
  {
    let target = try url(udid: udid, root: root)
    guard FileManager.default.fileExists(atPath: target.path) else { return [] }
    guard
      let entries = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: target), format: nil) as? [String: Bool]
    else { throw SimulatorError("Unexpected launchd overrides format.") }
    return Set(entries.filter(\.value).map(\.key))
  }
  static func url(udid: String, root: URL = URL(fileURLWithPath: "/private/var/tmp")) throws -> URL
  {
    guard UUID(uuidString: udid) != nil else { throw SimulatorError("Invalid simulator UUID.") }
    return root.appendingPathComponent("com.apple.CoreSimulator.SimDevice.\(udid)/disabled.plist")
  }
  static func merge(
    udid: String, desired: Set<String>, root: URL = URL(fileURLWithPath: "/private/var/tmp")
  ) throws {
    let url = try url(udid: udid, root: root)
    var entries: [String: Bool] = [:]
    if FileManager.default.fileExists(atPath: url.path) {
      guard
        let stored = try PropertyListSerialization.propertyList(
          from: Data(contentsOf: url), format: nil) as? [String: Bool]
      else {
        throw SimulatorError("Unexpected launchd overrides format.")
      }
      entries = stored
    }
    let current = Set(entries.filter(\.value).map(\.key))
    let delta = ServiceCatalog.delta(current: current, desired: desired)
    for label in delta.disable { entries[label] = true }
    for label in delta.enable { entries[label] = false }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try PropertyListSerialization.data(
      fromPropertyList: entries, format: .xml, options: 0)
    try data.write(to: url, options: .atomic)
  }
}
