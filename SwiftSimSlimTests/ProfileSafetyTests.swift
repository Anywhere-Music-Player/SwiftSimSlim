import Foundation
import Testing

@testable import SwiftSimSlim

private func safetyBackend(_ fake: FakeSimulator) -> SwiftSimSlimBackend {
  SwiftSimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }),
    deviceSets: ["/synthetic-safety-set"],
    writeOverrides: { _, desired in
      let unmanaged = await fake.disabled.subtracting(ServiceCatalog.managed)
      await fake.writeOverrides(desired.union(unmanaged))
    })
}

@Test func dryRunIsReadOnlyAndRepairsCompatibilityInItsDiff() async throws {
  let fake = FakeSimulator()
  let backend = safetyBackend(fake)
  let labels = Array(ServiceCatalog.slimmable.sorted().prefix(2))
  let required = try #require(ServiceCatalog.compatibility.first)
  await fake.writeOverrides([labels[0], required, "unmanaged"])
  let plan = try await backend.previewProfile(udid: fake.udid, desired: [labels[1]])
  #expect(plan.isLive)
  #expect(plan.disable == [labels[1]])
  #expect(Set(plan.enable) == [labels[0], required])
  #expect(await fake.disabled == [labels[0], required, "unmanaged"])
  #expect(await fake.commands.allSatisfy { $0.contains("list") || $0.contains("print-disabled") })
  _ = try await backend.shutdown(udid: fake.udid)
  let count = await fake.commands.count
  let offline = try await backend.previewProfile(
    udid: fake.udid, desired: [labels[1]], readOffline: { _ in [labels[0]] })
  #expect(!offline.isLive)
  #expect(offline.enable == [labels[0]])
  #expect(await fake.commands.dropFirst(count).allSatisfy { $0.contains("list") })
  #expect(await fake.state == "Shutdown")
}

@Test func savedStateSurvivesStoreRecreationAndRestoresPartialProfile() async throws {
  let fake = FakeSimulator()
  let backend = safetyBackend(fake)
  let labels = Array(ServiceCatalog.slimmable.sorted().prefix(2))
  let required = try #require(ServiceCatalog.compatibility.first)
  await fake.writeOverrides([labels[0], required, "unmanaged"])
  _ = try await backend.shutdown(udid: fake.udid)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ServiceBackupStore(directory: root)
  try await backend.configureWithBackup(
    udid: fake.udid, desired: [labels[1]], preserveBootState: true,
    save: { try await store.save($0) })
  #expect(await fake.disabled == [labels[1], "unmanaged"])
  #expect(await fake.state == "Shutdown")
  let reopened = ServiceBackupStore(directory: root)
  let backup = try #require(try await reopened.load(fake.udid))
  #expect(backup.disabled == [labels[0], required, "unmanaged"])
  #expect(backup.bootState == "Shutdown")
  // A no-op must not replace the useful recovery point with the already slimmed state.
  try await backend.configureWithBackup(
    udid: fake.udid, desired: [labels[1]], preserveBootState: true,
    save: { _ in
      Issue.record("No-op replaced original backup")
    })
  try await backend.restoreSavedState(backup)
  #expect(await fake.disabled == [labels[0], "unmanaged"])
  #expect(await fake.state == "Shutdown")
  #expect(try await reopened.load(fake.udid) == backup)
  let json = try #require(
    try JSONSerialization.jsonObject(with: backup.exportedData()) as? [String: Any])
  #expect(json["deviceSet"] as? String == "/synthetic-safety-set")
  #expect(json["version"] as? Int == 1)
}

@Test func failedBackupAndStalePreviewStopBeforeServiceMutations() async throws {
  for booted in [true, false] {
    let fake = FakeSimulator()
    let backend = safetyBackend(fake)
    if !booted { _ = try await backend.shutdown(udid: fake.udid) }
    await #expect(throws: SimulatorError.self) {
      try await backend.configureWithBackup(
        udid: fake.udid, desired: ServiceCatalog.slimmable, preserveBootState: false,
        save: { _ in
          throw SimulatorError("Disk full")
        })
    }
    #expect(await fake.disabled.isEmpty)
    #expect(await fake.state == (booted ? "Booted" : "Shutdown"))
    #expect(await fake.commands.allSatisfy { !$0.contains("disable") && !$0.contains("enable") })
  }
  let fake = FakeSimulator()
  let backend = safetyBackend(fake)
  let label = try #require(ServiceCatalog.slimmable.first)
  await fake.writeOverrides([label])
  await #expect(throws: SimulatorError.self) {
    try await backend.configureWithBackup(
      udid: fake.udid, desired: [], preserveBootState: true, expectedCurrent: [],
      save: { _ in Issue.record("Saved stale preview") })
  }
  #expect(await fake.disabled == [label])
  #expect(
    await fake.commands.allSatisfy {
      $0.contains("list") || $0.contains("bootstatus") || $0.contains("print-disabled")
    })
}

@Test func cancellationDuringCaptureRestoresShutdownAndDoesNotMutateServices() async throws {
  let fake = FakeSimulator()
  let backend = safetyBackend(fake)
  _ = try await backend.shutdown(udid: fake.udid)
  await #expect(throws: CancellationError.self) {
    try await backend.configureWithBackup(
      udid: fake.udid, desired: ServiceCatalog.slimmable, preserveBootState: true,
      save: { _ in throw CancellationError() })
  }
  #expect(await fake.state == "Shutdown")
  #expect(await fake.disabled.isEmpty)
}

@Test func savedStateRejectsWrongRuntimeSetOrDeviceAndNeverDisablesRequiredServices() async throws {
  let fake = FakeSimulator()
  let backend = safetyBackend(fake)
  var device = try await backend.find(fake.udid)
  let backup = ServiceStateBackup(device: device, disabled: ServiceCatalog.compatibility)
  device.osVersion = "99.0"
  #expect(throws: SimulatorError.self) { try backup.validate(for: device) }
  device = try await backend.find(fake.udid)
  device.set = "/other-set"
  #expect(throws: SimulatorError.self) { try backup.validate(for: device) }
  device = RawDevice(
    udid: UUID().uuidString, name: "Other", state: "Booted", isAvailable: true, dataPath: nil)
  #expect(throws: SimulatorError.self) { try backup.validate(for: device) }
  try await backend.restoreSavedState(backup)
  #expect(await fake.disabled.isDisjoint(with: ServiceCatalog.compatibility))
  await #expect(throws: SimulatorError.self) {
    try await backend.previewProfile(udid: "all", desired: [])
  }
}

@Test func backupStoreRejectsAnotherDevicesSnapshotAndMalformedData() async throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let store = ServiceBackupStore(directory: root)
  let id = UUID().uuidString
  let other = RawDevice(
    udid: UUID().uuidString, name: "Other", state: "Booted", isAvailable: true, dataPath: nil)
  try await store.save(ServiceStateBackup(device: other, disabled: []))
  let target = root.appendingPathComponent(id + ".json")
  try FileManager.default.copyItem(
    at: root.appendingPathComponent(other.udid + ".json"), to: target)
  await #expect(throws: SimulatorError.self) { try await store.load(id) }
  try Data("invalid JSON".utf8).write(to: target)
  await #expect(throws: (any Error).self) { try await store.load(id) }
}
