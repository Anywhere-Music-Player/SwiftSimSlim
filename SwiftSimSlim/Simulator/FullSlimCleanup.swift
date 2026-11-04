import Foundation

extension SwiftSimSlimBackend {
  /// One coordinated operation. A failed profile/backup must never proceed to deletion.
  func fullSlimAndClean(
    udid: String, preserveBootState: Bool,
    applyFullSlim: Bool = true,
    categoryIDs: Set<String> = Set(DiskStore.categories.filter(\.canClean).map(\.id)),
    save: @Sendable (ServiceStateBackup) async throws -> Void
  ) async throws -> SimulatorDiskCleanupResult {
    guard applyFullSlim || !categoryIDs.isEmpty else {
      throw SimulatorError("Select Full Slim or at least one cleanup category.")
    }
    if !categoryIDs.isEmpty { _ = try DiskStore.selection(categoryIDs) }
    let device = try await profileDevice(udid)
    // Validate the cleanup root before changing any services.
    _ = try DiskStore.dataDirectory(device)
    try Task.checkCancellation()
    if applyFullSlim {
      try await configureWithBackup(
        udid: udid, desired: ServiceCatalog.slimmable,
        preserveBootState: categoryIDs.isEmpty ? preserveBootState : true, save: save)
    }
    if categoryIDs.isEmpty {
      return .init(
        udid: udid, categoryIds: [], beforeBytes: 0, afterBytes: 0, reclaimedBytes: 0,
        wasBooted: device.isBooted, bootStateRestored: device.isBooted && preserveBootState)
    }
    try Task.checkCancellation()
    return try await cleanDisk(
      udid: udid, categoryIDs: categoryIDs,
      preserveBootState: preserveBootState)
  }
}
