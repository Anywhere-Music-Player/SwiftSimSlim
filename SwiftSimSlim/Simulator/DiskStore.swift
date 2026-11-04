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
      id: "wallpaper-cache", name: "Wallpaper & Poster Cache",
      description: "Generated wallpaper snapshots, including accumulated Home Screen textures.",
      downside: "Wallpaper previews may temporarily disappear or load more slowly.",
      recovery:
        "iOS may regenerate snapshots; the cache can grow again. Originals and settings are kept.",
      risk: "Optional cleanup", defaultSelected: false, canClean: true),
    .init(
      id: "required-siri-assets", name: "Downloaded Siri & Speech Assets",
      description: "Known per-simulator Siri and system speech asset catalogs.",
      downside: "Siri, dictation, and system voices may be unavailable until assets return.",
      recovery: "iOS may restore these downloads after boot, even when Siri services are disabled.",
      risk: "Experimental cleanup", defaultSelected: false, canClean: true),
    .init(
      id: "system-models", name: "Other Downloaded System Models",
      description: "Known Search, suggestions, handwriting, motion, and other model catalogs.",
      downside: "Features using these models may stop working until iOS restores them.",
      recovery: "Downloads may return after boot. Unknown catalogs and custom voices are kept.",
      risk: "Experimental cleanup", defaultSelected: false, canClean: true),
    .init(
      id: "intelligence-data", name: "System Intelligence History & Indexes",
      description: "IntelligencePlatform, Biome, and DuetExpertCenter data only.",
      downside:
        "Deletes learned suggestions and system activity history. Personalization is reset.",
      recovery:
        "Services may rebuild indexes and collect new history. Deleted history cannot be restored.",
      risk: "Resets personalization", defaultSelected: false, canClean: true),
  ]
  static let protectedNames: Set<String> = [
    "Documents", "Mobile Documents", "Media", "MobileAsset", "PRBPosterExtensionDataStore",
    "IntelligencePlatform", "Biome", "DuetExpertCenter",
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
  static func compact(_ root: URL, _ candidates: [URL], allowFiles: Bool = false) throws -> [URL] {
    var result: [URL] = []
    var resultPaths: [String] = []
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
      guard isDirectory(data) || (allowFiles && isRegular(data)) else { continue }
      try requireDescendant(root, candidate)
      let path = candidate.path
      if !resultPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
        result.append(candidate)
        resultPaths.append(path)
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
          "private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_LinguisticData"),
        root.appendingPathComponent(
          "private/var/MobileAsset/AssetsV2/com_apple_MobileAsset_UAF_LinguisticData"),
      ]
    case "system-models":
      candidates = [
        "com_apple_MobileAsset_UAF_SearchQueryUnderstanding",
        "com_apple_MobileAsset_UAF_SearchQueryUnderstandingOverrides",
        "com_apple_MobileAsset_CoreSuggestions", "com_apple_MobileAsset_CoreSuggestionsModels",
        "com_apple_MobileAsset_UAF_Handwriting_Synthesis",
        "com_apple_MobileAsset_UAF_MotionAnomalyFM",
        "com_apple_MobileAsset_UAF_CoreMotion_IMUFoundationModel",
        "com_apple_MobileAsset_GeoPolygonDataAssets",
        "com_apple_MobileAsset_UAF_Music_ConcertsRanking", "com_apple_MobileAsset_UAF_FM_Overrides",
        "com_apple_MobileAsset_SharingDeviceAssets",
      ].map { root.appendingPathComponent("private/var/MobileAsset/AssetsV2/" + $0) }
    case "wallpaper-cache":
      candidates = try posterSnapshotCaches(root)
    case "intelligence-data":
      candidates = ["Library/IntelligencePlatform", "Library/Biome", "Library/DuetExpertCenter"]
        .map(
          root.appendingPathComponent)
    case "required-siri-assets":
      let assets = root.appendingPathComponent("private/var/MobileAsset/AssetsV2")
      if !exists(assets) { return [] }
      try requireDirectory(assets)
      try requireDescendant(root, assets)
      let catalogs: Set<String> = [
        "com_apple_MobileAsset_UAF_Siri_DialogAssets",
        "com_apple_MobileAsset_UAF_Siri_UnderstandingASRHammer",
        "com_apple_MobileAsset_UAF_Siri_Understanding",
        "com_apple_MobileAsset_UAF_Siri_TextToSpeech",
        "com_apple_MobileAsset_UAF_Siri_FindMyConfigurationFiles",
        "com_apple_MobileAsset_SiriInferenceHolidays",
        "com_apple_MobileAsset_TTSAXResourceModelAssets",
        "com_apple_MobileAsset_VoiceTriggerAssetsStudioDisplay",
        "com_apple_MobileAsset_VoiceServices_CombinedVocalizerVoices",
        "com_apple_MobileAsset_MacinTalkVoiceAssets",
      ]
      candidates = try children(assets).filter { catalogs.contains($0.lastPathComponent) }
    default: throw SimulatorError("Unknown cleanup category: \(category)")
    }
    return try compact(root, candidates, allowFiles: category == "wallpaper-cache")
  }
  /// Reject even in-root symlink redirects into durable app data.
  static func requireUnlinkedDescendant(_ root: URL, _ target: URL) throws {
    try requireDescendant(root, target)
    var current = root
    let components = target.standardizedFileURL.pathComponents.dropFirst(
      root.standardizedFileURL.pathComponents.count)
    for component in components {
      current.appendPathComponent(component)
      guard !isLink(try info(current)) else {
        throw SimulatorError("Refusing a symlink in cleanup path: \(current.path)")
      }
    }
  }

  /// Only observed generated snapshot layouts are eligible; never clear a version or its contents.
  static let posterStorePath = "Library/Application Support/PRBPosterExtensionDataStore"

  static func isPosterVersionEntry(_ parts: [String]) -> Bool {
    parts.count >= 8 && Int(parts[0]) != nil && parts[1] == "Extensions"
      && parts[2].hasPrefix("com.apple.")
      && ["configurations", "descriptors", "staticdescriptors"].contains(parts[3])
      && UUID(uuidString: parts[4]) != nil && parts[5] == "versions" && Int(parts[6]) != nil
  }

  static func isPosterRuntimeSnapshot(_ root: URL, _ target: URL) -> Bool {
    let store = root.appendingPathComponent(posterStorePath)
    guard contains(store, target) else { return false }
    let parts = Array(
      target.standardizedFileURL.pathComponents.dropFirst(
        store.standardizedFileURL.pathComponents.count))
    return parts.count == 8 && isPosterVersionEntry(parts)
      && target.lastPathComponent.range(
        of: "^RuntimeSnapshot-[a-f0-9]{64}-home\\.atx$", options: .regularExpression) != nil
  }

  static func posterSnapshotCaches(_ root: URL) throws -> [URL] {
    let store = root.appendingPathComponent(posterStorePath)
    guard exists(store) else { return [] }
    try requireDirectory(store)
    try requireUnlinkedDescendant(root, store)
    let baseCount = store.standardizedFileURL.pathComponents.count
    var candidates: [URL] = []
    try walk(store) { url, data in
      try Task.checkCancellation()
      let parts = Array(url.standardizedFileURL.pathComponents.dropFirst(baseCount))
      guard isPosterVersionEntry(parts) else { return true }
      if parts.count == 9, parts[7] == "scratch",
        parts[8] == "SnapshotCache.cachedb", isDirectory(data)
      {
        candidates.append(url)
        return false
      }
      if isRegular(data), isPosterRuntimeSnapshot(root, url) {
        candidates.append(url)
      }
      return true
    }
    return candidates
  }
  static func clear(_ root: URL, target: URL) throws {
    guard exists(target) else { return }
    try requireDirectory(root)
    try requireUnlinkedDescendant(root, target)
    let data = try info(target)
    if isRegular(data) {
      // File targets are generated wallpaper textures only, revalidated at deletion time.
      guard isPosterRuntimeSnapshot(root, target) else {
        throw SimulatorError("Refusing an unrecognized cleanup file: \(target.path)")
      }
      try fm.removeItem(at: target)
      return
    }
    try requireDirectory(target)
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
        "Select at least one supported cleanup category. Unknown system paths cannot be deleted.")
    }
    return ids.sorted()
  }
  static func plan(udid: String, root: URL) throws -> SimulatorDiskCleanupPlan {
    try Task.checkCancellation()
    let root = root.standardizedFileURL
    try requireDirectory(root)
    let categoryTargets = try categories.map { try targets(root, category: $0.id) }
    let containers = ["Containers/Data/Application", "Containers/Shared/AppGroup"].map(
      root.appendingPathComponent)
    var documents: [URL] = []
    for container in try compact(root, containers) {
      for app in try children(container) where isDirectory(try info(app)) {
        documents.append(app.appendingPathComponent("Documents"))
      }
    }
    // Earlier regions take precedence. Every allocated block belongs to one displayed bucket.
    let regions: [(id: String, roots: [URL])] = [
      ("installed-apps", [root.appendingPathComponent("Containers/Bundle/Application")]),
      ("documents", documents),
      ("app-data", containers),
      ("user-media", [root.appendingPathComponent("Media")]),
      (
        "wallpapers",
        [root.appendingPathComponent("Library/Application Support/PRBPosterExtensionDataStore")]
      ),
      ("system-assets", [root.appendingPathComponent("private/var/MobileAsset")]),
    ]
    // Normalize once. Descendants inherit their bucket instead of comparing each file
    // against every target via standardizedFileURL (which can perform filesystem I/O).
    var categoryAtPath: [String: Int] = [:]
    for index in categories.indices.reversed() {
      for target in categoryTargets[index] {
        categoryAtPath[target.standardizedFileURL.path] = index
      }
    }
    var regionAtPath: [String: Int] = [:]
    for index in regions.indices.reversed() {
      for target in regions[index].roots { regionAtPath[target.standardizedFileURL.path] = index }
    }
    var categoryBytes = Array(repeating: Int64(0), count: categories.count)
    var storageBytes: [String: Int64] = [:]
    var total: Int64 = 0
    func scan(_ url: URL, path: String, category: Int? = nil, region: Int? = nil) throws {
      try Task.checkCancellation()
      let data: stat
      do {
        data = try info(url)
      } catch let error as POSIXError where error.code == .ENOENT && url != root {
        // A running simulator may remove a transient file during this read-only scan.
        return
      }
      let category = [category, categoryAtPath[path]].compactMap { $0 }.min()
      let region = [region, regionAtPath[path]].compactMap { $0 }.min()
      let bytes = Int64(data.st_blocks) * 512
      total += bytes
      if let category { categoryBytes[category] += bytes }
      if category.map({ !categories[$0].canClean }) ?? true {
        let id = region.map { regions[$0].id } ?? "other-system-data"
        storageBytes[id, default: 0] += bytes
      }
      if isDirectory(data) {
        let entries: [URL]
        do {
          entries = try children(url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile && url != root {
          return
        }
        for child in entries {
          try scan(
            child, path: path + "/" + child.lastPathComponent, category: category, region: region)
        }
      }
    }
    try scan(root, path: root.path)
    let measurements = categories.indices.map {
      SimulatorDiskCleanupMeasurement(
        id: categories[$0].id, bytes: categoryBytes[$0], targets: categoryTargets[$0].count)
    }
    let descriptions: [(String, String, String)] = [
      ("installed-apps", "Installed Apps", "Developer-installed app and test-runner bundles."),
      ("documents", "Documents", "App and app-group Documents directories."),
      (
        "app-data", "App Data",
        "Preferences, databases, and support files outside cleanup categories."
      ),
      ("user-media", "User Media", "Photos, videos, and downloads."),
      (
        "wallpapers", "Wallpaper Originals & Other Data",
        "Originals, settings, and unrecognized poster files are kept. Recognized generated snapshots can be removed under Wallpaper & Poster Cache above."
      ),
      (
        "system-assets", "Other System Assets",
        "Other downloads and custom voices. Known Siri catalogs are offered for cleanup above."
      ),
      (
        "other-system-data", "Other System Data",
        "Remaining system containers and durable data, including Health, Home, and Shortcuts. Use Erase to reset the whole simulator."
      ),
    ]
    return .init(
      udid: udid, totalBytes: total,
      cleanableBytes: categories.indices.filter { categories[$0].canClean }.reduce(0) {
        $0 + categoryBytes[$1]
      }, categories: measurements,
      storage: descriptions.map {
        .init(id: $0.0, name: $0.1, description: $0.2, bytes: storageBytes[$0.0, default: 0])
      })
  }
}

extension SwiftSimSlimBackend {
  func diskCleanupPlan(udid: String) async throws -> SimulatorDiskCleanupPlan {
    let device = try await find(udid)
    let root = try DiskStore.dataDirectory(device)
    stage("Analyzing disk usage…", device)
    let task = Task.detached(priority: .utility) {
      try DiskStore.plan(udid: udid, root: root)
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
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
