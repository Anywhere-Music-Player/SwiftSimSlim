import Foundation
import Testing

@testable import SwiftSimSlim

private actor LaunchdReadFixture {
  enum Failure: Sendable { case status124, wrapped124, tearingDown, timeout, permanent, malformed }
  let failure: Failure
  let failures: Int
  var commands: [[String]] = []

  init(_ failure: Failure, failures: Int = 1) {
    self.failure = failure
    self.failures = failures
  }

  func execute(_ executable: String, _ args: [String]) throws -> CommandResult {
    commands.append(args)
    if commands.count > failures {
      return .init(
        data: Data("disabled services = {\n\"com.apple.searchd\" => disabled\n}".utf8),
        errorData: Data(), status: 0)
    }
    switch failure {
    case .timeout: throw SimulatorError("Fixture read timeout", isTimeout: true)
    case .status124: return .init(data: Data(), errorData: Data(), status: 124)
    case .wrapped124:
      return .init(data: Data(), errorData: Data("LaunchdSimError code=124".utf8), status: 1)
    case .tearingDown:
      return .init(data: Data("Domain is tearing down".utf8), errorData: Data(), status: 1)
    case .permanent:
      return .init(data: Data(), errorData: Data("Permission denied".utf8), status: 1)
    case .malformed:
      return .init(data: Data("disabled services = {".utf8), errorData: Data(), status: 0)
    }
  }
}

private let launchdReadDevice = RawDevice(
  udid: "00000000-0000-0000-0000-000000000001", name: "Fixture", state: "Booted",
  isAvailable: true, dataPath: nil, set: "/tmp/launchd-read-fixture", osVersion: "27.0")

@Test(arguments: [
  LaunchdReadFixture.Failure.status124, .wrapped124, .tearingDown, .timeout,
])
private func launchdReadRecoversOnlyTransientFailures(_ failure: LaunchdReadFixture.Failure)
  async throws
{
  let fake = LaunchdReadFixture(failure, failures: 2)
  let backend = SwiftSimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }))
  let disabled = try await backend.disabled(launchdReadDevice, retryDelays: [.zero, .zero])
  #expect(disabled == ["com.apple.searchd"])
  let commands = await fake.commands
  #expect(commands.count == 3)
  #expect(
    commands.allSatisfy {
      $0 == [
        "simctl", "--set", launchdReadDevice.set, "spawn", launchdReadDevice.udid,
        "launchctl", "print-disabled", "system",
      ]
    })
}

@Test(arguments: [LaunchdReadFixture.Failure.status124, .timeout, .permanent, .malformed])
private func launchdReadBoundsRetriesAndRejectsInvalidState(_ failure: LaunchdReadFixture.Failure)
  async throws
{
  let fake = LaunchdReadFixture(failure, failures: 10)
  let backend = SwiftSimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }))
  await #expect(throws: SimulatorError.self) {
    try await backend.disabled(launchdReadDevice, retryDelays: [.zero, .zero])
  }
  let expected = failure == .status124 || failure == .timeout ? 3 : 1
  #expect(await fake.commands.count == expected)
}

@Test private func launchdReadCancellationStopsBackoff() async throws {
  let fake = LaunchdReadFixture(.status124, failures: 10)
  let backend = SwiftSimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }))
  let task = Task {
    try await backend.disabled(launchdReadDevice, retryDelays: [.seconds(60)])
  }
  while await fake.commands.isEmpty { await Task.yield() }
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(await fake.commands.count == 1)
}

@Test(arguments: [("caches", "Caches"), ("logs", "Logs"), ("temporary", "tmp")])
func diskCleanupPreservesPackagedResources(_ category: String, _ directory: String) throws {
  let fixture = try Fixture()
  defer { fixture.remove() }
  // Use a canonical fixture root: macOS exposes its temp directory through /var -> /private/var.
  let data = try fixture.directory("data").resolvingSymlinksInPath()
  let bundle = "data/Containers/Bundle/Application/APP/Example.app"
  var resources: [URL] = []
  for path in [
    bundle, bundle + "/PlugIns/Example.appex", bundle + "/Frameworks/Example.framework",
    "data/Containers/Bundle/OtherResources",
  ] {
    resources.append(try fixture.file(path + "/" + directory + "/keep.bin"))
  }
  _ = try fixture.directory("data/Containers/Data/Application/DATA/Documents")
  let relative = category == "temporary" ? "tmp" : "Library/" + directory
  let disposable = try fixture.file("data/Containers/Data/Application/DATA/" + relative + "/remove")
  let cleanup = disposable.deletingLastPathComponent()
  let plan = try DiskStore.plan(udid: launchdReadDevice.udid, root: data)
  #expect(plan.cleanableBytes == (try DiskStore.allocatedSize(cleanup)))
  #expect(plan.categories.first { $0.id == category }?.targets == 1)
  #expect(
    plan.storage.first { $0.id == "installed-apps" }?.bytes
      == (try DiskStore.allocatedSize(data.appendingPathComponent("Containers/Bundle/Application")))
  )
  for target in try DiskStore.targets(data, category: category) {
    try DiskStore.clear(data, target: target)
  }
  for resource in resources { #expect(DiskStore.exists(resource)) }
  #expect(!DiskStore.exists(disposable))
  try DiskStore.requireDirectory(cleanup)
}

@Test func diskBreakdownAccountsForAllStorageWithoutOverlap() throws {
  let fixture = try Fixture()
  defer { fixture.remove() }
  let root = try fixture.directory("data").resolvingSymlinksInPath()
  let regions = [
    ("installed-apps", "Containers/Bundle/Application/A/Demo.app"),
    ("documents", "Containers/Data/Application/A/Documents"),
    ("app-data", "Containers/Shared/AppGroup/G/Library"),
    ("user-media", "Media"),
    ("wallpapers", "Library/Application Support/PRBPosterExtensionDataStore"),
    ("system-assets", "private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_Unrelated"),
  ]
  for (_, path) in regions { _ = try fixture.file("data/" + path + "/keep") }
  _ = try fixture.file(
    "data/private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_UAF_Siri_Understanding/model")
  _ = try fixture.file("data/Containers/Data/PluginKitPlugin/P/Library/extension.db")
  _ = try fixture.file("data/Library/IntelligencePlatform/index.db")
  _ = try fixture.file("data/Containers/Data/Application/A/Library/Caches/disposable")
  _ = try fixture.file(
    "data/private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_LinguisticData/model")
  // Nested log directories must not count a cache twice, and symlinks must not add external data.
  _ = try fixture.file("data/Library/Logs/Caches/disposable")
  let outside = try fixture.file("outside/large", text: String(repeating: "x", count: 100_000))
  try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent("external"),
    withDestinationURL: outside.deletingLastPathComponent())
  let plan = try DiskStore.plan(udid: launchdReadDevice.udid, root: root)
  #expect(plan.totalBytes == (try DiskStore.allocatedSize(root)))
  #expect(plan.totalBytes == plan.cleanableBytes + plan.storage.reduce(0) { $0 + $1.bytes })
  for (id, path) in regions {
    #expect(
      plan.storageBytes(for: id) >= (try DiskStore.allocatedSize(root.appendingPathComponent(path)))
    )
  }
  #expect(plan.storageBytes(for: "other-system-data") > 0)
  #expect(plan.bytes(for: "required-siri-assets") > 0)
  #expect(plan.storageBytes(for: "system-assets") > 0)
  #expect(plan.bytes(for: "linguistic-data") > 0)
  for category in DiskStore.categories where category.canClean {
    for target in try DiskStore.targets(root, category: category.id) {
      try DiskStore.clear(root, target: target)
    }
  }
  for (_, path) in regions {
    #expect(DiskStore.exists(root.appendingPathComponent(path + "/keep")))
  }
  #expect(DiskStore.exists(outside))
}

@Test func cancelledDiskAnalysisStopsWithoutRemovingFiles() async throws {
  let fixture = try Fixture()
  defer { fixture.remove() }
  let root = try fixture.directory("data")
  let file = try fixture.file("data/Library/Caches/keep")
  let task = Task.detached {
    withUnsafeCurrentTask { $0?.cancel() }
    return try DiskStore.plan(udid: launchdReadDevice.udid, root: root)
  }
  await #expect(throws: CancellationError.self) { try await task.value }
  #expect(DiskStore.exists(file))
}

@Test(arguments: ["configurations", "descriptors", "staticdescriptors"])
func wallpaperCleanupKeepsOriginalsAndUnknownLayouts(_ collection: String) throws {
  let fixture = try Fixture()
  defer { fixture.remove() }
  let root = try fixture.directory("data").resolvingSymlinksInPath()
  let store = "data/Library/Application Support/PRBPosterExtensionDataStore"
  let version =
    store + "/61/Extensions/com.apple.MercuryPoster/" + collection
    + "/00000000-0000-0000-0000-000000000001/versions/0"
  let cache = version + "/scratch/SnapshotCache.cachedb"
  let snapshot = try fixture.file(cache + "/PosterSnapshotCache.bundle/Composite.atx")
  let cacheDatabase = try fixture.file(cache + "/cache.db")
  let original = try fixture.file(version + "/contents/original.HEIC")
  let settings = try fixture.file(version + "/configuration.plist")
  let unrelated = try fixture.file(version + "/scratch/keep")
  let unknown = try fixture.file(store + "/unknown/SnapshotCache.cachedb/keep")
  let ordinaryCache = try fixture.file(store + "/Caches/keep")
  let outside = try fixture.file("outside/keep")
  try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent(
      "Library/Application Support/PRBPosterExtensionDataStore/linked"),
    withDestinationURL: outside.deletingLastPathComponent())
  let category = try #require(DiskStore.categories.first { $0.id == "wallpaper-cache" })
  #expect(category.canClean && !category.defaultSelected)
  #expect(try DiskStore.selection([category.id]) == [category.id])
  let plan = try DiskStore.plan(udid: launchdReadDevice.udid, root: root)
  let targets = try DiskStore.targets(root, category: category.id)
  #expect(targets.count == 1)
  #expect(
    plan.bytes(for: category.id)
      == (try DiskStore.allocatedSize(
        snapshot.deletingLastPathComponent().deletingLastPathComponent())))
  #expect(plan.totalBytes == plan.cleanableBytes + plan.storage.reduce(0) { $0 + $1.bytes })
  #expect(plan.bytes(for: "caches") == 0)
  for target in targets { try DiskStore.clear(root, target: target) }
  #expect(!DiskStore.exists(snapshot))
  #expect(!DiskStore.exists(cacheDatabase))
  for file in [original, settings, unrelated, unknown, ordinaryCache, outside] {
    #expect(DiskStore.exists(file))
  }
  let updated = try DiskStore.plan(udid: launchdReadDevice.udid, root: root)
  #expect(updated.bytes(for: category.id) <= plan.bytes(for: category.id))
  #expect(updated.storageBytes(for: "wallpapers") == plan.storageBytes(for: "wallpapers"))
}

@Test func advancedCleanupKeepsUnselectedSystemAndPersonalData() throws {
  let fixture = try Fixture()
  defer { fixture.remove() }
  let root = try fixture.directory("data").resolvingSymlinksInPath()
  let assets = "data/private/var/MobileAsset/AssetsV2/"
  let siri = try fixture.file(assets + "com_apple_MobileAsset_UAF_Siri_Understanding/model")
  var deleted = [siri]
  deleted.append(try fixture.file(assets + "com_apple_MobileAsset_UAF_LinguisticData/model"))
  deleted.append(
    try fixture.file(assets + "com_apple_MobileAsset_UAF_SearchQueryUnderstanding/model"))
  for path in ["IntelligencePlatform", "Biome", "DuetExpertCenter"] {
    deleted.append(try fixture.file("data/Library/" + path + "/index.db"))
  }
  var preserved: [URL] = []
  for path in [
    assets + "com_apple_MobileAsset_VoiceServices_CustomVoice/personal-voice",
    assets + "com_apple_MobileAsset_UAF_Siri_Unknown/unknown",
    assets + "com_apple_MobileAsset_OSEligibility/data",
    "data/Library/Health/health.db", "data/Library/homed/home.db",
    "data/Library/Shortcuts/shortcuts.db", "data/Media/photo.HEIC",
    "data/Containers/Data/Application/A/Documents/file",
  ] { preserved.append(try fixture.file(path)) }
  let before = try DiskStore.plan(udid: launchdReadDevice.udid, root: root)
  #expect(before.totalBytes == before.cleanableBytes + before.storage.reduce(0) { $0 + $1.bytes })
  let ids: Set<String> = [
    "required-siri-assets", "intelligence-data", "linguistic-data", "system-models",
  ]
  #expect(DiskStore.categories.filter { ids.contains($0.id) }.allSatisfy { !$0.defaultSelected })
  for id in try DiskStore.selection(ids) {
    for target in try DiskStore.targets(root, category: id) {
      try DiskStore.clear(root, target: target)
    }
  }
  for path in deleted { #expect(!DiskStore.exists(path)) }
  for path in preserved { #expect(DiskStore.exists(path)) }
}
