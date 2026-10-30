import Foundation

struct InstalledSimulatorApp: Identifiable, Sendable, Equatable {
  var id: String { bundleID }
  let udid: String
  let deviceSet: String
  let bundleID: String
  let name: String
  let bundlePath: String
  let dataPath: String?
  let bundleBytes: Int64
  let documentsBytes: Int64?
  let otherDataBytes: Int64?
  let issue: String?
  var hasCompleteSize: Bool { issue == nil && documentsBytes != nil && otherDataBytes != nil }
  var totalBytes: Int64 { bundleBytes + (documentsBytes ?? 0) + (otherDataBytes ?? 0) }
  var canManage: Bool { issue == nil && !bundleID.hasPrefix("com.apple.") }
}

struct SimulatorAppStorage: Sendable {
  let apps: [InstalledSimulatorApp]
  let sharedBytes: Int64
  let mediaBytes: Int64
  let capturedAt = Date()
}

enum AppStorageAction: String, Sendable, CaseIterable, Identifiable {
  case uninstall, documents, data
  var id: String { rawValue }
  var title: String {
    switch self {
    case .uninstall: "Uninstall App"
    case .documents: "Delete Documents"
    case .data: "Clear App Data"
    }
  }
  var explanation: String {
    switch self {
    case .uninstall:
      "Removes this app and its private data using CoreSimulator. App Group data may remain."
    case .documents:
      "Permanently deletes this app's Documents contents. The app and its other data remain."
    case .data:
      "Permanently clears this app's preferences, databases, caches, and temporary files. Documents and shared App Group data remain. The app may require sign-in again."
    }
  }
}

/// Offline inventory is advisory. Every destructive action also resolves the
/// registered app and data container through simctl before stopping the device.
enum AppStorageStore {
  static func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T
  {
    let task = Task.detached(priority: .utility) {
      try Task.checkCancellation()
      let value = try work()
      try Task.checkCancellation()
      return value
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }

  static let metadata = ".com.apple.mobile_container_manager.metadata.plist"

  static func checkedPath(_ root: URL, _ path: URL) throws {
    try DiskStore.requireDescendant(root, path)
    var current = path.standardizedFileURL
    while current.path != root.standardizedFileURL.path {
      guard !DiskStore.isLink(try DiskStore.info(current)) else {
        throw SimulatorError("Refusing a symlink in app storage: \(current.path)")
      }
      current.deleteLastPathComponent()
    }
    try DiskStore.requireDirectory(root)
  }

  static func dictionary(_ root: URL, _ path: URL) throws -> [String: Any] {
    try checkedPath(root, path)
    guard DiskStore.isRegular(try DiskStore.info(path)),
      let value = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: path), format: nil) as? [String: Any]
    else { throw SimulatorError("Invalid container metadata: \(path.path)") }
    return value
  }

  static func identifier(_ root: URL, _ container: URL) throws -> String {
    let value = try dictionary(root, container.appendingPathComponent(metadata))
    guard let id = value["MCMMetadataIdentifier"] as? String,
      id.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]*$", options: .regularExpression) != nil
    else {
      throw SimulatorError("Container has no application identifier.")
    }
    return id
  }

  static func containerDirectories(_ root: URL, _ relative: String) throws -> [URL] {
    let parent = root.appendingPathComponent(relative)
    guard DiskStore.exists(parent) else { return [] }
    try checkedPath(root, parent)
    try DiskStore.requireDirectory(parent)
    return try DiskStore.children(parent).filter { entry in
      guard UUID(uuidString: entry.lastPathComponent) != nil else { return false }
      try checkedPath(root, entry)
      try DiskStore.requireDirectory(entry)
      return true
    }
  }

  static func size(_ root: URL, _ path: URL) throws -> Int64 {
    do { _ = try DiskStore.info(path) } catch let error as POSIXError where error.code == .ENOENT {
      return 0
    }
    try checkedPath(root, path)
    var bytes: Int64 = 0
    try DiskStore.walk(path) { _, info in
      try Task.checkCancellation()
      bytes += Int64(info.st_blocks) * 512
      return true
    }
    return bytes
  }

  static func scan(_ device: RawDevice) throws -> SimulatorAppStorage {
    let root = try DiskStore.dataDirectory(device).resolvingSymlinksInPath()
    var containers: [String: [URL]] = [:]
    var unreadableContainers = false
    for path in try containerDirectories(root, "Containers/Data/Application") {
      do { containers[try identifier(root, path), default: []].append(path) } catch {
        unreadableContainers = true
      }
    }
    var apps: [InstalledSimulatorApp] = []
    for container in try containerDirectories(root, "Containers/Bundle/Application") {
      try Task.checkCancellation()
      let id = try identifier(root, container)
      let bundles = try DiskStore.children(container).filter { $0.pathExtension == "app" }
      guard bundles.count == 1, let bundle = bundles.first else {
        throw SimulatorError(
          "Installed app container is ambiguous. Refresh after installation completes.")
      }
      let info = try dictionary(root, bundle.appendingPathComponent("Info.plist"))
      guard info["CFBundleIdentifier"] as? String == id else {
        throw SimulatorError("Installed bundle identifier does not match its container.")
      }
      let paths = containers[id] ?? []
      let dataPath = paths.count == 1 ? paths[0] : nil
      var documents: Int64?
      var other: Int64?
      var issue: String?
      if paths.count > 1 {
        issue = "Multiple data containers found. Refresh before managing this app."
      }
      if paths.isEmpty && unreadableContainers {
        issue = "Some container metadata could not be read."
      }
      if let dataPath {
        do {
          documents = try size(root, dataPath.appendingPathComponent("Documents"))
          other = try DiskStore.children(dataPath).filter {
            $0.lastPathComponent != "Documents"
              && !$0.lastPathComponent.hasPrefix(".com.apple.mobile_container_manager")
          }.reduce(Int64(0)) { try $0 + size(root, $1) }
        } catch { issue = error.localizedDescription }
      }
      apps.append(
        .init(
          udid: device.udid, deviceSet: device.set, bundleID: id,
          name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? id,
          bundlePath: bundle.resolvingSymlinksInPath().path,
          dataPath: dataPath?.resolvingSymlinksInPath().path,
          bundleBytes: try size(root, container), documentsBytes: documents,
          otherDataBytes: other, issue: issue))
    }
    guard Set(apps.map(\.bundleID)).count == apps.count else {
      throw SimulatorError(
        "Duplicate installed application identifiers. Refresh before managing apps.")
    }
    return .init(
      apps: apps.sorted { $0.totalBytes > $1.totalBytes },
      sharedBytes: try size(root, root.appendingPathComponent("Containers/Shared/AppGroup")),
      mediaBytes: try size(root, root.appendingPathComponent("Media")))
  }

  static func validate(_ device: RawDevice, app: InstalledSimulatorApp) throws
    -> InstalledSimulatorApp
  {
    guard app.udid == device.udid, app.deviceSet == device.set, app.canManage else {
      throw SimulatorError("This app cannot be managed on the selected simulator.")
    }
    let fresh = try scan(device)
    guard let current = fresh.apps.first(where: { $0.bundleID == app.bundleID }), current.canManage,
      current.bundlePath == app.bundlePath, current.dataPath == app.dataPath
    else {
      throw SimulatorError(
        "Application containers changed. Refresh the app list before continuing.")
    }
    return current
  }

  static func clear(_ device: RawDevice, app: InstalledSimulatorApp, action: AppStorageAction)
    throws
  {
    guard device.state == "Shutdown", action != .uninstall else {
      throw SimulatorError("App files can only be cleared while the simulator is shutdown.")
    }
    _ = try validate(device, app: app)
    let root = try DiskStore.dataDirectory(device).resolvingSymlinksInPath()
    guard let dataPath = app.dataPath else {
      throw SimulatorError("This app has no private data container.")
    }
    let container = URL(fileURLWithPath: dataPath)
    let expectedParent = root.appendingPathComponent("Containers/Data/Application")
    guard
      container.deletingLastPathComponent().resolvingSymlinksInPath().path
        == expectedParent.resolvingSymlinksInPath().path,
      UUID(uuidString: container.lastPathComponent) != nil,
      try identifier(root, container) == app.bundleID
    else {
      throw SimulatorError("App data container is not a validated private application container.")
    }
    let targets: [URL]
    if action == .documents {
      let documents = container.appendingPathComponent("Documents")
      targets = DiskStore.exists(documents) ? [documents] : []
    } else {
      targets = try DiskStore.children(container).filter {
        $0.lastPathComponent != "Documents"
          && !$0.lastPathComponent.hasPrefix(".com.apple.mobile_container_manager")
      }
    }
    // Validate the entire selection before deleting its first file.
    for path in targets { try checkedPath(root, path) }
    for path in targets {
      try Task.checkCancellation()
      try checkedPath(root, path)
      guard try identifier(root, container) == app.bundleID else {
        throw SimulatorError("App container identity changed during cleanup.")
      }
      if DiskStore.isDirectory(try DiskStore.info(path)) {
        for child in try DiskStore.children(path) {
          try Task.checkCancellation()
          try checkedPath(root, path)
          // Remove a child link itself; never traverse it during deletion.
          try FileManager.default.removeItem(at: child)
        }
      } else {
        try FileManager.default.removeItem(at: path)
      }
    }
  }
}

extension SwiftSimSlimBackend {
  func openPhotos(udid: String) async throws {
    let device = try await profileDevice(udid)
    try await bootAndWait(device)
    try await simctl(device, ["launch", device.udid, "com.apple.mobileslideshow"])
    _ = try await runner.run(
      "/usr/bin/open", ["-a", "Simulator", "--args", "-CurrentDeviceUDID", device.udid]
    ).checked()
  }

  func appStorage(udid: String) async throws -> SimulatorAppStorage {
    let device = try await profileDevice(udid)
    guard ["Booted", "Shutdown"].contains(device.state) else {
      throw SimulatorError("Wait for the simulator to finish changing state.")
    }
    stage("Measuring installed apps and private data…", device)
    return try await AppStorageStore.background { try AppStorageStore.scan(device) }
  }

  func manageApp(_ app: InstalledSimulatorApp, action: AppStorageAction) async throws {
    let device = try await profileDevice(app.udid)
    guard ["Booted", "Shutdown"].contains(device.state) else {
      throw SimulatorError("Wait for the simulator to finish changing state.")
    }
    _ = try await AppStorageStore.background { try AppStorageStore.validate(device, app: app) }
    var failure: Error?
    do {
      if !device.isBooted {
        try await bootAndWait(device)
      } else {
        try await simctl(device, ["bootstatus", device.udid, "-b"], timeout: 600)
      }
      try Task.checkCancellation()
      let bundle = try await simctl(
        device, ["get_app_container", device.udid, app.bundleID, "app"])
      guard URL(fileURLWithPath: bundle.text).resolvingSymlinksInPath().path == app.bundlePath
      else {
        throw SimulatorError(
          "Registered app bundle differs from the reviewed app. Refresh the list.")
      }
      if let path = app.dataPath {
        let data = try await simctl(
          device, ["get_app_container", device.udid, app.bundleID, "data"])
        guard URL(fileURLWithPath: data.text).resolvingSymlinksInPath().path == path else {
          throw SimulatorError(
            "Registered app data differs from the reviewed container. Refresh the list.")
        }
      } else if action != .uninstall {
        throw SimulatorError("No private app data container was found.")
      }
      try Task.checkCancellation()
      if action == .uninstall {
        stage("Uninstalling \(app.name)…", device)
        try await simctl(device, ["uninstall", device.udid, app.bundleID], timeout: 120)
        let after = try await appStorage(udid: device.udid)
        guard !after.apps.contains(where: { $0.bundleID == app.bundleID }) else {
          throw SimulatorError("CoreSimulator still reports the app after uninstall.")
        }
      } else {
        try await stop(device)
        let stopped = try await profileDevice(device.udid)
        guard stopped.set == device.set else {
          throw SimulatorError("Device set changed during cleanup.")
        }
        stage("\(action.title): \(app.name)…", device)
        try Task.checkCancellation()
        try await AppStorageStore.background {
          try AppStorageStore.clear(stopped, app: app, action: action)
        }
      }
    } catch { failure = error }
    // Return to the original boot state even after a failed or cancelled deletion.
    do {
      try await Task.detached {
        let current = try await find(device.udid, set: device.set)
        if device.isBooted && !current.isBooted {
          try await bootAndWait(current)
        } else if !device.isBooted && current.state != "Shutdown" {
          try await stop(current)
        }
      }.value
    } catch {
      throw SimulatorError(
        "\(failure?.localizedDescription ?? "App storage operation finished.") Boot-state recovery failed: \(error.localizedDescription)"
      )
    }
    if let failure { throw failure }
  }
}
