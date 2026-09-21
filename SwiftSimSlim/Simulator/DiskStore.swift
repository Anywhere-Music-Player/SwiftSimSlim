import Darwin
import Foundation

enum DiskStore {
  static let categories: [DiskCleanupCategory] = [
    .init(
      id: "caches", name: "System & App Caches",
      description: "Generated cache files belonging to iOS and installed apps.",
      downside: "Next launches may be slower; downloaded or offline cache content can disappear.",
      recovery: "Apps build new caches as needed.", risk: "Lower risk", defaultSelected: true,
      canClean: true),
    .init(
      id: "logs", name: "Logs & Diagnostics",
      description: "Unified logs, signposts, crash logs, and app log folders.",
      downside: "Existing diagnostic and crash history is deleted.",
      recovery: "Future runs create new logs.", risk: "Lower risk", defaultSelected: true,
      canClean: true),
    .init(
      id: "temporary", name: "Temporary Files",
      description: "Simulator and app temporary directories.",
      downside: "Apps that misuse temporary storage may lose in-progress work.",
      recovery: "Apps create new temporary files as needed.", risk: "Lower risk",
      defaultSelected: true, canClean: true),
    .init(
      id: "linguistic-data", name: "Downloaded Language Data",
      description: "On-demand models used by Siri, Search, and text analysis.",
      downside: "Language-aware features may be limited until iOS downloads the package again.",
      recovery: "iOS downloads the package again when needed.", risk: "Restored on demand",
      defaultSelected: false, canClean: true),
    .init(
      id: "required-siri-assets", name: "Required Siri Assets",
      description: "Siri, speech, voice, and accessibility downloads restored by iOS.",
      downside: "Manual deletion is unsupported.", recovery: "Required assets return after boot.",
      risk: "System managed", defaultSelected: false, canClean: false),
  ]
  static let protectedNames: Set<String> = [
    "Documents", "Mobile Documents", "Media", "MobileAsset",
  ]
  static var fm: FileManager { FileManager.default }

  static func info(_ url: URL) throws -> stat {
    var result = stat()
    guard lstat(url.path, &result) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return result
  }
  static func isDirectory(_ info: stat) -> Bool { (info.st_mode & S_IFMT) == S_IFDIR }
  static func isLink(_ info: stat) -> Bool { (info.st_mode & S_IFMT) == S_IFLNK }
  static func isRegular(_ info: stat) -> Bool { (info.st_mode & S_IFMT) == S_IFREG }
  static func exists(_ url: URL) -> Bool { (try? info(url)) != nil }
  static func requireDirectory(_ url: URL) throws {
    guard isDirectory(try info(url)) else {
      throw SimulatorError("Not a real directory: \(url.path)")
    }
  }
  static func dataDirectory(_ device: RawDevice) throws -> URL {
    guard let path = device.dataPath, !path.isEmpty, path.hasPrefix("/") else {
      throw SimulatorError("simctl reported no valid data path.")
    }
    let root = URL(fileURLWithPath: path).standardizedFileURL
    try requireDirectory(root)
    return root
  }
  static func contains(_ root: URL, _ target: URL, allowRoot: Bool = false) -> Bool {
    let root = root.standardizedFileURL.path
    let target = target.standardizedFileURL.path
    return (allowRoot && root == target) || target.hasPrefix(root + "/")
  }
  static func requireDescendant(_ root: URL, _ target: URL) throws {
    guard contains(root, target),
      contains(root.resolvingSymlinksInPath(), target.resolvingSymlinksInPath())
    else {
      throw SimulatorError("Refusing a path outside simulator data: \(target.path)")
    }
  }
  static func children(_ directory: URL) throws -> [URL] {
    try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted {
      $0.path < $1.path
    }
  }
  /// lstat-based traversal never follows symlink directories.
  static func walk(_ root: URL, visit: (URL, stat) throws -> Bool) throws {
    let data = try info(root)
    if try visit(root, data), isDirectory(data) {
      for child in try children(root) { try walk(child, visit: visit) }
    }
  }
  static func allocatedSize(_ root: URL, excluding: Set<String> = []) throws -> Int64 {
    var total: Int64 = 0
    try walk(root) { path, data in
      if path != root && isDirectory(data) && excluding.contains(path.lastPathComponent) {
        return false
      }
      total += Int64(data.st_blocks) * 512
      return true
    }
    return total
  }
  static func compact(_ root: URL, _ candidates: [URL]) throws -> [URL] {
    var result: [URL] = []
    for candidate in Set(candidates.map(\.standardizedFileURL)).sorted(by: {
      $0.path.count < $1.path.count
    }) {
      guard contains(root, candidate) else {
        throw SimulatorError("Cleanup candidate is outside the simulator.")
      }
      let data: stat
      do { data = try info(candidate) } catch let error as POSIXError where error.code == .ENOENT {
        continue
      }
      guard isDirectory(data) else { continue }
      try requireDescendant(root, candidate)
      if !result.contains(where: { contains($0, candidate, allowRoot: true) }) {
        result.append(candidate)
      }
    }
    return result
  }
  static func named(_ root: URL, name: String, excluding: Set<String> = []) throws -> [URL] {
    var result: [URL] = []
    try walk(root) { url, data in
      guard isDirectory(data), url != root else { return true }
      if protectedNames.contains(url.lastPathComponent) || excluding.contains(url.lastPathComponent)
        || url.pathExtension == "app"
        || contains(root.appendingPathComponent("Containers/Bundle"), url, allowRoot: true)
      {
        return false
      }
      if url.lastPathComponent == name {
        result.append(url)
        return false
      }
      return true
    }
    return result
  }
  static func targets(_ root: URL, category: String) throws -> [URL] {
    var candidates: [URL]
    switch category {
    case "caches": candidates = try named(root, name: "Caches")
    case "temporary": candidates = try named(root, name: "tmp", excluding: ["Caches"])
    case "logs":
      candidates = ["Library/Logs", "var/log", "var/db/diagnostics", "var/db/uuidtext"].map(
        root.appendingPathComponent)
      candidates += try named(root, name: "Logs", excluding: ["Caches", "tmp"])
    case "linguistic-data":
      candidates = [
        root.appendingPathComponent(
          "private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_LinguisticData")
      ]
    case "required-siri-assets":
      let assets = root.appendingPathComponent("private/var/MobileAsset/AssetsV2")
      if !exists(assets) { return [] }
      try requireDirectory(assets)
      try requireDescendant(root, assets)
      let prefixes = [
        "com_apple_MobileAsset_UAF_Siri_", "com_apple_MobileAsset_TTS",
        "com_apple_MobileAsset_VoiceServices_", "com_apple_MobileAsset_VoiceTrigger",
      ]
      candidates = try children(assets).filter { url in
        prefixes.contains { url.lastPathComponent.hasPrefix($0) }
      }
    default: throw SimulatorError("Unknown cleanup category: \(category)")
    }
    return try compact(root, candidates)
  }
  static func clear(_ root: URL, target: URL) throws {
    guard exists(target) else { return }
    try requireDirectory(root)
    try requireDirectory(target)
    try requireDescendant(root, target)
    for child in try children(target) {
      // Recheck the parent before each removal; do not follow a child symlink.
      try requireDirectory(target)
      try requireDescendant(root, target)
      try fm.removeItem(at: child)
    }
  }
  static func selection(_ ids: Set<String>) throws -> [String] {
    guard !ids.isEmpty, ids.isSubset(of: Set(categories.filter(\.canClean).map(\.id))) else {
      throw SimulatorError(
        "Select at least one supported cleanup category. Required system assets cannot be deleted.")
    }
    return ids.sorted()
  }
  static func storage(_ root: URL) throws -> [SimulatorDiskStorageMeasurement] {
    let containers = ["Containers/Data/Application", "Containers/Shared/AppGroup"].map(
      root.appendingPathComponent)
    var documents: [URL] = []
    var appBytes: Int64 = 0
    for container in try compact(root, containers) {
      for app in try children(container) where isDirectory(try info(app)) {
        documents.append(app.appendingPathComponent("Documents"))
      }
      appBytes += try allocatedSize(container, excluding: ["Caches", "Documents", "Logs", "tmp"])
    }
    func size(_ candidates: [URL]) throws -> Int64 {
      try compact(root, candidates).reduce(0) { try $0 + allocatedSize($1) }
    }
    return [
      .init(
        id: "installed-apps", name: "Installed Apps",
        description: "Developer-installed app and test-runner bundles.",
        bytes: try size([root.appendingPathComponent("Containers/Bundle/Application")])),
      .init(
        id: "documents", name: "Documents", description: "App and app-group Documents directories.",
        bytes: try size(documents)),
      .init(
        id: "app-data", name: "App Data",
        description: "Preferences, databases, and support files outside cleanup categories.",
        bytes: appBytes),
      .init(
        id: "user-media", name: "User Media", description: "Photos, videos, and downloads.",
        bytes: try size([root.appendingPathComponent("Media")])),
    ]
  }
  static func plan(udid: String, root: URL) throws -> SimulatorDiskCleanupPlan {
    try requireDirectory(root)
    var measurements: [SimulatorDiskCleanupMeasurement] = []
    var total: Int64 = 0
    var cleanable: Int64 = 0
    for category in categories {
      let targets = try targets(root, category: category.id)
      let bytes = try targets.reduce(Int64(0)) { try $0 + allocatedSize($1) }
      measurements.append(.init(id: category.id, bytes: bytes, targets: targets.count))
      total += bytes
      if category.canClean { cleanable += bytes }
    }
    return .init(
      udid: udid, totalBytes: total, cleanableBytes: cleanable, categories: measurements,
      storage: try storage(root))
  }
}

extension SwiftSimSlimBackend {
  func diskCleanupPlan(udid: String) async throws -> SimulatorDiskCleanupPlan {
    let device = try await find(udid)
    let root = try DiskStore.dataDirectory(device)
    stage("Analyzing disk usage…", device)
    return try await Task.detached(priority: .utility) {
      try DiskStore.plan(udid: udid, root: root)
    }.value
  }
  func cleanDisk(udid: String, categoryIDs: Set<String>, preserveBootState: Bool) async throws
    -> SimulatorDiskCleanupResult
  {
    let ids = try DiskStore.selection(categoryIDs)
    let device = try await find(udid)
    let root = try DiskStore.dataDirectory(device)
    // Always wait for full shutdown before touching files, including transient states.
    try await stop(device)
    stage("Cleaning selected disk categories…", device)
    var failure: Error?
    var before: Int64 = 0
    var after: Int64 = 0
    do {
      (before, after) = try await Task.detached(priority: .utility) {
        let plan = try DiskStore.plan(udid: udid, root: root)
        let before = ids.reduce(Int64(0)) { $0 + plan.bytes(for: $1) }
        for id in ids {
          for target in try DiskStore.targets(root, category: id) {
            try DiskStore.clear(root, target: target)
          }
        }
        let updated = try DiskStore.plan(udid: udid, root: root)
        return (before, ids.reduce(Int64(0)) { $0 + updated.bytes(for: $1) })
      }.value
    } catch { failure = error }
    if device.isBooted && preserveBootState {
      do { try await bootAndWait(device) } catch {
        throw SimulatorError(
          "\(failure?.localizedDescription ?? "Cleanup finished.")\nCould not restore boot state: \(error.localizedDescription)"
        )
      }
    }
    if let failure { throw failure }
    return .init(
      udid: udid, categoryIds: ids, beforeBytes: before, afterBytes: after,
      reclaimedBytes: max(0, before - after), wasBooted: device.isBooted,
      bootStateRestored: device.isBooted && preserveBootState)
  }
}
