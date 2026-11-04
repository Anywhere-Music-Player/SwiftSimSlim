import Foundation
import Testing

@testable import SwiftSimSlim

private let wallpaperVersion =
  "Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/com.apple.MercuryPoster/configurations/00000000-0000-0000-0000-000000000001/versions/0"
private let wallpaperTexture = "RuntimeSnapshot-" + String(repeating: "a", count: 64) + "-home.atx"

@Test func wallpaperRuntimeSnapshotsAreCleanableWithoutDeletingOriginalsOrApps() async throws {
  let files = try Fixture()
  defer { files.remove() }
  let root = try files.directory("data").resolvingSymlinksInPath()
  let texture = try files.file("data/" + wallpaperVersion + "/" + wallpaperTexture)
  let cache = try files.file(
    "data/" + wallpaperVersion + "/scratch/SnapshotCache.cachedb/cache.db")
  let keep = try [
    wallpaperVersion + "/contents/original.HEIC",
    wallpaperVersion + "/contents/" + wallpaperTexture,
    wallpaperVersion + "/configuration.plist",
    wallpaperVersion + "/RuntimeSnapshot-unknown-home.atx",
    "Library/Application Support/PRBPosterExtensionDataStore/unknown/" + wallpaperTexture,
    "Containers/Bundle/Application/A/App.app/" + wallpaperTexture,
    "Containers/Data/Application/A/Documents/" + wallpaperTexture,
    "Containers/Data/Application/A/Library/Preferences/settings.plist",
    "Containers/Data/Application/A/Library/Application Support/database",
    "Containers/Shared/AppGroup/A/Documents/document",
    "Media/DCIM/photo",
  ].map { try files.file("data/" + $0, text: "durable content") }
  let fake = FakeSimulator(dataPath: root.path)
  let backend = SwiftSimSlimBackend(
    runner: CommandRunner(executor: { executable, arguments in
      if arguments.contains("shutdown") {
        #expect(DiskStore.exists(texture) && DiskStore.exists(cache))
      }
      if arguments.contains("boot") {
        #expect(!DiskStore.exists(texture) && !DiskStore.exists(cache))
      }
      return try await fake.execute(executable, arguments)
    }), deviceSets: ["/synthetic-wallpaper-cleanup"])
  let plan = try await backend.diskCleanupPlan(udid: fake.udid)
  #expect(plan.categories.first { $0.id == "wallpaper-cache" }?.targets == 2)
  let expected =
    try DiskStore.allocatedSize(texture)
    + DiskStore.allocatedSize(cache.deletingLastPathComponent())
  #expect(plan.bytes(for: "wallpaper-cache") == expected)
  #expect(plan.totalBytes == plan.cleanableBytes + plan.storage.reduce(0) { $0 + $1.bytes })
  let result = try await backend.cleanDisk(
    udid: fake.udid, categoryIDs: ["wallpaper-cache"], preserveBootState: true)
  #expect(result.beforeBytes == expected && result.reclaimedBytes > 0)
  #expect(result.categoryIds == ["wallpaper-cache"])
  #expect(!DiskStore.exists(texture) && !DiskStore.exists(cache))
  for file in keep { #expect(try String(contentsOf: file, encoding: .utf8) == "durable content") }
  #expect(await fake.state == "Booted")
  let commands = await fake.commands
  #expect(
    commands.allSatisfy { $0.prefix(3) == ["simctl", "--set", "/synthetic-wallpaper-cleanup"] })
  #expect(!commands.contains { $0.contains("erase") || $0.contains("delete") })
}

@Test func wallpaperCleanupRejectsRedirectsAndUnknownFiles() throws {
  let files = try Fixture()
  defer { files.remove() }
  let root = try files.directory("data").resolvingSymlinksInPath()
  let target = try files.file("data/" + wallpaperVersion + "/" + wallpaperTexture)
  let original = try files.file("data/" + wallpaperVersion + "/contents/original.HEIC")
  #expect(throws: SimulatorError.self) { try DiskStore.clear(root, target: original) }
  // Replace a previously analyzed file with a link to an app document.
  let document = try files.file("data/Containers/Data/Application/A/Documents/document")
  try FileManager.default.removeItem(at: target)
  try FileManager.default.createSymbolicLink(at: target, withDestinationURL: document)
  #expect(try DiskStore.targets(root, category: "wallpaper-cache").isEmpty)
  #expect(throws: SimulatorError.self) { try DiskStore.clear(root, target: target) }
  #expect(DiskStore.exists(document) && DiskStore.exists(original))

  // An intermediate symlink must not redirect a recognized path into app data either.
  let support = root.appendingPathComponent("Library/Application Support")
  let moved = root.appendingPathComponent("Containers/Data/Application/A/Documents/support")
  try FileManager.default.moveItem(at: support, to: moved)
  try FileManager.default.createSymbolicLink(at: support, withDestinationURL: moved)
  #expect(throws: SimulatorError.self) { try DiskStore.targets(root, category: "wallpaper-cache") }
  #expect(throws: SimulatorError.self) { try DiskStore.clear(root, target: target) }
  #expect(DiskStore.exists(document))
}
