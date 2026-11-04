import Foundation

/// Explicit wallpaper reset, deliberately excluded from routine disk cleanup / Full Slim.
enum WallpaperMode {
  static let service = "com.apple.PosterBoard"

  static func store(_ root: URL) throws -> URL {
    try DiskStore.requireDirectory(root)
    let target = root.appendingPathComponent(DiskStore.posterStorePath)
    // Validate ancestors even when the store is absent. Never follow a redirected parent.
    for relative in ["Library", "Library/Application Support", DiskStore.posterStorePath] {
      let path = root.appendingPathComponent(relative)
      if DiskStore.exists(path) {
        try DiskStore.requireUnlinkedDescendant(root, path)
        try DiskStore.requireDirectory(path)
      }
    }
    if DiskStore.exists(target) {
      try DiskStore.walk(target) { path, info in
        try Task.checkCancellation()
        guard !DiskStore.isLink(info), DiskStore.isDirectory(info) || DiskStore.isRegular(info)
        else {
          throw SimulatorError("Wallpaper reset refuses links or special files: \(path.path)")
        }
        return true
      }
    }
    return target
  }

  static func reset(_ root: URL) throws -> Int64 {
    let target = try store(root)
    guard DiskStore.exists(target) else { return 0 }
    let bytes = try DiskStore.allocatedSize(target)
    try Task.checkCancellation()
    // Removing this exact store, rather than its contents, is necessary for the black fallback.
    try FileManager.default.removeItem(at: target)
    return bytes
  }
}

extension SwiftSimSlimBackend {
  func enableBlackWallpaper(
    udid: String, preserveBootState: Bool,
    save: @Sendable (ServiceStateBackup) async throws -> Void
  ) async throws -> SimulatorDiskCleanupResult {
    let device = try await profileDevice(udid)
    guard ["Booted", "Shutdown"].contains(device.state),
      ServiceCatalog.supportsPersistence(device.osVersion),
      ServiceCatalog.slimmable.contains(WallpaperMode.service)
    else {
      throw SimulatorError("This simulator state or runtime does not support wallpaper mode.")
    }
    let root = try DiskStore.dataDirectory(device)
    _ = try await Task.detached(priority: .utility) { try WallpaperMode.store(root) }.value
    var removed: Int64 = 0
    do {
      stage("Checking wallpaper service…", device)
      if !device.isBooted {
        try await bootAndWait(device)
      } else {
        try await simctl(device, ["bootstatus", udid, "-b"], timeout: 600)
      }
      let original = try await disabled(device)
      if !original.contains(WallpaperMode.service) {
        try await save(ServiceStateBackup(device: device, disabled: original))
        try Task.checkCancellation()
        try await simctl(
          device, ["spawn", udid, "launchctl", "disable", "system/" + WallpaperMode.service])
      }
      // Only this allowlisted label changes; all other managed/unmanaged overrides stay intact.
      if try await loadedServices(device).contains(WallpaperMode.service) {
        try await simctl(
          device, ["spawn", udid, "launchctl", "bootout", "system/" + WallpaperMode.service])
      }
      try await verifyWallpaperDisabled(device)
      try await stop(device)
      let stopped = try await profileDevice(udid)
      guard stopped.set == device.set, stopped.state == "Shutdown",
        try DiskStore.dataDirectory(stopped) == root
      else {
        throw SimulatorError("Simulator identity or data path changed; wallpapers were not reset.")
      }
      stage("Removing wallpaper originals, settings, and snapshots…", device)
      try Task.checkCancellation()
      let task = Task.detached(priority: .utility) { try WallpaperMode.reset(root) }
      removed = try await withTaskCancellationHandler {
        try await task.value
      } onCancel: {
        task.cancel()
      }
      stage("Verifying wallpaper mode after restart…", device)
      try await bootAndWait(device)
      try await verifyWallpaperDisabled(device)
      if !device.isBooted || !preserveBootState { try await stop(device) }
    } catch {
      let failure = error
      // Cancellation must not skip restoring the requested boot state.
      do {
        try await Task.detached {
          let current = try await find(udid, set: device.set)
          if device.isBooted && preserveBootState {
            if !current.isBooted { try await bootAndWait(current) }
          } else if current.state != "Shutdown" {
            try await stop(current)
          }
        }.value
      } catch {
        throw SimulatorError(
          "\(failure.localizedDescription) Boot-state recovery also failed: \(error.localizedDescription)"
        )
      }
      throw SimulatorError(
        "Wallpaper mode did not finish: \(failure.localizedDescription). PosterBoard may already be disabled; use Restore Saved State to restore services. Removed wallpapers cannot be recovered that way."
      )
    }
    return .init(
      udid: udid, categoryIds: ["wallpaper-reset"], beforeBytes: removed, afterBytes: 0,
      reclaimedBytes: removed, wasBooted: device.isBooted,
      bootStateRestored: device.isBooted && preserveBootState)
  }

  private func verifyWallpaperDisabled(_ device: RawDevice) async throws {
    guard try await disabled(device).contains(WallpaperMode.service),
      try await !loadedServices(device).contains(WallpaperMode.service)
    else {
      throw SimulatorError(
        "PosterBoard is still enabled or loaded. Wallpaper mode was not verified.")
    }
  }
}
