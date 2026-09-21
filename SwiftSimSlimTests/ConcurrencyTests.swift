import Foundation
import Testing

@testable import SwiftSimSlim

private func device(_ number: Int, booted: Bool = false) -> SimulatorDevice {
  .init(
    udid: String(format: "00000000-0000-0000-0000-%012d", number), name: "Fixture \(number)",
    state: booted ? "Booted" : "Shutdown", osVersion: "26.5", managedDisabled: 0,
    managedTotal: ServiceCatalog.slimmable.count, statusError: nil, memory: nil, memoryError: nil)
}

@MainActor
private func eventually(_ condition: @MainActor () async -> Bool) async -> Bool {
  for _ in 0..<2000 {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(1))
  }
  return false
}

private actor Gate {
  private var open = false
  private var continuations: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    if open { return }
    await withCheckedContinuation { continuations.append($0) }
  }
  func release() {
    open = true
    for continuation in continuations { continuation.resume() }
    continuations.removeAll()
  }
}

@Test @MainActor func heavyOperationsQueueWithoutBlockingOtherDevices() async throws {
  let queue = OperationCoordinator(heavyLimit: 2)
  let tickets = try queue.reserve([device(1), device(2), device(3)], action: .boot)
  try await queue.acquire(tickets[0])
  try await queue.acquire(tickets[1])
  let waiting = Task { try await queue.acquire(tickets[2]) }
  #expect(queue.runningCount == 2)
  #expect(queue.queuedCount == 1)
  #expect(queue.entries[device(3).udid]?.stage.hasPrefix("Queued") == true)
  let light = try #require(queue.reserve([device(4)], action: .rename("Other")).first)
  try await queue.acquire(light)
  #expect(queue.runningCount == 3)
  queue.finish(tickets[0])
  try await waiting.value
  #expect(queue.entries[device(3).udid]?.started != nil)
  for ticket in tickets { queue.finish(ticket) }
  queue.finish(light)
  #expect(queue.entries.isEmpty)
}

@Test @MainActor func overlappingBatchesAreRejectedAtomicallyAndLateEventsAreIgnored() async throws
{
  let queue = OperationCoordinator()
  let old = try #require(queue.reserve([device(1)], action: .boot).first)
  #expect(throws: SimulatorError.self) {
    try queue.reserve([device(2), device(1)], action: .delete)
  }
  #expect(queue.entries[device(2).udid] == nil)
  try await queue.acquire(old)
  queue.finish(old)
  let next = try #require(queue.reserve([device(1)], action: .shutdown).first)
  try await queue.acquire(next)
  queue.update("Late old output", for: old)
  queue.finish(old)
  #expect(queue.entries[device(1).udid]?.ticket.id == next.id)
  #expect(queue.entries[device(1).udid]?.stage == SimulatorAction.shutdown.title)
  queue.finish(next)
}

@Test @MainActor func cancellingQueuedWorkReleasesOnlyItsDevice() async throws {
  let queue = OperationCoordinator(heavyLimit: 1)
  let tickets = try queue.reserve([device(1), device(2)], action: .boot)
  try await queue.acquire(tickets[0])
  let waiting = Task {
    defer { queue.finish(tickets[1]) }
    try await queue.acquire(tickets[1])
  }
  await Task.yield()
  waiting.cancel()
  await #expect(throws: CancellationError.self) { try await waiting.value }
  #expect(queue.entries[device(2).udid] == nil)
  #expect(queue.entries[device(1).udid]?.started != nil)
  queue.finish(tickets[0])
  let next = try #require(queue.reserve([device(2)], action: .boot).first)
  try await queue.acquire(next)
  queue.finish(next)
  #expect(queue.entries.isEmpty)
}

/// Only synthetic simctl replies. No command is passed to the operating system.
private actor ParallelSimulator {
  var devices: [String: SimulatorDevice]
  var states: [String: String]
  var disabled: [String: Set<String>] = [:]
  var commands: [[String]] = []
  var renameGates: [String: Gate] = [:]
  var bootGates: [String: Gate] = [:]
  var failedBoots: Set<String> = []
  var nextListGate: Gate?
  var heldLists = 0
  init(_ fixtures: [SimulatorDevice]) {
    devices = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.udid, $0) })
    states = Dictionary(uniqueKeysWithValues: fixtures.map { ($0.udid, $0.state) })
  }
  func writeOverrides(_ id: String, _ desired: Set<String>) { disabled[id] = desired }
  func holdRename(_ id: String, gate: Gate) { renameGates[id] = gate }
  func holdBoot(_ id: String, gate: Gate, fail: Bool = false) {
    bootGates[id] = gate
    if fail { failedBoots.insert(id) }
  }
  func holdList(_ gate: Gate) { nextListGate = gate }
  func add(_ fixture: SimulatorDevice) {
    devices[fixture.udid] = fixture
    states[fixture.udid] = fixture.state
  }
  func execute(_ executable: String, _ args: [String]) async throws -> CommandResult {
    commands.append(args)
    var output = ""
    if args.contains("list") {
      let rows: [[String: Any]] = devices.values.map {
        [
          "udid": $0.udid, "name": $0.name, "state": states[$0.udid] ?? "Shutdown",
          "isAvailable": true,
        ]
      }
      let data = try JSONSerialization.data(withJSONObject: [
        "devices": ["com.apple.CoreSimulator.SimRuntime.iOS-26-5": rows]
      ])
      if let gate = nextListGate {
        nextListGate = nil
        heldLists += 1
        await gate.wait()
      }
      return .init(data: data, errorData: Data(), status: 0)
    }
    if let id = args.first(where: { devices[$0] != nil }) {
      if args.contains("rename"), let gate = renameGates[id] { await gate.wait() }
      if args.contains("delete") {
        devices.removeValue(forKey: id)
        states.removeValue(forKey: id)
      }
      if args.contains("boot") {
        if let gate = bootGates[id] { await gate.wait() }
        if failedBoots.contains(id) { throw SimulatorError("Injected boot failure") }
        states[id] = "Booted"
      }
      if args.contains("shutdown") { states[id] = "Shutdown" }
      if args.contains("disable"), let label = args.last {
        disabled[id, default: []].insert(String(label.dropFirst(7)))
      }
      if args.contains("enable"), let label = args.last {
        disabled[id, default: []].remove(String(label.dropFirst(7)))
      }
      if args.contains("print-disabled") {
        output =
          "disabled services = {\n"
          + (disabled[id] ?? []).sorted().map { "\"\($0)\" => disabled" }.joined(separator: "\n")
          + "\n}"
      }
    }
    return .init(data: Data(output.utf8), errorData: Data(), status: 0)
  }
}

@MainActor
private func model(_ fake: ParallelSimulator) -> AppModel {
  AppModel(
    deviceSets: ["/synthetic-test-set"],
    runner: CommandRunner(executor: { try await fake.execute($0, $1) }),
    defaults: UserDefaults(suiteName: "SwiftSimSlim-Concurrency-\(UUID())")!,
    automaticallyMeasureDisk: false,
    writeOverrides: { await fake.writeOverrides($0, $1) })
}

@Test @MainActor func anotherDeviceRemainsUsableAndBatchesHaveIndependentProgress() async throws {
  let a = device(1)
  let b = device(2)
  let fake = ParallelSimulator([a, b])
  let firstGate = Gate()
  let secondGate = Gate()
  await fake.holdRename(a.udid, gate: firstGate)
  await fake.holdRename(b.udid, gate: secondGate)
  defer {
    Task {
      await firstGate.release()
      await secondGate.release()
    }
  }
  let app = model(fake)
  await app.load()
  app.select([a.udid])
  let first = Task { await app.renameSimulator(a, to: "First") }
  #expect(await eventually { app.isOperating(a) })
  app.select([b.udid])
  #expect(app.canOperateOnSelection)
  let second = Task { await app.renameSimulator(b, to: "Second") }
  #expect(await eventually { app.batches.count == 2 })
  #expect(app.operations.runningCount == 2)
  let batches = Set(app.batches.map(\.id))
  // The same device cannot start a second operation, even through a direct model call.
  await app.renameSimulator(a, to: "Conflict")
  #expect(await fake.commands.filter { $0.contains("Conflict") }.isEmpty)
  app.keptCategoryIDs = ["store"]
  await secondGate.release()
  await second.value
  #expect(app.isOperating(a))
  #expect(!app.isOperating(b))
  #expect(app.batches.count == 1)
  #expect(Set(app.batches.map(\.id)).isSubset(of: batches))
  #expect(app.selectedUDIDs == [b.udid])
  await firstGate.release()
  await first.value
  #expect(app.selectedUDIDs == [b.udid])
  #expect(app.batches.isEmpty && app.operations.entries.isEmpty)
}

@Test @MainActor func queuedProfilesKeepTheirSettingsAndCacheCounts() async throws {
  let a = device(1, booted: true)
  let b = device(2, booted: true)
  let fake = ParallelSimulator([a, b])
  let app = model(fake)
  await app.load()
  let keep = ServiceCatalog.slimmable.subtracting(ServiceCatalog.slimmable.sorted().prefix(2))
  app.keptServiceLabels = keep
  app.preserveBootState = true
  let blockers = try app.operations.reserve([device(3), device(4)], action: .boot)
  for ticket in blockers { try await app.operations.acquire(ticket) }
  let operation = Task { await app.applyProfile(to: [a, b]) }
  #expect(await eventually { app.operations.queuedCount == 2 })
  app.keptServiceLabels = ServiceCatalog.slimmable
  app.keptCategoryIDs = ["store"]
  app.preserveBootState = false
  for fixture in [a, b] {
    if case .slim(let snapshot) = app.operations.entries[fixture.udid]?.ticket.action {
      #expect(snapshot.labels == keep)
      #expect(snapshot.categories.isEmpty)
      #expect(snapshot.preserveBootState)
      #expect(snapshot.disabledCount == 2)
    } else {
      Issue.record("Queued profile missing")
    }
  }
  for ticket in blockers { app.operations.finish(ticket) }
  await operation.value
  #expect(await fake.disabled[a.udid]?.count == 2)
  #expect(await fake.disabled[b.udid]?.count == 2)
  #expect(app.operations.entries.isEmpty)
  #expect(app.activity.allSatisfy { $0.level != .failure })
  for fixture in app.devices {
    #expect(
      app.slimState(for: fixture) == .partial(disabled: 2, total: ServiceCatalog.slimmable.count))
  }
}

@Test @MainActor func refreshStartedBeforeDeletionCannotRestoreADeletedRow() async throws {
  let a = device(1)
  let b = device(2)
  let fake = ParallelSimulator([a, b])
  let app = model(fake)
  await app.load()
  app.select([a.udid, b.udid])
  let gate = Gate()
  await fake.holdList(gate)
  defer { Task { await gate.release() } }
  let refresh = Task { await app.refresh() }
  #expect(await eventually { await fake.heldLists == 1 })
  await app.deleteSimulators([a])
  #expect(!app.devices.contains { $0.udid == a.udid })
  await gate.release()
  await refresh.value
  #expect(app.devices.map(\.udid) == [b.udid])
  #expect(app.selectedUDIDs == [b.udid])
}

@Test @MainActor func unfinishedClonesStayHiddenDuringUnrelatedRefreshes() async throws {
  let a = device(1)
  let clone = device(2)
  let fake = ParallelSimulator([a])
  let app = model(fake)
  await app.load()
  let ticket = try #require(app.operations.reserve([a], action: .clone("Copy")).first)
  try await app.operations.acquire(ticket)
  await fake.add(clone)
  await app.refresh()
  #expect(app.devices.map(\.udid) == [a.udid])
  app.operations.finish(ticket)
  await app.refresh()
  #expect(Set(app.devices.map(\.udid)) == [a.udid, clone.udid])
}

@Test @MainActor func failedOperationFreesAHeavySlotWhileAnotherDeviceKeepsRunning() async throws {
  let a = device(1)
  let b = device(2)
  let c = device(3)
  let fake = ParallelSimulator([a, b, c])
  let first = Gate()
  let second = Gate()
  await fake.holdBoot(a.udid, gate: first, fail: true)
  await fake.holdBoot(b.udid, gate: second)
  defer {
    Task {
      await first.release()
      await second.release()
    }
  }
  let app = model(fake)
  await app.load()
  let failed = Task { await app.bootSimulator(a) }
  let held = Task { await app.bootSimulator(b) }
  #expect(await eventually { app.operations.runningCount == 2 })
  let queued = Task { await app.bootSimulator(c) }
  #expect(await eventually { app.operations.queuedCount == 1 })
  await first.release()
  await failed.value
  await queued.value
  #expect(app.isOperating(b))
  #expect(!app.isOperating(c))
  #expect(await fake.states[c.udid] == "Booted")
  #expect(
    app.activity.contains { $0.level == .failure && $0.message.contains("Injected boot failure") })
  #expect(app.presentedError == nil)
  await second.release()
  await held.value
  #expect(app.operations.entries.isEmpty)
}

@Test @MainActor func automaticDiskAnalysisDoesNotCancelItselfWhenReservingADevice() async throws {
  let a = device(1)
  let app = model(ParallelSimulator([a]))
  await app.load()
  app.select([a.udid])
  let before = app.diskAnalysisRequestID
  let analysis = try #require(app.operations.reserve([a], action: .analyze).first)
  #expect(app.diskAnalysisRequestID == before)
  app.operations.finish(analysis)
  let mutation = try #require(app.operations.reserve([a], action: .boot).first)
  #expect(app.diskAnalysisRequestID != before)
  app.operations.finish(mutation)
  #expect(app.diskAnalysisRequestID == before)
}
