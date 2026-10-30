import Foundation
import Testing

@testable import SwiftSimSlim

private let storageAppID = "com.example.StorageFixture"
private let storageSet = "/synthetic-app-storage"

private struct AppStorageFixture {
  let files: Fixture
  let device: RawDevice
  let bundle: URL
  let data: URL
  let documents: URL
  let database: URL
  let shared: URL
  let media: URL

  init() throws {
    files = try Fixture()
    let root = try files.directory("data").resolvingSymlinksInPath()
    let bundleContainer = try files.directory(
      "data/Containers/Bundle/Application/" + UUID().uuidString)
    bundle = bundleContainer.appendingPathComponent("Fixture.app").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    data = try files.directory("data/Containers/Data/Application/" + UUID().uuidString)
      .resolvingSymlinksInPath()
    for container in [bundleContainer, data] {
      try Self.plist(
        ["MCMMetadataIdentifier": storageAppID],
        at: container.appendingPathComponent(AppStorageStore.metadata))
    }
    try Self.plist(
      ["CFBundleIdentifier": storageAppID, "CFBundleDisplayName": "Storage Fixture"],
      at: bundle.appendingPathComponent("Info.plist"))
    try Data(repeating: 1, count: 8192).write(to: bundle.appendingPathComponent("asset"))
    documents = try Self.file(data.appendingPathComponent("Documents/keep.txt"))
    database = try Self.file(data.appendingPathComponent("Library/Application Support/db.sqlite"))
    _ = try Self.file(data.appendingPathComponent("tmp/generated"))
    shared = try files.file(
      "data/Containers/Shared/AppGroup/" + UUID().uuidString + "/Documents/shared")
    media = try files.file("data/Media/DCIM/100APPLE/photo.JPG")
    device = RawDevice(
      udid: "00000000-0000-0000-0000-000000000031", name: "Storage fixture", state: "Shutdown",
      isAvailable: true, dataPath: root.path, set: storageSet, osVersion: "27.0")
  }

  static func plist(_ value: [String: String], at path: URL) throws {
    try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0).write(
      to: path)
  }
  static func file(_ path: URL) throws -> URL {
    try FileManager.default.createDirectory(
      at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: 8192).write(to: path)
    return path
  }
  func app() throws -> InstalledSimulatorApp {
    try #require(AppStorageStore.scan(device).apps.first)
  }
}

@Test func appStorageMeasuresPrivateDataWithoutSharedDoubleCounting() throws {
  let fixture = try AppStorageFixture()
  defer { fixture.files.remove() }
  let snapshot = try AppStorageStore.scan(fixture.device)
  let app = try #require(snapshot.apps.first)
  #expect(snapshot.apps.count == 1)
  #expect(app.name == "Storage Fixture")
  #expect(app.bundleID == storageAppID && app.canManage)
  #expect(
    app.documentsBytes
      == (try DiskStore.allocatedSize(fixture.documents.deletingLastPathComponent())))
  #expect(
    app.bundleBytes == (try DiskStore.allocatedSize(fixture.bundle.deletingLastPathComponent())))
  #expect(
    app.otherDataBytes
      == (try DiskStore.allocatedSize(fixture.data.appendingPathComponent("Library")))
      + (try DiskStore.allocatedSize(fixture.data.appendingPathComponent("tmp"))))
  #expect(snapshot.sharedBytes > 0 && snapshot.mediaBytes > 0)
  #expect(app.totalBytes == app.bundleBytes + (app.documentsBytes ?? 0) + (app.otherDataBytes ?? 0))
}

@Test(arguments: [AppStorageAction.documents, .data])
func appStorageClearsOnlyChosenPrivateCategory(_ action: AppStorageAction) throws {
  let fixture = try AppStorageFixture()
  defer { fixture.files.remove() }
  let app = try fixture.app()
  try AppStorageStore.clear(fixture.device, app: app, action: action)
  #expect(DiskStore.exists(fixture.documents) == (action != .documents))
  #expect(DiskStore.exists(fixture.database) == (action != .data))
  for protected in [
    fixture.bundle, fixture.shared, fixture.media,
    fixture.data.appendingPathComponent(AppStorageStore.metadata),
    fixture.data.appendingPathComponent("Documents"),
    fixture.data.appendingPathComponent("Library"),
  ] { #expect(DiskStore.exists(protected)) }
}

@Test(arguments: [
  "symlink", "wrong-identity", "wrong-set", "booted", "duplicate-container", "system",
])
func appStorageRejectsUnsafeTargets(_ scenario: String) throws {
  let fixture = try AppStorageFixture()
  defer { fixture.files.remove() }
  var device = fixture.device
  var app = try fixture.app()
  switch scenario {
  case "symlink":
    let outside = try fixture.files.file("outside/precious")
    try FileManager.default.createSymbolicLink(
      at: fixture.data.appendingPathComponent("escape"), withDestinationURL: outside)
  case "wrong-identity":
    try AppStorageFixture.plist(
      ["MCMMetadataIdentifier": "com.other.App"],
      at: fixture.data.appendingPathComponent(AppStorageStore.metadata))
  case "wrong-set": device.set = "other-set"
  case "booted":
    device = .init(
      udid: device.udid, name: device.name, state: "Booted", isAvailable: true,
      dataPath: device.dataPath, set: device.set, osVersion: device.osVersion)
  case "duplicate-container":
    let duplicate = try fixture.files.directory(
      "data/Containers/Data/Application/" + UUID().uuidString)
    try AppStorageFixture.plist(
      ["MCMMetadataIdentifier": storageAppID],
      at: duplicate.appendingPathComponent(AppStorageStore.metadata))
  case "system":
    for container in [fixture.data, fixture.bundle.deletingLastPathComponent()] {
      try AppStorageFixture.plist(
        ["MCMMetadataIdentifier": "com.apple.Fixture"],
        at: container.appendingPathComponent(AppStorageStore.metadata))
    }
    try AppStorageFixture.plist(
      ["CFBundleIdentifier": "com.apple.Fixture"],
      at: fixture.bundle.appendingPathComponent("Info.plist"))
    app = try fixture.app()
  default: break
  }
  #expect(throws: SimulatorError.self) {
    try AppStorageStore.clear(device, app: app, action: .data)
  }
  #expect(DiskStore.exists(fixture.documents))
  #expect(DiskStore.exists(fixture.database))
  #expect(DiskStore.exists(fixture.shared))
}

private actor AppStorageCommands {
  let fixture: AppStorageFixture
  var booted: Bool
  var commands: [[String]] = []
  var mismatch = false
  var cancel = false
  var shutdownFails = false
  init(_ fixture: AppStorageFixture, booted: Bool) {
    self.fixture = fixture
    self.booted = booted
  }
  func options(mismatch: Bool = false, cancel: Bool = false, shutdownFails: Bool = false) {
    self.mismatch = mismatch
    self.cancel = cancel
    self.shutdownFails = shutdownFails
  }
  func execute(_ executable: String, _ args: [String]) throws -> CommandResult {
    commands.append(args)
    var text = ""
    if args.contains("devices") {
      let json = try JSONSerialization.data(withJSONObject: [
        "devices": [
          "com.apple.CoreSimulator.SimRuntime.iOS-27-0": [
            [
              "udid": fixture.device.udid, "name": fixture.device.name,
              "state": booted ? "Booted" : "Shutdown",
              "isAvailable": true, "dataPath": fixture.device.dataPath!,
            ]
          ]
        ]
      ])
      return .init(data: json, errorData: Data(), status: 0)
    } else if args.contains("boot") {
      booted = true
    } else if args.contains("shutdown") {
      if shutdownFails { throw CancellationError() }
      booted = false
    } else if args.contains("get_app_container") {
      if cancel { throw CancellationError() }
      text =
        mismatch ? "/outside/wrong" : (args.last == "app" ? fixture.bundle.path : fixture.data.path)
    } else if args.contains("uninstall") {
      #expect(booted)
      #expect(args.last == storageAppID)
      try FileManager.default.removeItem(at: fixture.bundle.deletingLastPathComponent())
      try FileManager.default.removeItem(at: fixture.data)
    }
    return .init(data: Data(text.utf8), errorData: Data(), status: 0)
  }
}

@Test(arguments: [true, false], [AppStorageAction.uninstall, .documents, .data])
func appStorageBackendResolvesContainersAndRestoresBootState(
  _ booted: Bool, _ action: AppStorageAction
) async throws {
  let fixture = try AppStorageFixture()
  defer { fixture.files.remove() }
  let fake = AppStorageCommands(fixture, booted: booted)
  let backend = SwiftSimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }), deviceSets: [storageSet])
  let app = try #require(try await backend.appStorage(udid: fixture.device.udid).apps.first)
  #expect(await fake.commands.allSatisfy { $0.contains("devices") })
  try await backend.manageApp(app, action: action)
  #expect(await fake.booted == booted)
  #expect(DiskStore.exists(fixture.bundle) == (action != .uninstall))
  #expect(DiskStore.exists(fixture.documents) == (action == .data))
  #expect(DiskStore.exists(fixture.database) == (action == .documents))
  #expect(DiskStore.exists(fixture.shared) && DiskStore.exists(fixture.media))
  let commands = await fake.commands
  #expect(commands.allSatisfy { $0.prefix(3) == ["simctl", "--set", storageSet] })
  #expect(commands.contains { $0.contains("get_app_container") })
  if action != .uninstall { #expect(commands.contains { $0.contains("shutdown") }) }
}

@Test(arguments: ["mismatch", "cancel", "shutdown-failure", "ambiguous"])
func appStorageBackendFailureDoesNotDeleteData(_ failure: String) async throws {
  let fixture = try AppStorageFixture()
  defer { fixture.files.remove() }
  let fake = AppStorageCommands(fixture, booted: true)
  await fake.options(
    mismatch: failure == "mismatch", cancel: failure == "cancel",
    shutdownFails: failure == "shutdown-failure")
  let backend = SwiftSimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }),
    deviceSets: failure == "ambiguous" ? [storageSet, "other"] : [storageSet])
  do {
    try await backend.manageApp(fixture.app(), action: .data)
    Issue.record("Expected refusal")
  } catch {}
  #expect(DiskStore.exists(fixture.database))
  #expect(DiskStore.exists(fixture.documents))
  #expect(await fake.booted)
}
