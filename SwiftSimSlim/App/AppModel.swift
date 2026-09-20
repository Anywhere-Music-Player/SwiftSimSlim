import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
  private(set) var devices: [SimulatorDevice] = []
  private(set) var categories: [SlimCategory] = []
  private(set) var diskCleanupCategories: [DiskCleanupCategory] = []
  private(set) var diskCleanupPlans: [String: SimulatorDiskCleanupPlan] = [:]
  private(set) var measurements: [String: SimulatorMeasurement] = [:]
  private(set) var diskSizes: [String: SimulatorDiskMeasurement] = [:]
  private(set) var diskSizeLoadingUDIDs: Set<String> = []
  let operations = OperationCoordinator()
  var activeOperations: [String: String] { operations.entries.mapValues(\.stage) }
  var operationStarted: [String: Date] { operations.entries.compactMapValues(\.started) }
  private(set) var batches: [BatchProgress] = []
  @ObservationIgnored private var operationRevision = 0
  @ObservationIgnored private var refreshRequested = false
  @ObservationIgnored private let defaults: UserDefaults
  @ObservationIgnored private let automaticallyMeasureDisk: Bool
  private(set) var activity: [ActivityEntry] = []
  private(set) var isRefreshing = false
  private(set) var lastUpdated: Date?
  var selectedUDIDs: Set<String> = []
  var keptCategoryIDs: Set<String> = []
  var keptServiceLabels: Set<String> = []
  var selectedDiskCleanupCategoryIDs: Set<String> = []
  var preserveBootState = true
  var presentedError: PresentedError?

  @ObservationIgnored private var backend: SimSlimBackend?
  private var hasLoaded = false
  private var lastKnownDisabled: [String: Int]
  private var diskSizeTask: Task<Void, Never>?
  private var diskReloadRequested = false
  private static let stateCacheKey = "lastKnownManagedDisabled"

  init(
    deviceSets: [String] = ["", "testing"], runner: CommandRunner? = nil,
    defaults: UserDefaults = .standard, automaticallyMeasureDisk: Bool = true
  ) {
    self.defaults = defaults
    self.automaticallyMeasureDisk = automaticallyMeasureDisk
    lastKnownDisabled =
      defaults
      .dictionary(forKey: Self.stateCacheKey)?
      .compactMapValues { ($0 as? NSNumber)?.intValue } ?? [:]

    var commandRunner = runner ?? CommandRunner()
    commandRunner.report = { [weak self] event in
      Task { @MainActor [weak self] in self?.receive(event) }
    }
    backend = SimSlimBackend(runner: commandRunner, deviceSets: deviceSets)
  }

  #if DEBUG
    static func preview() -> AppModel {
      let model = AppModel(deviceSets: [])
      model.hasLoaded = true
      model.categories = ServiceCatalog.categories
      model.diskCleanupCategories = DiskStore.categories
      model.devices = [
        .init(
          udid: "00000000-0000-0000-0000-000000000001", name: "iPhone 17 Pro", state: "Booted",
          osVersion: "26.5", managedDisabled: ServiceCatalog.slimmable.count,
          managedTotal: ServiceCatalog.slimmable.count,
          statusError: nil, memory: .init(processes: 82, bytes: 900_000_000), memoryError: nil),
        .init(
          udid: "00000000-0000-0000-0000-000000000002", name: "iPhone 17 Pro QA", state: "Shutdown",
          osVersion: "27.0", managedDisabled: nil, managedTotal: ServiceCatalog.slimmable.count,
          statusError: nil, memory: nil, memoryError: nil),
      ]
      model.measurements[model.devices[0].udid] = model.devices[0].memory
      model.selectedUDIDs = [model.devices[0].udid]
      _ = try? model.operations.reserve([model.devices[0]], action: .boot)
      model.commandLog = [
        "Applying service profile…", "xcrun simctl bootstatus <test-simulator> -b",
        "Boot complete. Verifying services…",
      ]
      model.lastUpdated = Date()
      return model
    }
    static func parallelPreview() async throws -> AppModel {
      let model = preview()
      for entry in model.operations.entries.values { model.operations.finish(entry.ticket) }
      for (number, name) in [(3, "iPhone QA"), (4, "iPhone Free")] {
        model.devices.append(
          .init(
            udid: String(format: "00000000-0000-0000-0000-%012d", number),
            name: name, state: "Shutdown", osVersion: "26.5", managedDisabled: nil,
            managedTotal: ServiceCatalog.slimmable.count, statusError: nil, memory: nil,
            memoryError: nil))
      }
      let tickets = try model.operations.reserve(Array(model.devices.prefix(3)), action: .boot)
      for ticket in tickets.prefix(2) { try await model.operations.acquire(ticket) }
      model.operations.update("Verifying service state…", for: tickets[0])
      model.operations.update("Waiting for boot…", for: tickets[1])
      model.batches = [BatchProgress(total: 3, action: "Booting simulators…")]
      model.selectedUDIDs = [model.devices[3].udid]
      return model
    }
  #endif

  private(set) var commandLog: [String] = []

  private func receive(_ event: OperationEvent, ticket: OperationCoordinator.Ticket? = nil) {
    if event.kind == .stage, let ticket { operations.update(event.message, for: ticket) }
    let timestamp = Date().formatted(date: .omitted, time: .standard)
    let context =
      ticket.map { "[\($0.device.name) · \($0.device.udid) · \($0.id.uuidString.prefix(8))] " }
      ?? ""
    let target = event.udid.map { "[\($0)] " } ?? ""
    commandLog.append("[\(timestamp)] \(context)\(target)\(event.message)")
    if commandLog.count > 2000 { commandLog.removeFirst(commandLog.count - 2000) }
  }

  var isBusy: Bool { isRefreshing || !operations.entries.isEmpty }
  var diskAnalysisRequestID: String {
    let changing = selectedDevices.filter {
      guard let entry = operations.entries[$0.udid] else { return false }
      return entry.ticket.action != .analyze
    }.map(\.udid).sorted()
    return selectedUDIDs.sorted().joined(separator: ",") + ":" + changing.joined(separator: ",")
  }
  var canOperateOnSelection: Bool { operations.canReserve(selectedDevices) }
  func isOperating(_ device: SimulatorDevice) -> Bool { operations.entries[device.udid] != nil }
  var operationSummary: String {
    let running = operations.runningCount
    let queued = operations.queuedCount
    if queued > 0 { return "\(running) running · \(queued) queued" }
    return running > 0 ? "\(running) running" : "Refreshing…"
  }

  /// Labels kept enabled by a kept category or an individual keep. Categories
  /// may share labels, so a shared label is kept when any of its categories is.
  var effectiveKeptLabels: Set<String> {
    categories.reduce(into: keptServiceLabels) { kept, category in
      if categoryIsKept(category) { kept.formUnion(category.labels) }
    }
  }

  var disabledDaemonCount: Int {
    let allLabels = categories.reduce(into: Set<String>()) { $0.formUnion($1.labels) }
    return allLabels.subtracting(effectiveKeptLabels).count
  }

  var bootedCount: Int { devices.filter(\.isBooted).count }
  var selectionCount: Int { selectedUDIDs.count }

  var selectedDevices: [SimulatorDevice] {
    devices.filter { selectedUDIDs.contains($0.udid) }
  }

  var diskAnalysisCoversSelection: Bool {
    diskAnalysisCovers(selectedDevices)
  }

  var isAnalyzingDisk: Bool {
    selectedDevices.contains { operations.entries[$0.udid]?.ticket.action == .analyze }
  }

  var selectedDiskCleanupBytes: Int64 {
    diskCleanupBytes(for: selectedDevices, categoryIDs: selectedDiskCleanupCategoryIDs)
  }

  var diskStorageRows: [SimulatorDiskStorageMeasurement] {
    guard let device = selectedDevices.first else { return [] }
    return diskCleanupPlans[device.udid]?.storage ?? []
  }

  var canCleanDiskSelection: Bool {
    canCleanDisk(selectedDevices)
  }

  func diskAnalysisCovers(_ devices: [SimulatorDevice]) -> Bool {
    !devices.isEmpty && devices.allSatisfy { diskCleanupPlans[$0.udid] != nil }
  }

  func canCleanDisk(_ devices: [SimulatorDevice]) -> Bool {
    let cleanableIDs = Set(diskCleanupCategories.filter(\.canClean).map(\.id))
    let selectedIDs = selectedDiskCleanupCategoryIDs.intersection(cleanableIDs)
    return operations.canReserve(devices) && diskAnalysisCovers(devices)
      && !selectedIDs.isEmpty
      && diskCleanupBytes(for: devices, categoryIDs: selectedIDs) > 0
  }

  func load() async {
    guard !hasLoaded else { return }
    hasLoaded = true
    await refresh(includeCategories: true)
  }

  func refresh(includeCategories: Bool = false) async {
    guard let backend else { return }
    guard !isRefreshing else {
      refreshRequested = true
      return
    }
    isRefreshing = true
    defer { isRefreshing = false }
    if includeCategories || categories.isEmpty {
      categories = ServiceCatalog.categories
      diskCleanupCategories = DiskStore.categories
      selectedDiskCleanupCategoryIDs = Set(
        diskCleanupCategories.filter(\.defaultSelected).map(\.id))
    }
    repeat {
      refreshRequested = false
      let revision = operationRevision
      do {
        let incoming = try await backend.devices()
        guard revision == operationRevision else {
          refreshRequested = true
          continue
        }
        let existing = Dictionary(uniqueKeysWithValues: devices.map { ($0.udid, $0) })
        let cloning = operations.entries.values.contains { $0.ticket.action.isClone }
        // A clone isn't actionable until its preparation and independence audit finish.
        var merged = incoming.filter { !cloning || existing[$0.udid] != nil }.map { device in
          isOperating(device) ? (existing[device.udid] ?? device) : device
        }
        let received = Set(merged.map(\.udid))
        merged += devices.filter { isOperating($0) && !received.contains($0.udid) }
        devices = merged
        let available = Set(devices.map(\.udid))
        selectedUDIDs.formIntersection(available)
        diskCleanupPlans = diskCleanupPlans.filter { available.contains($0.key) }
        updateMeasurementsFromDevices()
        updateStateCacheFromLiveDevices()
        lastUpdated = Date()
        if automaticallyMeasureDisk { scheduleDiskSizeRefresh(for: devices) }
      } catch {
        recordFailure("Refresh failed: \(error.localizedDescription)", present: true)
      }
    } while refreshRequested && !Task.isCancelled
  }

  func slimState(for device: SimulatorDevice) -> ServiceSlimState {
    let cachedOrLiveDisabled = device.managedDisabled ?? lastKnownDisabled[device.udid]
    guard let cachedOrLiveDisabled else { return .unknown }
    // Profile updates can remove a daemon from the slimmable set. Clamp an
    // older shutdown-state cache to the current total until the device boots
    // and supplies a fresh live count.
    let disabled = min(max(cachedOrLiveDisabled, 0), device.managedTotal)
    switch disabled {
    case 0:
      return .stock
    case device.managedTotal:
      return .full(total: device.managedTotal)
    default:
      return .partial(disabled: disabled, total: device.managedTotal)
    }
  }

  func stateIsCached(for device: SimulatorDevice) -> Bool {
    device.managedDisabled == nil && lastKnownDisabled[device.udid] != nil
  }

  func diskSizeText(for device: SimulatorDevice, loadingText: String = "…") -> String {
    if let size = diskSizes[device.udid] {
      return size.sizeText
    }
    return diskSizeLoadingUDIDs.contains(device.udid) ? loadingText : "—"
  }

  func toggleSelection(_ udid: String) {
    if selectedUDIDs.contains(udid) {
      selectedUDIDs.remove(udid)
    } else {
      selectedUDIDs.insert(udid)
    }
  }

  func select(_ udids: Set<String>) {
    selectedUDIDs = udids
  }

  func clearSelection() {
    selectedUDIDs.removeAll()
  }

  func setCategory(_ category: SlimCategory, keptEnabled: Bool) {
    if keptEnabled {
      keptCategoryIDs.insert(category.id)
      keptServiceLabels.subtract(category.labels)
    } else {
      keptCategoryIDs.remove(category.id)
      keptServiceLabels.subtract(category.labels)
    }
  }

  func categoryIsKept(_ category: SlimCategory) -> Bool {
    keptCategoryIDs.contains(category.id)
      || category.labels.allSatisfy { keptServiceLabels.contains($0) }
  }

  func serviceIsKept(_ label: String) -> Bool {
    effectiveKeptLabels.contains(label)
  }

  func setService(_ label: String, in category: SlimCategory, keptEnabled: Bool) {
    guard category.labels.contains(label) else { return }

    if keptEnabled {
      keptServiceLabels.insert(label)
      if category.labels.allSatisfy({ keptServiceLabels.contains($0) }) {
        keptCategoryIDs.insert(category.id)
        keptServiceLabels.subtract(category.labels)
      }
      return
    }

    if keptCategoryIDs.remove(category.id) != nil {
      keptServiceLabels.formUnion(category.labels)
    }
    keptServiceLabels.remove(label)
  }

  func resetProfile() {
    keptCategoryIDs.removeAll()
    keptServiceLabels.removeAll()
  }

  func setDiskCleanupCategory(_ category: DiskCleanupCategory, selected: Bool) {
    guard category.canClean else { return }
    if selected {
      selectedDiskCleanupCategoryIDs.insert(category.id)
    } else {
      selectedDiskCleanupCategoryIDs.remove(category.id)
    }
  }

  func diskCleanupBytes(for categoryID: String) -> Int64? {
    guard diskAnalysisCoversSelection else { return nil }
    return selectedDevices.reduce(0) {
      $0 + (diskCleanupPlans[$1.udid]?.bytes(for: categoryID) ?? 0)
    }
  }

  func diskCleanupSizeText(for categoryID: String) -> String {
    guard !selectedDevices.isEmpty else { return "—" }
    guard !isAnalyzingDisk else { return "Analyzing…" }
    guard let bytes = diskCleanupBytes(for: categoryID) else {
      return "Pending"
    }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  func diskStorageSizeText(for storageID: String) -> String {
    guard diskAnalysisCoversSelection else { return isAnalyzingDisk ? "Analyzing…" : "Pending" }
    let bytes = selectedDevices.reduce(0) {
      $0 + (diskCleanupPlans[$1.udid]?.storageBytes(for: storageID) ?? 0)
    }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }

  func selectedDiskCleanupSizeText() -> String {
    guard !selectedDevices.isEmpty else { return "No selection" }
    guard !isAnalyzingDisk else { return "Analyzing…" }
    guard diskAnalysisCoversSelection else { return "Pending" }
    return ByteCountFormatter.string(fromByteCount: selectedDiskCleanupBytes, countStyle: .file)
  }

  func analyzeDiskSelectionIfNeeded() async {
    let missing = selectedDevices.filter { diskCleanupPlans[$0.udid] == nil && !isOperating($0) }
    guard !missing.isEmpty else { return }
    await analyzeDisk(devices: missing)
  }

  func analyzeDiskSelection() async {
    await analyzeDisk(devices: selectedDevices)
  }

  func cleanDisk(_ devices: [SimulatorDevice], categoryIDs: Set<String>) async {
    let allowed = Set(diskCleanupCategories.filter(\.canClean).map(\.id))
    let chosen = categoryIDs.intersection(allowed)
    guard !chosen.isEmpty else { return }
    await run(.clean(categories: chosen, preserveBootState: preserveBootState), on: devices)
  }

  func measure(_ device: SimulatorDevice) async {
    guard device.isBooted else { return }
    await run(.measure, on: [device])
  }

  func applyProfileToSelection() async { await applyProfile(to: selectedDevices) }
  func applyProfile(to device: SimulatorDevice) async { await applyProfile(to: [device]) }
  func applyProfile(to devices: [SimulatorDevice]) async {
    do {
      let profile = try ServiceProfileSnapshot(
        categories: keptCategoryIDs, labels: keptServiceLabels,
        preserveBootState: preserveBootState)
      await run(.slim(profile), on: devices)
    } catch { recordFailure(error.localizedDescription, present: true) }
  }
  func restoreSelection() async {
    await run(.restore(preserveBootState: preserveBootState), on: selectedDevices)
  }
  func restoreOriginalServices(for device: SimulatorDevice) async {
    await run(.restore(preserveBootState: preserveBootState), on: [device])
  }
  func cloneSimulator(_ device: SimulatorDevice, named name: String) async {
    await run(.clone(name), on: [device])
  }
  func renameSimulator(_ device: SimulatorDevice, to name: String) async {
    await run(.rename(name), on: [device])
  }
  func eraseSimulators(_ devices: [SimulatorDevice]) async { await run(.erase, on: devices) }
  func deleteSimulators(_ devices: [SimulatorDevice]) async { await run(.delete, on: devices) }
  func bootSimulator(_ device: SimulatorDevice) async { await run(.boot, on: [device]) }
  func shutdownSimulator(_ device: SimulatorDevice) async { await run(.shutdown, on: [device]) }
  func clearActivity() {
    activity.removeAll()
    commandLog.removeAll()
  }

  private func diskCleanupBytes(for devices: [SimulatorDevice], categoryIDs: Set<String>) -> Int64 {
    devices.reduce(0) { total, device in
      total + categoryIDs.reduce(0) { $0 + (diskCleanupPlans[device.udid]?.bytes(for: $1) ?? 0) }
    }
  }

  private func analyzeDisk(devices: [SimulatorDevice]) async { await run(.analyze, on: devices) }

  private func run(_ action: SimulatorAction, on devices: [SimulatorDevice]) async {
    guard backend != nil, !devices.isEmpty, !Task.isCancelled else { return }
    let tickets: [OperationCoordinator.Ticket]
    do { tickets = try operations.reserve(devices, action: action) } catch {
      recordFailure(error.localizedDescription, present: true)
      return
    }
    operationRevision += 1
    let batch = BatchProgress(total: tickets.count, action: action.title)
    batches.append(batch)
    var failures = 0
    await withTaskGroup(of: Bool.self) { group in
      for ticket in tickets {
        group.addTask { await self.perform(ticket, batchID: batch.id) }
      }
      for await success in group {
        if !success { failures += 1 }
      }
    }
    batches.removeAll { $0.id == batch.id }
    if tickets.count > 1 {
      record(
        failures == 0 ? .success : .failure,
        "\(action.title) Finished \(tickets.count - failures)/\(tickets.count); \(failures) failed or cancelled."
      )
    }
  }

  private func perform(_ ticket: OperationCoordinator.Ticket, batchID: UUID) async -> Bool {
    let device = ticket.device
    var succeeded = false
    do {
      try await operations.acquire(ticket)
      guard let base = backend else { throw SimulatorError("Backend unavailable.") }
      var runner = base.runner
      runner.report = { [weak self] event in
        Task { @MainActor [weak self] in self?.receive(event, ticket: ticket) }
      }
      let backend = SimSlimBackend(runner: runner, deviceSets: base.deviceSets)
      record(.info, "\(device.name): \(ticket.action.title)")
      switch ticket.action {
      case .slim(let profile):
        _ = try await backend.slim(
          udid: device.udid, exceptCategories: profile.categories,
          keepLabels: profile.labels, preserveBootState: profile.preserveBootState)
        setCachedDisabled(profile.disabledCount, for: device.udid)
      case .restore(let preserve):
        _ = try await backend.restore(udid: device.udid, preserveBootState: preserve)
        setCachedDisabled(0, for: device.udid)
      case .clean(let categories, let preserve):
        let result = try await backend.cleanDisk(
          udid: device.udid, categoryIDs: categories,
          preserveBootState: preserve)
        record(.success, "\(device.name): reclaimed \(result.reclaimedText)")
      case .boot: _ = try await backend.boot(udid: device.udid)
      case .shutdown: _ = try await backend.shutdown(udid: device.udid)
      case .rename(let name): _ = try await backend.rename(udid: device.udid, name: name)
      case .clone(let name):
        let result = try await backend.clone(udid: device.udid, name: name)
        if let disabled = device.managedDisabled ?? lastKnownDisabled[device.udid] {
          setCachedDisabled(disabled, for: result.udid)
        }
        record(.success, "\(device.name): clone ready — \(result.name ?? name) (\(result.udid))")
      case .erase:
        _ = try await backend.erase(udid: device.udid)
        measurements.removeValue(forKey: device.udid)
        setCachedDisabled(0, for: device.udid)
      case .delete:
        _ = try await backend.delete(udid: device.udid)
        measurements.removeValue(forKey: device.udid)
        diskSizes.removeValue(forKey: device.udid)
        removeCachedDisabled(for: device.udid)
        selectedUDIDs.remove(device.udid)
        self.devices.removeAll { $0.udid == device.udid }
      case .measure:
        let result = try await backend.measure(udid: device.udid)
        measurements[device.udid] = result
        record(.success, "\(device.name): \(result.memoryText), \(result.processes) processes")
      case .analyze:
        diskCleanupPlans[device.udid] = try await backend.diskCleanupPlan(udid: device.udid)
      }
      if ticket.action != .analyze && ticket.action != .measure {
        diskCleanupPlans.removeValue(forKey: device.udid)
      }
      record(.success, "\(device.name): \(ticket.action.title) Done")
      succeeded = true
    } catch is CancellationError {
      record(.info, "\(device.name): operation cancelled")
    } catch {
      // Concurrent errors stay in Activity instead of interrupting unrelated work with alerts.
      recordFailure(
        "\(device.name): \(ticket.action.title) \(error.localizedDescription)", present: false)
    }
    operations.finish(ticket)
    operationRevision += 1
    if let index = batches.firstIndex(where: { $0.id == batchID }) { batches[index].completed += 1 }
    // Release the permit before refreshing; each batch retains independent progress.
    if ticket.action != .analyze && ticket.action != .measure { await refresh() }
    return succeeded
  }

  private func updateStateCacheFromLiveDevices() {
    var changed = false
    for device in devices where !isOperating(device) {
      guard let managedDisabled = device.managedDisabled else { continue }
      if lastKnownDisabled[device.udid] != managedDisabled {
        lastKnownDisabled[device.udid] = managedDisabled
        changed = true
      }
    }
    if changed { persistStateCache() }
  }

  private func updateMeasurementsFromDevices() {
    let busyMeasurements = measurements.filter { operations.entries[$0.key] != nil }
    measurements = Dictionary(
      uniqueKeysWithValues: devices.compactMap { device in
        guard device.isBooted, let memory = device.memory else { return nil }
        return (device.udid, memory)
      })
    measurements.merge(busyMeasurements) { _, held in held }
  }

  private func scheduleDiskSizeRefresh(for snapshot: [SimulatorDevice]) {
    guard let backend else { return }
    guard diskSizeTask == nil else {
      diskReloadRequested = true
      return
    }

    let available = Set(snapshot.map(\.udid))
    diskSizes = diskSizes.filter { available.contains($0.key) }
    diskSizeLoadingUDIDs = available
    diskSizeTask = Task { [weak self] in
      guard let self else { return }
      await self.loadDiskSizes(for: snapshot, backend: backend)
      self.diskSizeTask = nil
      if self.diskReloadRequested {
        self.diskReloadRequested = false
        self.scheduleDiskSizeRefresh(for: self.devices)
      }
    }
  }

  private func loadDiskSizes(for snapshot: [SimulatorDevice], backend: SimSlimBackend) async {
    let revision = operationRevision
    await withTaskGroup(of: (String, SimulatorDiskMeasurement?).self) { group in
      var nextIndex = 0
      let concurrentMeasurements = min(3, snapshot.count)

      for _ in 0..<concurrentMeasurements {
        let device = snapshot[nextIndex]
        nextIndex += 1
        group.addTask {
          let measurement = try? await backend.diskSize(udid: device.udid)
          return (device.udid, measurement)
        }
      }

      while let (udid, measurement) = await group.next() {
        if revision == operationRevision, operations.entries[udid] == nil,
          devices.contains(where: { $0.udid == udid }), let measurement
        {
          diskSizes[udid] = measurement
        }
        diskSizeLoadingUDIDs.remove(udid)

        if nextIndex < snapshot.count {
          let device = snapshot[nextIndex]
          nextIndex += 1
          group.addTask {
            let measurement = try? await backend.diskSize(udid: device.udid)
            return (device.udid, measurement)
          }
        }
      }
    }

    let available = Set(devices.map(\.udid))
    diskSizes = diskSizes.filter { available.contains($0.key) }
    diskSizeLoadingUDIDs.formIntersection(available)
  }

  private func setCachedDisabled(_ count: Int, for udid: String) {
    lastKnownDisabled[udid] = count
    persistStateCache()
  }

  private func removeCachedDisabled(for udid: String) {
    lastKnownDisabled.removeValue(forKey: udid)
    persistStateCache()
  }

  private func persistStateCache() {
    defaults.set(lastKnownDisabled, forKey: Self.stateCacheKey)
  }

  private func record(_ level: ActivityEntry.Level, _ message: String) {
    activity.insert(ActivityEntry(level: level, message: message), at: 0)
    if activity.count > 100 {
      activity.removeLast(activity.count - 100)
    }
  }

  private func recordFailure(_ message: String, present: Bool) {
    record(.failure, message)
    if present {
      presentedError = PresentedError(message: message)
    }
  }

  private func summaryLine(_ output: String) -> String {
    output
      .split(separator: "\n")
      .last
      .map(String.init) ?? "Done"
  }
}
