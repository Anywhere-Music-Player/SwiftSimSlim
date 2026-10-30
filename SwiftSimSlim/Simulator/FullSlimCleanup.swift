import Foundation

extension SwiftSimSlimBackend {
  /// One coordinated operation. A failed profile/backup must never proceed to deletion.
  func fullSlimAndClean(
    udid: String, preserveBootState: Bool,
    save: @Sendable (ServiceStateBackup) async throws -> Void
  ) async throws -> SimulatorDiskCleanupResult {
    let device = try await profileDevice(udid)
    // Validate the cleanup root before changing any services.
    _ = try DiskStore.dataDirectory(device)
    try Task.checkCancellation()
    try await configureWithBackup(
      udid: udid, desired: ServiceCatalog.slimmable, preserveBootState: true, save: save)
    try Task.checkCancellation()
    return try await cleanDisk(
      udid: udid, categoryIDs: Set(DiskStore.categories.filter(\.canClean).map(\.id)),
      preserveBootState: preserveBootState)
  }
}
