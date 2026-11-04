import Foundation
import Testing

@testable import SwiftSimSlim

actor WallpaperFixture {
  let udid = "00000000-0000-0000-0000-000000000081"
  let root: URL
  var state: String
  var disabled: Set<String> = ["unmanaged", "com.apple.weatherd"]
  var loaded = true
  var commands: [[String]] = []
  let failure: String
  init(root: URL, state: String = "Booted", failure: String = "") {
    self.root = root
    self.state = state
    self.failure = failure
  }
  func execute(_ executable: String, _ args: [String]) throws -> CommandResult {
    commands.append(args)
    func result(_ text: String = "") -> CommandResult {
      .init(data: Data(text.utf8), errorData: Data(), status: 0)
    }
    if args.contains("devices") {
      let data = try JSONSerialization.data(withJSONObject: [
        "devices": [
          "com.apple.CoreSimulator.SimRuntime.iOS-27-2": [
            [
              "udid": udid, "name": "Wallpaper fixture", "state": state,
              "dataPath": root.path, "isAvailable": true,
            ]
          ]
        ]
      ])
      return .init(data: data, errorData: Data(), status: 0)
    }
    if args.contains("print-disabled") {
      return result(
        "disabled services = {\n"
          + disabled.sorted().map { "\"\($0)\" => disabled" }.joined(separator: "\n") + "\n}")
    }
    if args.contains("list") {
      return result(
        "PID Status Label\n1 0 com.apple.SpringBoard\n"
          + (loaded ? "2 0 com.apple.PosterBoard\n" : ""))
    }
    if args.contains("disable") {
      if failure == "cancel" { throw CancellationError() }
      if failure != "ignore-disable" { disabled.insert(WallpaperMode.service) }
    }
    if args.contains("bootout") {
      if failure == "bootout" { throw SimulatorError("Refused bootout") }
      loaded = false
    }
    if args.contains("shutdown") {
      if failure == "shutdown" { throw SimulatorError("Refused shutdown") }
      state = "Shutdown"
    }
    if args.contains("boot") {
      state = "Booted"
      loaded = !disabled.contains(WallpaperMode.service)
    }
    return result()
  }
}

@Test func blackWallpaperLifecycleAndFailureSafety() async throws {
  for scenario in [
    "booted", "shutdown", "leave-shutdown", "backup", "cancel", "ignore-disable", "bootout",
    "shutdown-failure",
  ] {
    try await checkWallpaperScenario(scenario)
  }
}

private func checkWallpaperScenario(_ scenario: String) async throws {
  let files = try Fixture()
  defer { files.remove() }
  let root = try files.directory("data").resolvingSymlinksInPath()
  let wallpaper = try files.file("data/" + DiskStore.posterStorePath + "/61/contents/original")
  let protected = try [
    "Containers/Bundle/Application/A/App.app/binary",
    "Containers/Data/Application/A/Documents/document",
    "Containers/Data/Application/A/Library/Preferences/settings.plist",
    "Containers/Data/Application/A/Library/Application Support/database",
    "Containers/Shared/AppGroup/A/Documents/group-document",
    "Media/DCIM/photo", "Library/Caches/unrelated",
    "Library/Preferences/com.apple.SpringBoard.plist",
  ].map { try files.file("data/" + $0, text: "keep unchanged") }
  let fake = WallpaperFixture(
    root: root, state: scenario == "shutdown" ? "Shutdown" : "Booted",
    failure: scenario == "shutdown-failure" ? "shutdown" : (scenario == "shutdown" ? "" : scenario))
  let backend = SwiftSimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }),
    deviceSets: ["/isolated-wallpaper-fixture"])
  let successful = ["booted", "shutdown", "leave-shutdown"].contains(scenario)
  do {
    let result = try await backend.enableBlackWallpaper(
      udid: fake.udid, preserveBootState: scenario != "leave-shutdown"
    ) { backup in
      #expect(DiskStore.exists(wallpaper))
      #expect(backup.disabled == ["unmanaged", "com.apple.weatherd"])
      if scenario == "backup" { throw SimulatorError("Backup failed") }
    }
    #expect(successful)
    #expect(result.reclaimedBytes > 0)
    #expect(!DiskStore.exists(root.appendingPathComponent(DiskStore.posterStorePath)))
    #expect(await fake.disabled == ["unmanaged", "com.apple.weatherd", WallpaperMode.service])
    #expect(await fake.state == (scenario == "booted" ? "Booted" : "Shutdown"))
    #expect(await !fake.loaded)
  } catch {
    #expect(!successful, "Unexpected failure: \(error)")
    #expect(DiskStore.exists(wallpaper))
  }
  for path in protected {
    #expect(try String(contentsOf: path, encoding: .utf8) == "keep unchanged")
  }
  let commands = await fake.commands
  #expect(
    commands.allSatisfy { $0.prefix(3) == ["simctl", "--set", "/isolated-wallpaper-fixture"] })
  #expect(!commands.contains { $0.contains("erase") || $0.contains("delete") })
  for args in commands where args.contains("disable") || args.contains("bootout") {
    #expect(args.last == "system/" + WallpaperMode.service)
  }
}

@Test(arguments: ["store", "parent", "nested", "inside-data"])
func blackWallpaperRejectsRedirectedStores(_ scenario: String) async throws {
  let files = try Fixture()
  defer { files.remove() }
  let root = try files.directory("data").resolvingSymlinksInPath()
  let original = try files.file("data/" + DiskStore.posterStorePath + "/61/original")
  let document = try files.file(
    "data/Containers/Data/Application/A/Documents/document", text: "keep")
  let target: URL
  switch scenario {
  case "store", "inside-data": target = root.appendingPathComponent(DiskStore.posterStorePath)
  case "parent": target = root.appendingPathComponent("Library/Application Support")
  default: target = original
  }
  let moved = files.root.appendingPathComponent("moved-wallpapers")
  try FileManager.default.moveItem(at: target, to: moved)
  try FileManager.default.createSymbolicLink(
    at: target,
    withDestinationURL: scenario == "inside-data" ? document.deletingLastPathComponent() : moved)
  let fake = WallpaperFixture(root: root)
  let backend = SwiftSimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }), deviceSets: ["/fixture"])
  await #expect(throws: (any Error).self) {
    try await backend.enableBlackWallpaper(udid: fake.udid, preserveBootState: true, save: { _ in })
  }
  #expect(await fake.commands.count == 1, "Reject before booting or changing services")
  #expect(try String(contentsOf: document, encoding: .utf8) == "keep")
  #expect(DiskStore.exists(moved))
}

@Test func blackWallpaperRejectsAliasesAndCanRepeatWithNoStore() async throws {
  let files = try Fixture()
  defer { files.remove() }
  let root = try files.directory("data").resolvingSymlinksInPath()
  let fake = WallpaperFixture(root: root)
  let backend = SwiftSimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }), deviceSets: ["/fixture"])
  await #expect(throws: SimulatorError.self) {
    try await backend.enableBlackWallpaper(udid: "all", preserveBootState: true, save: { _ in })
  }
  #expect(await fake.commands.isEmpty)
  for _ in 0..<2 {
    let result = try await backend.enableBlackWallpaper(
      udid: fake.udid, preserveBootState: true, save: { _ in })
    #expect(result.reclaimedBytes == 0)
  }
  #expect(await fake.disabled == ["unmanaged", "com.apple.weatherd", WallpaperMode.service])
}
