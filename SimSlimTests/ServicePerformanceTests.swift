import Foundation
import Testing

@testable import SimSlim

@Test func applyingFullProfileAvoidsOneSimctlPerService() async throws {
  let fake = FakeSimulator()
  let backend = SimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }),
    writeOverrides: { _, desired in await fake.writeOverrides(desired) })
  let device = try await backend.find(fake.udid)
  try await backend.ensure(device, desired: ServiceCatalog.slimmable)
  let commands = await fake.commands
  let spawns = commands.filter { $0.contains("spawn") && !$0.contains("print-disabled") }
  #expect(spawns.isEmpty, "The offline fast path must not launch a command per service.")
}

@Test func matchingBootedProfileDoesNotBootOrWaitAgain() async throws {
  let fake = FakeSimulator()
  let backend = SimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }),
    writeOverrides: { _, desired in await fake.writeOverrides(desired) })
  let device = try await backend.find(fake.udid)
  try await backend.ensure(device, desired: [])
  let commands = await fake.commands
  #expect(!commands.contains { $0.contains("boot") || $0.contains("bootstatus") })
}

@Test func bootedProfileUsesOneRestartAndNoServiceSpawns() async throws {
  let fake = FakeSimulator()
  let backend = SimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }),
    writeOverrides: { _, desired in await fake.writeOverrides(desired) })
  _ = try await backend.slim(
    udid: fake.udid, exceptCategories: [], keepLabels: [], preserveBootState: true)
  let commands = await fake.commands
  #expect(commands.filter { $0.contains("boot") }.count == 1)
  #expect(commands.filter { $0.contains("shutdown") }.count == 1)
  #expect(!commands.contains { $0.contains("simslim-batch") || $0.contains("disable") })
  #expect(await fake.disabled == ServiceCatalog.slimmable)
  #expect(await fake.state == "Booted")
}

private actor ConcurrentServiceFixture {
  var active = 0
  var peak = 0
  var calls: [String: Int] = [:]
  var arguments: [[String]] = []
  let retry: String
  init(retry: String) { self.retry = retry }
  func execute(_ executable: String, _ args: [String]) async throws -> CommandResult {
    let label = String(args.last!.dropFirst(7))
    arguments.append(args)
    calls[label, default: 0] += 1
    let attempt = calls[label]!
    active += 1
    peak = max(peak, active)
    defer { active -= 1 }
    try await Task.sleep(for: .milliseconds(15))
    return .init(data: Data(), errorData: Data(), status: label == retry && attempt == 1 ? 1 : 0)
  }
}

@Test func batchRetriesOnlyFailedLabelsAndBoundsConcurrency() async throws {
  let labels = Array(ServiceCatalog.slimmable.sorted().prefix(45))
  let fake = ConcurrentServiceFixture(retry: labels[7])
  let backend = SimSlimBackend(runner: CommandRunner(executor: { try await fake.execute($0, $1) }))
  let device = RawDevice(
    udid: UUID().uuidString, name: "Fixture", state: "Booted", isAvailable: true,
    dataPath: nil, set: "/tmp/isolated-batch-fixture", osVersion: "27.0")
  try await backend.applyServiceChanges(device, disable: labels, enable: [])
  #expect(await fake.peak == ServiceBatch.concurrency)
  let calls = await fake.calls
  #expect(calls[labels[7]] == 2)
  #expect(calls.filter { $0.key != labels[7] }.values.allSatisfy { $0 == 1 })
  let commands = await fake.arguments
  #expect(commands.allSatisfy { $0.prefix(3) == ["simctl", "--set", device.set] })
  #expect(!commands.contains { $0.contains("/bin/sh") })
}

@Test func batchesRejectUnsafeTransitionsBeforeLaunching() async throws {
  let fake = FakeSimulator()
  let backend = SimSlimBackend(runner: CommandRunner(executor: { try await fake.execute($0, $1) }))
  var device = try await backend.find(fake.udid)
  let before = await fake.commands.count
  await #expect(throws: SimulatorError.self) {
    try await backend.applyServiceChanges(device, disable: ["unmanaged"], enable: [])
  }
  let compatibility = try #require(ServiceCatalog.compatibility.first)
  await #expect(throws: SimulatorError.self) {
    try await backend.applyServiceChanges(device, disable: [compatibility], enable: [])
  }
  device = RawDevice(udid: "all", name: "Bad", state: "Booted", isAvailable: true, dataPath: nil)
  await #expect(throws: SimulatorError.self) {
    try await backend.applyServiceChanges(device, disable: [], enable: [compatibility])
  }
  #expect(await fake.commands.count == before)
}

@Test func cancelledBatchNeverFallsThroughToRetries() async throws {
  let fake = FakeSimulator()
  let backend = SimSlimBackend(
    runner: CommandRunner(executor: { _, args in
      _ = try await fake.execute("", args)
      throw CancellationError()
    }))
  let device = RawDevice(
    udid: fake.udid, name: "Fixture", state: "Booted", isAvailable: true, dataPath: nil)
  await #expect(throws: CancellationError.self) {
    try await backend.applyServiceChanges(
      device, disable: Array(ServiceCatalog.slimmable), enable: [])
  }
  #expect(await fake.commands.count <= ServiceBatch.concurrency)
}

@Test func unavailableOfflineStoreFallsBackAndVerifies() async throws {
  let fake = FakeSimulator()
  let backend = SimSlimBackend(
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }),
    writeOverrides: { _, _ in throw SimulatorError("Injected store failure") })
  let desired = Set(ServiceCatalog.slimmable.sorted().prefix(3))
  try await backend.ensure(try await backend.find(fake.udid), desired: desired)
  #expect(await fake.disabled == desired)
  let commands = await fake.commands
  #expect(commands.filter { $0.contains("disable") }.count == 3)
  #expect(commands.last?.contains("print-disabled") == true)
}

@Test func bootFailureDoesNotRetryTheEntireProfile() async throws {
  actor Replies {
    let fake = FakeSimulator()
    var boots = 0
    func execute(_ executable: String, _ arguments: [String]) async throws -> CommandResult {
      if arguments.contains("boot") {
        boots += 1
        throw SimulatorError("Injected boot failure")
      }
      return try await fake.execute(executable, arguments)
    }
  }
  let replies = Replies()
  let backend = SimSlimBackend(
    runner: CommandRunner(executor: { try await replies.execute($0, $1) }),
    writeOverrides: { _, desired in await replies.fake.writeOverrides(desired) })
  let device = try await backend.find(replies.fake.udid)
  await #expect(throws: SimulatorError.self) {
    try await backend.ensure(device, desired: ServiceCatalog.slimmable)
  }
  #expect(await replies.boots == 1)
  #expect(await replies.fake.commands.filter { $0.contains("disable") }.isEmpty)
}

@Test func parallelServiceFailuresHaveBoundedRetries() async throws {
  let fake = FakeSimulator()
  let backend = SimSlimBackend(
    runner: CommandRunner(executor: { _, args in
      _ = try await fake.execute("", args)
      return .init(data: Data(), errorData: Data("Fixture failure".utf8), status: 7)
    }))
  let device = RawDevice(
    udid: fake.udid, name: "Fixture", state: "Booted", isAvailable: true, dataPath: nil)
  await #expect(throws: SimulatorError.self) {
    try await backend.applyServiceChanges(
      device, disable: Array(ServiceCatalog.slimmable.sorted().prefix(2)), enable: [])
  }
  #expect(await fake.commands.count == 6)
}
