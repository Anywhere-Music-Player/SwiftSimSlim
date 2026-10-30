import Foundation
import Testing

@testable import SwiftSimSlim

@Test func fullSlimCleanupPreservesDataAndOrdersMutations() async throws {
  for scenario in ["booted", "shutdown", "leave-shutdown", "backup-failure", "cancel"] {
    try await checkFullSlimCleanup(scenario)
  }
}

private func checkFullSlimCleanup(_ scenario: String) async throws {
  let files = try Fixture()
  defer { files.remove() }
  let data = try files.directory("data").resolvingSymlinksInPath()
  let cache = try files.file("data/Library/Caches/disposable")
  let speech = try files.file(
    "data/private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_UAF_Siri_TextToSpeech/model")
  let protected = try [
    "Containers/Bundle/Application/A/App.app/binary",
    "Containers/Data/Application/A/Documents/document",
    "Containers/Data/Application/A/Library/Preferences/settings.plist",
    "Containers/Data/Application/A/Library/Application Support/database",
    "Media/DCIM/photo", "private/var/MobileAsset/AssetsV2/unknown/model",
  ].map { try files.file("data/" + $0) }
  let fake = FakeSimulator(dataPath: data.path)
  let set = "/synthetic-full-slim-clean"
  let backend = SwiftSimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }), deviceSets: [set],
    writeOverrides: { _, desired in
      #expect(DiskStore.exists(cache), "Profile must be applied before cleanup")
      let unmanaged = await fake.disabled.subtracting(ServiceCatalog.managed)
      await fake.writeOverrides(desired.union(unmanaged))
    })
  await fake.writeOverrides(["unmanaged", "com.apple.assistantd"])
  if scenario == "shutdown" { _ = try await backend.shutdown(udid: fake.udid) }
  let store = ServiceBackupStore(directory: files.root.appendingPathComponent("backups"))
  do {
    let result = try await backend.fullSlimAndClean(
      udid: fake.udid, preserveBootState: scenario != "leave-shutdown",
      save: { backup in
        #expect(DiskStore.exists(cache) && DiskStore.exists(speech))
        if scenario == "backup-failure" { throw SimulatorError("Disk full") }
        if scenario == "cancel" { throw CancellationError() }
        try await store.save(backup)
      })
    #expect(scenario != "backup-failure" && scenario != "cancel")
    #expect(!DiskStore.exists(cache) && !DiskStore.exists(speech))
    #expect(result.reclaimedBytes > 0)
    #expect(Set(result.categoryIds) == Set(DiskStore.categories.filter(\.canClean).map(\.id)))
    #expect(await fake.disabled == ServiceCatalog.slimmable.union(["unmanaged"]))
    #expect(await fake.state == (scenario == "booted" ? "Booted" : "Shutdown"))
    #expect(try await store.load(fake.udid)?.disabled == ["unmanaged", "com.apple.assistantd"])
  } catch {
    #expect(scenario == "backup-failure" || scenario == "cancel")
    #expect(DiskStore.exists(cache) && DiskStore.exists(speech))
    #expect(await fake.disabled == ["unmanaged", "com.apple.assistantd"])
    #expect(await fake.state == "Booted")
  }
  for file in protected { #expect(DiskStore.exists(file)) }
  let commands = await fake.commands
  #expect(!commands.contains { $0.contains("erase") || $0.contains("delete") })
  #expect(commands.allSatisfy { $0.prefix(3) == ["simctl", "--set", set] })
}
