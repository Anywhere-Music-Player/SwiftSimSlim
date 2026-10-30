import Foundation

struct LiveServiceResult: Sendable {
  let restartRequired: [String]
}

/// Only exact allowlisted labels and matching runtime job plists may be used.
enum LiveServiceJobs {
  static func loadedLabels(_ text: String) throws -> Set<String> {
    let rows = text.split(whereSeparator: \.isNewline).map {
      $0.split(whereSeparator: \.isWhitespace).map(String.init)
    }
    guard rows.first == ["PID", "Status", "Label"] else {
      throw SimulatorError("CoreSimulator returned an incomplete loaded-service list.")
    }
    var labels: Set<String> = []
    for row in rows.dropFirst() {
      guard row.count == 3, row[0] == "-" || Int(row[0]) != nil, Int(row[1]) != nil else {
        throw SimulatorError("CoreSimulator returned an invalid loaded-service row.")
      }
      labels.insert(row[2])
    }
    return labels
  }

  static func paths(root: URL, labels: Set<String>) throws -> [String: String] {
    guard labels.isSubset(of: ServiceCatalog.managed) else {
      throw SimulatorError("Unmanaged runtime job requested.")
    }
    try DiskStore.requireDirectory(root)
    var result: [String: String] = [:]
    for label in labels.sorted() {
      try Task.checkCancellation()
      for directory in ["System/Library/LaunchDaemons", "System/Library/LaunchAgents"] {
        let path = root.appendingPathComponent(directory).appendingPathComponent(label + ".plist")
        guard DiskStore.exists(path) else { continue }
        try DiskStore.requireDescendant(root, path)
        guard DiskStore.isRegular(try DiskStore.info(path)),
          let plist = try PropertyListSerialization.propertyList(
            from: Data(contentsOf: path), format: nil) as? [String: Any],
          plist["Label"] as? String == label
        else { throw SimulatorError("Runtime job does not match its managed label: \(label)") }
        result[label] = path.path
        break
      }
    }
    return result
  }
}

extension SwiftSimSlimBackend {
  func loadedServices(_ device: RawDevice) async throws -> Set<String> {
    let output = try await readLaunchd(device, arguments: ["list"], log: true)
    return try LiveServiceJobs.loadedLabels(output.text)
  }

  private func liveJobPaths(_ device: RawDevice) async throws -> [String: String] {
    struct Runtime: Decodable {
      let identifier: String
      let runtimeRoot: String?
    }
    struct Response: Decodable { let runtimes: [Runtime] }
    let output = try await runner.run("/usr/bin/xcrun", ["simctl", "list", "runtimes", "-j"])
      .checked()
    let runtimes = try JSONDecoder().decode(Response.self, from: output.data).runtimes
      .filter { $0.identifier == device.runtimeID }
    guard runtimes.count == 1, let path = runtimes.first?.runtimeRoot, path.hasPrefix("/") else {
      throw SimulatorError("Cannot resolve this simulator's runtime jobs. Use the restart mode.")
    }
    return try await Task.detached(priority: .utility) {
      try LiveServiceJobs.paths(
        root: URL(fileURLWithPath: path).resolvingSymlinksInPath(), labels: ServiceCatalog.managed)
    }.value
  }

  /// A failed launchctl transition is evidence to log, not proof of final state.
  /// Readback below decides success, including commands that exit zero without acting.
  private func liveCommand(_ device: RawDevice, _ arguments: [String]) async throws {
    try Task.checkCancellation()
    do {
      try await simctl(device, ["spawn", device.udid, "launchctl"] + arguments)
    } catch {
      if error is CancellationError { throw error }
      runner.report(
        .init(
          kind: .output, udid: device.udid,
          message: "Live transition needs verification: \(error.localizedDescription)"))
    }
  }

  private func batchJobs(_ device: RawDevice, verb: String, paths: [String]) async throws {
    for start in stride(from: 0, to: paths.count, by: 64) {
      stage(
        "\(verb == "load" ? "Loading" : "Stopping") runtime jobs · \(min(start + 64, paths.count))/\(paths.count)…",
        device)
      try await liveCommand(
        device, [verb, "-w"] + Array(paths[start..<min(start + 64, paths.count)]))
    }
  }

  private func finishLiveJobs(
    _ device: RawDevice, stop: Set<String>, start: Set<String>, paths: [String: String]
  ) async throws {
    let jobs =
      stop.sorted().map { ["bootout", "system/" + $0] }
      + start.sorted().compactMap { label in paths[label].map { ["bootstrap", "system", $0] } }
    // A fixed worker count also bounds task allocation for a full profile.
    try await withThrowingTaskGroup(of: Void.self) { group in
      for worker in 0..<min(ServiceBatch.concurrency, jobs.count) {
        group.addTask {
          for index in stride(from: worker, to: jobs.count, by: ServiceBatch.concurrency) {
            try await liveCommand(device, jobs[index])
          }
        }
      }
      try await group.waitForAll()
    }
  }

  func configureLiveWithBackup(
    udid: String, desired: Set<String>, expectedCurrent: Set<String>? = nil,
    save: @Sendable (ServiceStateBackup) async throws -> Void
  ) async throws -> LiveServiceResult {
    let started = ContinuousClock.now
    defer { timing("live-profile-total (no reboot)", started, udid) }
    guard desired.isSubset(of: ServiceCatalog.slimmable) else {
      throw SimulatorError("Profile contains services that cannot be disabled.")
    }
    let device = try await profileDevice(udid)
    guard device.isBooted else {
      throw SimulatorError(
        "Without restart requires an already booted simulator. Refresh the preview.")
    }
    // Keep the same supported-runtime boundary as the existing profile editor.
    guard desired.isEmpty || ServiceCatalog.supportsPersistence(device.osVersion) else {
      throw SimulatorError("This runtime does not support the selected profile.")
    }
    try await simctl(device, ["bootstatus", device.udid, "-b"], timeout: 600)
    let original = try await disabled(device, log: true)
    if let expectedCurrent,
      original.intersection(ServiceCatalog.managed)
        != expectedCurrent.intersection(ServiceCatalog.managed)
    {
      throw SimulatorError("Service state changed since the preview. Review the changes again.")
    }
    let loaded = try await loadedServices(device)
    let paths = try await liveJobPaths(device)
    let enabled = ServiceCatalog.managed.subtracting(desired)
    let toStop = desired.subtracting(original).union(desired.intersection(loaded))
    let toStart = enabled.intersection(original).union(
      enabled.intersection(Set(paths.keys)).subtracting(loaded))
    guard !toStop.isEmpty || !toStart.isEmpty else { return .init(restartRequired: []) }
    try Task.checkCancellation()
    try await save(ServiceStateBackup(device: device, disabled: original))
    runner.report(
      .init(kind: .output, udid: udid, message: "SAVED original service state before live changes.")
    )
    try Task.checkCancellation()
    let beforeMutation = try await profileDevice(udid)
    guard beforeMutation.isBooted, beforeMutation.set == device.set,
      beforeMutation.runtimeID == device.runtimeID
    else {
      throw SimulatorError("Simulator stopped before live changes. No services were changed.")
    }
    do {
      stage("Applying services without restarting…", device)
      // Enable first so dependencies needed by the new profile are restored before stopping others.
      try await batchJobs(device, verb: "load", paths: toStart.sorted().compactMap { paths[$0] })
      try await batchJobs(device, verb: "unload", paths: toStop.sorted().compactMap { paths[$0] })
      let afterBatch = try await disabled(device, log: true)
      let delta = ServiceCatalog.delta(current: afterBatch, desired: desired)
      try await applyServiceChanges(device, disable: delta.disable, enable: delta.enable)
      let loadedAfterBatch = try await loadedServices(device)
      stage("Finishing live service transitions…", device)
      try await finishLiveJobs(
        device, stop: desired.intersection(loadedAfterBatch),
        start: toStart.subtracting(loadedAfterBatch), paths: paths)
      stage("Verifying live service state…", device)
      let final = try await disabled(device, log: true)
      let finalLoaded = try await loadedServices(device)
      guard final.intersection(ServiceCatalog.managed) == desired,
        final.subtracting(ServiceCatalog.managed) == original.subtracting(ServiceCatalog.managed),
        desired.isDisjoint(with: finalLoaded)
      else {
        throw SimulatorError(
          "Live service verification failed. Some changes may have applied; review Activity or restore saved state."
        )
      }
      let currentDevice = try await profileDevice(udid)
      guard currentDevice.isBooted, currentDevice.set == device.set,
        currentDevice.runtimeID == device.runtimeID
      else {
        throw SimulatorError("Simulator state changed during live verification.")
      }
      let pending = toStart.intersection(Set(paths.keys)).subtracting(finalLoaded).sorted()
      runner.report(
        .init(
          kind: .output, udid: udid,
          message: pending.isEmpty
            ? "VERIFIED live profile without restart."
            : "VERIFIED overrides; restart needed to load: " + pending.joined(separator: ", ")))
      return .init(restartRequired: pending)
    } catch {
      runner.report(
        .init(
          kind: .output, udid: udid,
          message:
            "FAILED live profile: \(error.localizedDescription). No automatic reboot or rollback; Restore Saved State remains available."
        ))
      throw error
    }
  }
}
