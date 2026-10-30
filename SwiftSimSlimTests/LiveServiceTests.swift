import Foundation
import Testing

@testable import SwiftSimSlim

private let liveDisable = "com.apple.weatherd"
private let liveEnable = "com.apple.searchd"
private let liveRequired = "com.apple.sharingd"

private actor LiveFixture {
  let udid = "00000000-0000-0000-0000-000000000021"
  let runtime = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
  let root: String
  var booted = true
  var disabled: Set<String> = [liveEnable, liveRequired, "unmanaged"]
  var loaded: Set<String> = [liveDisable, "unmanaged"]
  var commands: [[String]] = []
  var saved: ServiceStateBackup?
  var ignoreBatch = false
  var refuseStart = false
  var refuseStop = false
  var cancelMutation = false
  var mutations = 0

  init(root: URL) { self.root = root.path }
  func options(
    booted: Bool = true, ignoreBatch: Bool = false, refuseStart: Bool = false,
    refuseStop: Bool = false, cancelMutation: Bool = false
  ) {
    self.booted = booted
    self.ignoreBatch = ignoreBatch
    self.refuseStart = refuseStart
    self.refuseStop = refuseStop
    self.cancelMutation = cancelMutation
  }
  func save(_ backup: ServiceStateBackup) { saved = backup }
  func execute(_ executable: String, _ args: [String]) throws -> CommandResult {
    commands.append(args)
    func result(_ text: String) -> CommandResult {
      .init(data: Data(text.utf8), errorData: Data(), status: 0)
    }
    if executable != "/usr/bin/xcrun" { return result("") }
    if args.contains("runtimes") {
      let data = try JSONSerialization.data(withJSONObject: [
        "runtimes": [["identifier": runtime, "runtimeRoot": root]]
      ])
      return .init(data: data, errorData: Data(), status: 0)
    }
    if args.contains("devices") {
      let data = try JSONSerialization.data(withJSONObject: [
        "devices": [
          runtime: [
            [
              "udid": udid, "name": "Live fixture", "state": booted ? "Booted" : "Shutdown",
              "isAvailable": true,
            ]
          ]
        ]
      ])
      return .init(data: data, errorData: Data(), status: 0)
    }
    if args.contains("bootstatus") { return result("") }
    if args.contains("shutdown") {
      booted = false
      return result("")
    }
    if args.contains("boot") {
      booted = true
      loaded = Set([liveEnable, liveDisable, liveRequired]).subtracting(disabled).union([
        "unmanaged"
      ])
      return result("")
    }
    guard let index = args.firstIndex(of: "launchctl"), args.count > index + 1 else {
      throw SimulatorError("Unexpected lifecycle command: \(args)")
    }
    let verb = args[index + 1]
    if verb == "print-disabled" {
      return result(
        "disabled services = {\n"
          + disabled.sorted().map { "\"\($0)\" => disabled" }.joined(separator: "\n") + "\n}")
    }
    if verb == "list" {
      return result(
        "PID Status Label\n" + loaded.sorted().map { "- 0 \($0)" }.joined(separator: "\n"))
    }
    #expect(saved != nil, "No service mutation may precede the backup")
    mutations += 1
    if cancelMutation { throw CancellationError() }
    switch verb {
    case "load", "unload":
      if !ignoreBatch {
        for path in args.dropFirst(index + 3) {
          let label = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
          if verb == "load" {
            disabled.remove(label)
            if !(refuseStart && label == liveEnable) { loaded.insert(label) }
          } else {
            disabled.insert(label)
            if !refuseStop { loaded.remove(label) }
          }
        }
      }
    case "enable": disabled.remove(String(args.last!.dropFirst("system/".count)))
    case "disable": disabled.insert(String(args.last!.dropFirst("system/".count)))
    case "bootout": if !refuseStop { loaded.remove(String(args.last!.dropFirst("system/".count))) }
    case "bootstrap":
      let label = URL(fileURLWithPath: args.last!).deletingPathExtension().lastPathComponent
      if !(refuseStart && label == liveEnable) { loaded.insert(label) }
    default: throw SimulatorError("Unexpected live command")
    }
    return result("")
  }
}

private func liveFixture() throws -> (Fixture, LiveFixture, SwiftSimSlimBackend) {
  let fixture = try Fixture()
  do {
    let root = try fixture.directory("runtime").resolvingSymlinksInPath()
    for label in [liveEnable, liveDisable, liveRequired] {
      let path = try fixture.file("runtime/System/Library/LaunchDaemons/" + label + ".plist")
      try PropertyListSerialization.data(
        fromPropertyList: ["Label": label], format: .binary, options: 0
      ).write(to: path)
    }
    let fake = LiveFixture(root: root)
    let backend = SwiftSimSlimBackend(
      runner: CommandRunner(executor: { try await fake.execute($0, $1) }),
      deviceSets: ["/synthetic-live-set"])
    return (fixture, fake, backend)
  } catch {
    fixture.remove()
    throw error
  }
}

@Test(arguments: [false, true])
private func liveProfileVerifiesBatchesAndFallbackWithoutRestart(_ fallback: Bool) async throws {
  let (fixture, fake, backend) = try liveFixture()
  defer { fixture.remove() }
  await fake.options(ignoreBatch: fallback)
  let result = try await backend.configureLiveWithBackup(
    udid: fake.udid, desired: [liveDisable], save: { await fake.save($0) })
  #expect(result.restartRequired.isEmpty)
  #expect(await fake.disabled == [liveDisable, "unmanaged"])
  #expect(await fake.loaded == [liveEnable, liveRequired, "unmanaged"])
  #expect(await fake.saved?.disabled == [liveEnable, liveRequired, "unmanaged"])
  let commands = await fake.commands
  #expect(!commands.contains { $0.contains("boot") || $0.contains("shutdown") })
  #expect(
    commands.filter { $0.contains("spawn") }.allSatisfy {
      $0.prefix(5) == ["simctl", "--set", "/synthetic-live-set", "spawn", fake.udid]
    })
  if fallback { #expect(commands.contains { $0.contains("bootstrap") }) }
  let mutations = await fake.mutations
  _ = try await backend.configureLiveWithBackup(
    udid: fake.udid, desired: [liveDisable], save: { _ in Issue.record("No-op replaced backup") })
  #expect(await fake.mutations == mutations)
}

@Test private func liveProfileReportsEnabledButUnloadedJobs() async throws {
  let (fixture, fake, backend) = try liveFixture()
  defer { fixture.remove() }
  await fake.options(refuseStart: true)
  let result = try await backend.configureLiveWithBackup(
    udid: fake.udid, desired: [liveDisable], save: { await fake.save($0) })
  #expect(result.restartRequired == [liveEnable])
  #expect(await fake.disabled == [liveDisable, "unmanaged"])
}

@Test(arguments: ["stopped", "stale", "save", "unsafe", "ambiguous", "cancel", "stop-failed"])
private func liveProfileGuardsAndFailures(_ scenario: String) async throws {
  let (fixture, fake, base) = try liveFixture()
  defer { fixture.remove() }
  await fake.options(
    booted: scenario != "stopped", refuseStop: scenario == "stop-failed",
    cancelMutation: scenario == "cancel")
  let backend =
    scenario == "ambiguous"
    ? SwiftSimSlimBackend(runner: base.runner, deviceSets: ["set-a", "set-b"]) : base
  do {
    _ = try await backend.configureLiveWithBackup(
      udid: fake.udid,
      desired: scenario == "unsafe" ? [liveRequired] : [liveDisable],
      expectedCurrent: scenario == "stale" ? [] : nil,
      save: {
        if scenario == "save" { throw SimulatorError("Disk full") }
        await fake.save($0)
      })
    Issue.record("Expected failure for \(scenario)")
  } catch {
    if scenario == "cancel" { #expect(error is CancellationError) }
  }
  if !["cancel", "stop-failed"].contains(scenario) { #expect(await fake.mutations == 0) }
  #expect(await fake.commands.allSatisfy { !$0.contains("boot") && !$0.contains("shutdown") })
}

@Test func liveJobValidationRejectsWrongLabelsAndSymlinkEscapes() throws {
  let fixture = try Fixture()
  defer { fixture.remove() }
  let root = try fixture.directory("runtime").resolvingSymlinksInPath()
  let path = try fixture.file("runtime/System/Library/LaunchDaemons/" + liveEnable + ".plist")
  try PropertyListSerialization.data(
    fromPropertyList: ["Label": "unmanaged"], format: .xml, options: 0
  ).write(to: path)
  #expect(throws: SimulatorError.self) {
    try LiveServiceJobs.paths(root: root, labels: [liveEnable])
  }
  let outside = try fixture.file("outside.plist")
  try FileManager.default.removeItem(at: path)
  try FileManager.default.createSymbolicLink(at: path, withDestinationURL: outside)
  #expect(throws: SimulatorError.self) {
    try LiveServiceJobs.paths(root: root, labels: [liveEnable])
  }
  #expect(throws: SimulatorError.self) {
    try LiveServiceJobs.paths(root: root, labels: ["unmanaged"])
  }
  #expect(
    try LiveServiceJobs.loadedLabels("PID\tStatus\tLabel\n-\t0\tcom.apple.searchd") == [liveEnable])
  #expect(throws: SimulatorError.self) { try LiveServiceJobs.loadedLabels("") }
  #expect(throws: SimulatorError.self) {
    try LiveServiceJobs.loadedLabels("PID Status Label\ntruncated")
  }
}

@Test @MainActor private func liveProfileModelPublishesRestartRequirement() async throws {
  let (fixture, fake, backend) = try liveFixture()
  defer { fixture.remove() }
  await fake.options(refuseStart: true)
  let defaultsName = "SwiftSimSlim-live-test-" + UUID().uuidString
  let defaults = try #require(UserDefaults(suiteName: defaultsName))
  defer { defaults.removePersistentDomain(forName: defaultsName) }
  let model = AppModel(
    deviceSets: backend.deviceSets,
    runner: CommandRunner(executor: { executable, args in
      // AppModel persists the real backup to the fixture store before its first mutation.
      if args.contains("load") || args.contains("unload") {
        let store = ServiceBackupStore(directory: fixture.root.appendingPathComponent("backups"))
        if let backup = try await store.load(fake.udid) { await fake.save(backup) }
      }
      return try await fake.execute(executable, args)
    }), defaults: defaults, automaticallyMeasureDisk: false,
    backupStore: ServiceBackupStore(directory: fixture.root.appendingPathComponent("backups")))
  await model.load()
  let device = try #require(model.devices.first)
  var profile = try ServiceProfileSnapshot(
    categories: [], labels: ServiceCatalog.slimmable.subtracting([liveDisable]),
    preserveBootState: true)
  profile.withoutRestart = true
  let plan = try await backend.previewProfile(udid: fake.udid, desired: [liveDisable])
  await model.applyReviewedProfile(profile, plans: [plan], to: [device])
  #expect(model.serviceRestartRequired[device.udid] == [liveEnable])
  #expect(model.operations.entries.isEmpty)
  #expect(model.activity.allSatisfy { $0.level != .failure })
  #expect(await fake.commands.allSatisfy { !$0.contains("boot") && !$0.contains("shutdown") })
  await model.restartSimulator(device)
  #expect(model.serviceRestartRequired[device.udid]?.isEmpty == true)
  #expect(await fake.commands.filter { $0.contains("shutdown") }.count == 1)
  #expect(await fake.commands.filter { $0.contains("boot") }.count == 1)
  #expect(model.operations.entries.isEmpty)
  #expect(model.activity.allSatisfy { $0.level != .failure })
}
