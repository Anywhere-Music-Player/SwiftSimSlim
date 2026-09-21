import Foundation
import Testing

@testable import SwiftSimSlim

@Test func catalogSafetyAndDescriptions() throws {
  let forbidden: Set<String> = [
    "com.apple.nanoregistryd", "com.apple.nanoregistrylaunchd", "com.apple.nanoprefsyncd.2",
    "com.apple.nanotimekitcompaniond", "com.apple.nanobackupd", "com.apple.sleepd",
    "com.apple.appprotectiond", "com.apple.ManagedSettingsAgent",
    "com.apple.managedconfiguration.profiled", "com.apple.mobiletimerd", "com.apple.routined",
    "com.apple.biomed", "com.apple.biomesyncd", "com.apple.dmd", "com.apple.donotdisturbd",
  ]
  #expect(ServiceCatalog.managed.isDisjoint(with: forbidden))
  #expect(ServiceCatalog.slimmable.count > 100)
  for category in ServiceCatalog.categories {
    #expect(category.approxMemoryMB > 0)
    #expect(Set(category.labels).count == category.labels.count)
    for label in category.labels {
      let description = category.serviceDescriptions?[label] ?? ""
      #expect(description.count > 0)
    }
  }
  let all = try ServiceCatalog.desired(except: [], keep: [])
  #expect(all.isDisjoint(with: ServiceCatalog.compatibility))
  for category in ServiceCatalog.categories {
    let desired = try ServiceCatalog.desired(except: [category.id], keep: [])
    #expect(desired.isDisjoint(with: category.labels))
  }
}

@Test func deltaPreservesUnmanagedAndRepairsRequiredServices() throws {
  let label = try #require(ServiceCatalog.slimmable.first)
  let required = try #require(ServiceCatalog.compatibility.first)
  let delta = ServiceCatalog.delta(
    current: ["unmanaged", required], desired: [label, "unsafe", required])
  #expect(delta.disable == [label])
  #expect(delta.enable == [required])
  #expect(throws: SimulatorError.self) { try ServiceCatalog.desired(except: ["unknown"], keep: []) }
}

@Test(arguments: [
  ("18.5", true), ("18.4", false), ("17.9", false), ("26.0", true), ("unknown", false),
  ("18", false),
])
func persistenceVersions(_ version: String, _ supported: Bool) {
  #expect(ServiceCatalog.supportsPersistence(version) == supported)
}

@Test func disabledOutputAndMemoryParsing() {
  #expect(
    ServiceCatalog.parseDisabled(
      "\"a\" => disabled\n\"b\" => true\n\"c\" => false\n\"d\" => enabled") == ["a", "b"])
  #expect(MemoryParser.bytes("1.5G+") == 1_610_612_736)
  #expect(MemoryParser.bytes("42M") == 44_040_192)
  #expect(MemoryParser.bytes("nan") == 0)
  let children = MemoryParser.children(
    "PID PPID CPU COMM\n1 3 0 root\n2 1 0 child\n3 2 0 cycle\n9 0 0 unrelated")
  #expect(MemoryParser.tree(root: 1, children: children) == [1, 2, 3])
}

struct Fixture {
  let root: URL
  init() throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SwiftSimSlimTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }
  func directory(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  func file(_ name: String, text: String = "test") throws -> URL {
    let url = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    return url
  }
  func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test func diskCleanupProtectsDurableContentAndSymlinks() throws {
  let fixture = try Fixture()
  defer { fixture.remove() }
  let data = try fixture.directory("data")
  let disposable = try fixture.file("data/Library/Caches/remove")
  let documents = try fixture.file("data/Containers/Data/Application/A/Documents/Caches/keep")
  let media = try fixture.file("data/Media/Logs/keep")
  let bundle = try fixture.file("data/Containers/Bundle/Application/A/Demo.app/Caches/keep")
  let external = try fixture.file("outside/keep")
  let link = data.appendingPathComponent("external")
  try FileManager.default.createSymbolicLink(
    at: link, withDestinationURL: external.deletingLastPathComponent())
  let targets = try DiskStore.targets(data, category: "caches")
  #expect(targets.count == 1)
  for target in targets { try DiskStore.clear(data, target: target) }
  #expect(!DiskStore.exists(disposable))
  for file in [documents, media, external, bundle] { #expect(DiskStore.exists(file)) }
  #expect(throws: SimulatorError.self) { try DiskStore.clear(data, target: link) }
  #expect(throws: SimulatorError.self) { try DiskStore.clear(data, target: data) }
  #expect(throws: SimulatorError.self) { try DiskStore.selection(["required-siri-assets"]) }
  #expect(throws: SimulatorError.self) { try DiskStore.selection([]) }
}

@Test func diskRejectsIntermediateSymlinkEscapes() throws {
  let fixture = try Fixture()
  defer { fixture.remove() }
  let data = try fixture.directory("data")
  let outside = try fixture.directory("outside")
  _ = try fixture.file("outside/Caches/precious")
  try FileManager.default.createSymbolicLink(
    at: data.appendingPathComponent("Library"), withDestinationURL: outside)
  #expect(throws: SimulatorError.self) {
    try DiskStore.compact(data, [data.appendingPathComponent("Library/Caches")])
  }
}

@Test func offlineStoreMergesWithoutOverwritingUnmanagedEntries() throws {
  let fixture = try Fixture()
  defer { fixture.remove() }
  let udid = UUID().uuidString
  let url = try DisabledStore.url(udid: udid, root: fixture.root)
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  let label = try #require(ServiceCatalog.slimmable.first)
  let required = try #require(ServiceCatalog.compatibility.first)
  let original = ["foreign.disabled": true, "runtime.enabled": false, required: true]
  try PropertyListSerialization.data(fromPropertyList: original, format: .binary, options: 0).write(
    to: url)
  try DisabledStore.merge(udid: udid, desired: [label], root: fixture.root)
  let entries = try #require(
    PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
      as? [String: Bool])
  #expect(entries["foreign.disabled"] == true)
  #expect(entries["runtime.enabled"] == false)
  #expect(entries[label] == true)
  #expect(entries[required] == false)
  #expect(throws: SimulatorError.self) {
    try DisabledStore.url(udid: "../../all", root: fixture.root)
  }
}

@Test func cloneRebasesLinksAndPlistsAndRejectsHardlinks() throws {
  let fixture = try Fixture()
  defer { fixture.remove() }
  let sourceID = UUID().uuidString
  let cloneID = UUID().uuidString
  let sourceData = try fixture.directory(sourceID + "/data")
  let cloneData = try fixture.directory(cloneID + "/data")
  let sourceFile = try fixture.file(sourceID + "/data/Documents/file")
  let cloneFile = try fixture.file(cloneID + "/data/Documents/file")
  let plist = try fixture.file(
    cloneID + "/data/Library/Preferences/test.plist",
    text: "<?xml version=\"1.0\"?><plist version=\"1.0\"><string>" + sourceFile.path
      + "</string></plist>")
  let link = cloneData.appendingPathComponent("source-link")
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sourceFile)
  let source = RawDevice(
    udid: sourceID, name: "source", state: "Shutdown", isAvailable: true, dataPath: sourceData.path)
  let clone = RawDevice(
    udid: cloneID, name: "clone", state: "Shutdown", isAvailable: true, dataPath: cloneData.path)
  let paths = ClonePaths(source: source, clone: clone, sourceData: sourceData, cloneData: cloneData)
  try paths.sanitize()
  #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == cloneFile.path)
  #expect(try String(contentsOf: plist, encoding: .utf8).contains(cloneID))
  #expect(try paths.audit("p123\nn" + cloneFile.path + "\n"))
  #expect(throws: SimulatorError.self) { try paths.audit("p123\nn" + sourceFile.path + "\n") }
  try FileManager.default.removeItem(at: cloneFile)
  try FileManager.default.linkItem(at: sourceFile, to: cloneFile)
  #expect(try DiskStore.info(sourceFile).st_ino == DiskStore.info(cloneFile).st_ino)
  #expect(throws: SimulatorError.self) { try paths.verify() }
}

@Test func commandRunnerCapturesBothPipesAndExitStatus() async throws {
  let runner = CommandRunner()
  for _ in 0..<30 {
    let result = try await runner.run(
      "/bin/sh", ["-c", "printf output; printf error >&2; exit 7"], log: false)
    #expect(result.text == "output")
    #expect(result.diagnostic == "error")
    #expect(result.status == 7)
    #expect(throws: SimulatorError.self) { try result.checked() }
  }
}

@Test func commandRunnerTimeoutAndCancellation() async throws {
  let runner = CommandRunner()
  await #expect(throws: SimulatorError.self) {
    try await runner.run("/bin/sleep", ["10"], timeout: 0.05, log: false)
  }
  let task = Task { try await runner.run("/bin/sleep", ["10"], log: false) }
  try await Task.sleep(for: .milliseconds(50))
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
}

actor FakeSimulator {
  let udid = "00000000-0000-0000-0000-000000000001"
  var state = "Booted"
  var disabled: Set<String> = []
  var commands: [[String]] = []
  var loseOverrides = false
  func writeOverrides(_ desired: Set<String>) { disabled = desired }
  init(loseOverrides: Bool = false) { self.loseOverrides = loseOverrides }
  func execute(_ executable: String, _ args: [String]) throws -> CommandResult {
    commands.append(args)
    var output = ""
    if args.contains("list") {
      output =
        "{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-26-0\":[{\"udid\":\"\(udid)\",\"name\":\"Fixture\",\"state\":\"\(state)\",\"isAvailable\":true}]}}"
    } else if args.contains("print-disabled") {
      output =
        "disabled services = {\n"
        + disabled.sorted().map { "\"\($0)\" => disabled" }.joined(separator: "\n") + "\n}"
    } else if args.contains("disable") {
      disabled.insert(String(args.last!.dropFirst("system/".count)))
    } else if args.contains("enable") {
      disabled.remove(String(args.last!.dropFirst("system/".count)))
    } else if args.contains("shutdown") {
      state = "Shutdown"
    } else if args.contains("boot") {
      state = "Booted"
      if loseOverrides { disabled = [] }
    }
    return .init(data: Data(output.utf8), errorData: Data(), status: 0)
  }
}

@Test func profileLifecycleVerifiesAfterReboot() async throws {
  let fake = FakeSimulator()
  let backend = SwiftSimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }),
    writeOverrides: { _, desired in await fake.writeOverrides(desired) })
  let label = try #require(ServiceCatalog.slimmable.first)
  let device = try await backend.find(fake.udid)
  try await backend.ensure(device, desired: [label])
  let commands = await fake.commands
  #expect(commands.contains { $0.contains("shutdown") })
  #expect(commands.last?.contains("print-disabled") == true)
  #expect(await fake.disabled == [label])
  await #expect(throws: SimulatorError.self) { try await backend.delete(udid: "all") }
}

@Test func profileRejectsLostOverridesAndOldRuntimeBeforeMutation() async throws {
  let fake = FakeSimulator(loseOverrides: true)
  let backend = SwiftSimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }),
    writeOverrides: { _, desired in await fake.writeOverrides(desired) })
  let label = try #require(ServiceCatalog.slimmable.first)
  let device = try await backend.find(fake.udid)
  await #expect(throws: SimulatorError.self) { try await backend.ensure(device, desired: [label]) }
  var old = device
  old.osVersion = "18.3"
  let before = await fake.commands.count
  await #expect(throws: SimulatorError.self) { try await backend.ensure(old, desired: [label]) }
  #expect(await fake.commands.count == before)
}

@Test func commandRunnerDrainsLargeOutputWithoutDeadlocking() async throws {
  let output = try await CommandRunner().run(
    "/bin/sh",
    [
      "-c",
      "i=0; while [ $i -lt 2000 ]; do printf 'stdout data line\\n'; printf 'stderr data line\\n' >&2; i=$((i+1)); done",
    ], timeout: 5, log: false
  ).checked()
  #expect(output.text.split(separator: "\n").count == 2000)
  #expect(output.diagnostic.split(separator: "\n").count == 2000)
}

@Test func commandRunnerDoesNotWaitForInheritedPipes() async throws {
  let start = ContinuousClock.now
  let output = try await CommandRunner().run(
    "/bin/sh", ["-c", "/bin/sleep 1 & printf done"], timeout: 2, log: false
  ).checked()
  #expect(output.text == "done")
  #expect(ContinuousClock.now - start < .seconds(0.8))
}

@Test func outputIsDrainedAfterExitUnderConcurrentLoad() async throws {
  try await withThrowingTaskGroup(of: Void.self) { group in
    for number in 0..<100 {
      group.addTask {
        let expected = "{\"device\":\"\(number)\",\"state\":\"Shutdown\"}"
        let result = try await CommandRunner().run(
          "/bin/sh", ["-c", "printf '%s' \"$1\"", "fixture", expected], log: false
        ).checked()
        #expect(result.text == expected)
      }
    }
    try await group.waitForAll()
  }
}

@Test func configuredDeviceSetNeverFallsBackToDefault() async throws {
  let fake = FakeSimulator()
  let set = "/tmp/SwiftSimSlim-Isolated-Unit-Test"
  let backend = SwiftSimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }), deviceSets: [set])
  _ = try await backend.rename(udid: fake.udid, name: "Scoped")
  let commands = await fake.commands
  #expect(commands.count == 2)
  #expect(commands.allSatisfy { $0.prefix(3) == ["simctl", "--set", set] })
}

@Test func commandRunnerLaunchFailureAndEarlyCancellation() async throws {
  await #expect(throws: (any Error).self) {
    try await CommandRunner().run("/no/such/executable", [], log: false)
  }
  let task = Task { try await CommandRunner().run("/bin/sleep", ["10"], log: false) }
  task.cancel()
  await #expect(throws: CancellationError.self) { try await task.value }
}

@Test func deviceListRetriesOnlyReadTimeout() async throws {
  actor Replies {
    var calls = 0
    func execute(_ executable: String, _ args: [String]) throws -> CommandResult {
      calls += 1
      if calls == 1 { throw SimulatorError("Fixture timeout", isTimeout: true) }
      return .init(data: Data("{\"devices\":{}}".utf8), errorData: Data(), status: 0)
    }
  }
  let replies = Replies()
  let backend = SwiftSimSlimBackend(
    runner: CommandRunner(executor: { try await replies.execute($0, $1) }),
    deviceSets: ["/tmp/isolated-read-retry"])
  #expect(try await backend.listRaw().isEmpty)
  #expect(await replies.calls == 2)
}

@Test func incompleteLaunchdStateIsRejected() async throws {
  let backend = SwiftSimSlimBackend(
    runner: CommandRunner(executor: { _, _ in
      .init(data: Data(), errorData: Data(), status: 0)
    }))
  let device = RawDevice(
    udid: UUID().uuidString, name: "Fixture", state: "Booted", isAvailable: true, dataPath: nil)
  await #expect(throws: SimulatorError.self) { try await backend.disabled(device) }
}

@Test func emptyLaunchdStateIsValid() async throws {
  let backend = SwiftSimSlimBackend(
    runner: CommandRunner(executor: { _, _ in
      .init(
        data: Data("\n\tdisabled services = (no disabled services)\n".utf8), errorData: Data(),
        status: 0)
    }))
  let device = RawDevice(
    udid: UUID().uuidString, name: "Fresh", state: "Booted", isAvailable: true, dataPath: nil)
  #expect(try await backend.disabled(device).isEmpty)
}
