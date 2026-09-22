import Foundation

struct ServiceBackupExport {
  let udid: String
  let data: Data
}

/// A live, effective launchd state, not a copy of the private override plist.
/// Unmanaged labels are exported for context but are never restored by this app.
struct ServiceStateBackup: Codable, Sendable, Equatable {
  let version: Int
  let capturedAt: Date
  let udid: String
  let deviceSet: String
  let name: String
  let osVersion: String
  let bootState: String
  let disabled: Set<String>

  init(device: RawDevice, disabled: Set<String>) {
    version = 1
    capturedAt = Date()
    udid = device.udid
    deviceSet = device.set
    name = device.name
    osVersion = device.osVersion
    bootState = device.state
    self.disabled = disabled
  }

  func validate(for device: RawDevice) throws {
    guard version == 1, UUID(uuidString: udid) != nil, device.udid == udid,
      device.set == deviceSet, device.osVersion == osVersion,
      ["Booted", "Shutdown"].contains(bootState)
    else {
      throw SimulatorError("The saved state does not match this simulator, device set, or runtime.")
    }
  }

  func exportedData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(self)
  }
}

actor ServiceBackupStore {
  let directory: URL

  init(
    directory: URL = URL.applicationSupportDirectory.appendingPathComponent(
      "SwiftSimSlim/ServiceBackups")
  ) {
    self.directory = directory
  }

  private func url(_ udid: String) throws -> URL {
    guard UUID(uuidString: udid) != nil else { throw SimulatorError("Invalid backup UUID.") }
    return directory.appendingPathComponent(udid + ".json")
  }

  func save(_ backup: ServiceStateBackup) throws {
    let target = try url(backup.udid)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try backup.exportedData().write(to: target, options: .atomic)
  }

  func load(_ udid: String) throws -> ServiceStateBackup? {
    let target = try url(udid)
    guard FileManager.default.fileExists(atPath: target.path) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let backup = try decoder.decode(ServiceStateBackup.self, from: Data(contentsOf: target))
    guard backup.udid == udid, backup.version == 1,
      ["Booted", "Shutdown"].contains(backup.bootState)
    else {
      throw SimulatorError("Saved state has an unsupported format or a different simulator UUID.")
    }
    return backup
  }

  func remove(_ udid: String) throws {
    let target = try url(udid)
    if FileManager.default.fileExists(atPath: target.path) {
      try FileManager.default.removeItem(at: target)
    }
  }
}

struct ServiceChangePlan: Sendable, Identifiable {
  let id = UUID()
  let device: RawDevice
  let current: Set<String>
  let desired: Set<String>
  let isLive: Bool
  let capturedAt = Date()
  var disable: [String] { ServiceCatalog.delta(current: current, desired: desired).disable }
  var enable: [String] { ServiceCatalog.delta(current: current, desired: desired).enable }
}

extension SwiftSimSlimBackend {
  private func profileDevice(_ udid: String) async throws -> RawDevice {
    guard UUID(uuidString: udid) != nil else {
      throw SimulatorError("An exact simulator UUID is required.")
    }
    let matches = try await listRaw().filter { $0.udid == udid }
    guard matches.count == 1, let device = matches.first else {
      throw SimulatorError("Simulator must resolve uniquely in the configured device sets.")
    }
    return device
  }
  /// Never boots, shuts down, or changes a service. Offline data is provisional.
  func previewProfile(
    udid: String, desired: Set<String>,
    readOffline: @Sendable (String) throws -> Set<String> = { try DisabledStore.read(udid: $0) }
  ) async throws -> ServiceChangePlan {
    guard desired.isSubset(of: ServiceCatalog.slimmable) else {
      throw SimulatorError("Profile contains services that cannot be disabled.")
    }
    let device = try await profileDevice(udid)
    guard ["Booted", "Shutdown"].contains(device.state) else {
      throw SimulatorError("Wait for the simulator to finish changing state.")
    }
    guard desired.isEmpty || ServiceCatalog.supportsPersistence(device.osVersion) else {
      throw SimulatorError("Persistent slimming requires iOS 18.5 or newer.")
    }
    let current = device.isBooted ? try await disabled(device) : try readOffline(device.udid)
    return .init(device: device, current: current, desired: desired, isLive: device.isBooted)
  }

  /// Saving must succeed before any profile mutation. Shutdown devices are
  /// temporarily booted to capture launchd's actual state, then returned to Shutdown.
  func configureWithBackup(
    udid: String, desired: Set<String>, preserveBootState: Bool,
    expectedCurrent: Set<String>? = nil,
    save: @Sendable (ServiceStateBackup) async throws -> Void
  ) async throws {
    let start = ContinuousClock.now
    defer {
      timing("profile-total (capture, save, apply, boot, verification, recovery)", start, udid)
    }
    guard desired.isSubset(of: ServiceCatalog.slimmable) else {
      throw SimulatorError("Profile contains services that cannot be disabled.")
    }
    let device = try await profileDevice(udid)
    guard ["Booted", "Shutdown"].contains(device.state),
      desired.isEmpty || ServiceCatalog.supportsPersistence(device.osVersion)
    else { throw SimulatorError("The simulator state or runtime does not support this profile.") }
    do {
      stage("Capturing original service state…", device)
      if device.isBooted {
        try await simctl(device, ["bootstatus", device.udid, "-b"], timeout: 600)
      } else {
        try await bootAndWait(device)
      }
      try Task.checkCancellation()
      let original = try await disabled(device)
      if let expectedCurrent,
        original.intersection(ServiceCatalog.managed)
          != expectedCurrent.intersection(ServiceCatalog.managed)
      {
        throw SimulatorError("Service state changed since the preview. Review the changes again.")
      }
      let backup = ServiceStateBackup(device: device, disabled: original)
      let delta = ServiceCatalog.delta(current: original, desired: desired)
      if !delta.disable.isEmpty || !delta.enable.isEmpty {
        try await save(backup)
        runner.report(
          .init(
            kind: .output, udid: udid,
            message: "SAVED original service state at \(backup.capturedAt.ISO8601Format())"))
      }
      try Task.checkCancellation()
      // Resolve again because the capture may have booted this device.
      for label in delta.disable {
        runner.report(.init(kind: .output, udid: udid, message: "PLANNED disable \(label)"))
      }
      for label in delta.enable {
        runner.report(.init(kind: .output, udid: udid, message: "PLANNED enable \(label)"))
      }
      try await ensure(try await find(udid, set: device.set), desired: desired)
      for label in delta.disable {
        runner.report(.init(kind: .output, udid: udid, message: "VERIFIED disabled \(label)"))
      }
      for label in delta.enable {
        runner.report(.init(kind: .output, udid: udid, message: "VERIFIED enabled \(label)"))
      }
      if preserveBootState && !device.isBooted { try await stop(device) }
    } catch {
      let failure = error
      runner.report(
        .init(
          kind: .output, udid: udid,
          message:
            "FAILED profile operation: \(failure.localizedDescription). Service changes are not automatically rolled back; use Restore Saved State if a backup was saved."
        ))
      // Cancellation must not cancel the boot-state recovery itself.
      do {
        try await Task.detached {
          if !device.isBooted {
            try await stop(device)
          } else if !(try await find(udid, set: device.set)).isBooted {
            try await bootAndWait(device)
          }
        }.value
        runner.report(
          .init(
            kind: .output, udid: udid,
            message: "RESTORED original boot state: \(device.state); service state may be partial.")
        )
      } catch {
        throw SimulatorError(
          "\(failure.localizedDescription)\nBoot-state recovery also failed: \(error.localizedDescription)"
        )
      }
      throw failure
    }
  }

  func restoreSavedState(_ backup: ServiceStateBackup) async throws {
    let start = ContinuousClock.now
    defer { timing("saved-state-restore-total", start, backup.udid) }
    let device = try await profileDevice(backup.udid)
    try backup.validate(for: device)
    let desired = backup.disabled.intersection(ServiceCatalog.slimmable)
    do {
      try await ensure(device, desired: desired)
      if backup.bootState == "Shutdown" { try await stop(device) }
    } catch {
      let failure = error
      do {
        try await Task.detached {
          if backup.bootState == "Shutdown" {
            try await stop(device)
          } else if !(try await find(device.udid, set: device.set)).isBooted {
            try await bootAndWait(device)
          }
        }.value
      } catch {
        throw SimulatorError(
          "\(failure.localizedDescription)\nCould not restore saved boot state: \(error.localizedDescription)"
        )
      }
      throw failure
    }
    runner.report(
      .init(
        kind: .output, udid: backup.udid,
        message:
          "RESTORED and verified saved managed service state and \(backup.bootState) boot state. Required services enabled; unmanaged overrides preserved."
      ))
  }

  func timing(_ phase: String, _ start: ContinuousClock.Instant, _ udid: String) {
    runner.report(
      .init(kind: .output, udid: udid, message: "TIMING \(phase): \(start.duration(to: .now))"))
  }
}
