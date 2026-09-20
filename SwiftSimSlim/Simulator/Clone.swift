import Darwin
import Foundation

struct ClonePaths: Sendable {
  let source: RawDevice
  let clone: RawDevice
  let sourceData: URL
  let cloneData: URL
  var sourceRoot: URL { sourceData.deletingLastPathComponent() }
  var cloneRoot: URL { cloneData.deletingLastPathComponent() }
  var sourceLogs: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Logs/CoreSimulator/" + source.udid)
  }
  var cloneLogs: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Logs/CoreSimulator/" + clone.udid)
  }

  static func rebase(_ path: URL, from source: URL, to clone: URL) -> URL? {
    guard DiskStore.contains(source, path, allowRoot: true) else { return nil }
    return URL(
      fileURLWithPath: clone.path
        + path.standardizedFileURL.path.dropFirst(source.standardizedFileURL.path.count))
  }
  func sourceReference(_ path: URL) -> Bool {
    DiskStore.contains(sourceRoot, path, allowRoot: true)
      || DiskStore.contains(sourceLogs, path, allowRoot: true)
  }
  func validate() throws {
    guard UUID(uuidString: source.udid) != nil, UUID(uuidString: clone.udid) != nil,
      source.udid != clone.udid, source.set == clone.set,
      sourceRoot != cloneRoot
    else {
      throw SimulatorError(
        "Clone source and destination must be distinct and in the same device set.")
    }
    for url in [sourceData, cloneData, sourceRoot, cloneRoot] {
      try DiskStore.requireDirectory(url)
    }
    try DiskStore.requireDescendant(sourceRoot, sourceData)
    try DiskStore.requireDescendant(cloneRoot, cloneData)
    guard
      !DiskStore.contains(
        sourceRoot.resolvingSymlinksInPath(), cloneRoot.resolvingSymlinksInPath(), allowRoot: true),
      !DiskStore.contains(
        cloneRoot.resolvingSymlinksInPath(), sourceRoot.resolvingSymlinksInPath(), allowRoot: true)
    else {
      throw SimulatorError("Clone and source directories overlap.")
    }
  }
  func sanitize() throws {
    try validate()
    let lsd = cloneData.appendingPathComponent("var/db/lsd")
    if DiskStore.exists(lsd) {
      try DiskStore.requireDirectory(lsd)
      try DiskStore.requireDescendant(cloneData, lsd)
      for file in try DiskStore.children(lsd)
      where file.lastPathComponent.hasPrefix("com.apple.LaunchServices-")
        && file.lastPathComponent.contains(".csstore")
      {
        try removeRegular(file)
      }
    }
    let frontboard = cloneData.appendingPathComponent("Library/FrontBoard")
    if DiskStore.exists(frontboard) {
      try DiskStore.requireDirectory(frontboard)
      try DiskStore.requireDescendant(cloneData, frontboard)
      for name in ["applicationState.db", "applicationState.db-shm", "applicationState.db-wal"] {
        let file = frontboard.appendingPathComponent(name)
        if DiskStore.exists(file) { try removeRegular(file) }
      }
    }
    var directories = [
      "Library/AppleMediaServices/Engagement/internal/database", "Library/Spotlight",
      "Library/chronod/replicator", "Library/com.apple.nsurlsessiond",
      "private/var/MobileAsset/AssetsV2/locks", "private/var/MobileAsset/AssetsV2/persisted",
      "private/var/db/assetsubscriptiond/history", "var/db/diagnostics/Persist",
      "var/db/diagnostics/Special",
      "Library/Caches", "tmp",
    ].map(cloneData.appendingPathComponent)
    let groups = cloneData.appendingPathComponent("Containers/Shared/AppGroup")
    if DiskStore.exists(groups) {
      try DiskStore.requireDirectory(groups)
      try DiskStore.requireDescendant(cloneData, groups)
      for group in try DiskStore.children(groups)
      where DiskStore.isDirectory(try DiskStore.info(group)) {
        directories.append(group.appendingPathComponent("replicatord"))
      }
    }
    for directory in directories { try DiskStore.clear(cloneData, target: directory) }
    let from = Data(source.udid.utf8)
    let to = Data(clone.udid.utf8)
    try DiskStore.walk(cloneRoot) { path, info in
      if DiskStore.isRegular(info), path.pathExtension.lowercased() == "plist" {
        var data = try Data(contentsOf: path)
        var offset = data.startIndex
        var changed = false
        while offset < data.endIndex, let range = data.range(of: from, in: offset..<data.endIndex) {
          data.replaceSubrange(range, with: to)
          offset = range.upperBound
          changed = true
        }
        if changed {
          try data.write(to: path, options: .atomic)
          guard chmod(path.path, info.st_mode & 0o777) == 0 else { throw POSIXError(.EACCES) }
        }
      } else if DiskStore.isLink(info) {
        let original = try DiskStore.fm.destinationOfSymbolicLink(atPath: path.path)
        let target = URL(fileURLWithPath: original, relativeTo: path.deletingLastPathComponent())
          .standardizedFileURL
        if let mapped = Self.rebase(target, from: sourceRoot, to: cloneRoot)
          ?? Self.rebase(target, from: sourceLogs, to: cloneLogs)
        {
          let temporary = path.deletingLastPathComponent().appendingPathComponent(
            ".swiftsimslim-link-" + UUID().uuidString)
          defer { try? DiskStore.fm.removeItem(at: temporary) }
          try DiskStore.fm.createSymbolicLink(
            atPath: temporary.path, withDestinationPath: mapped.path)
          guard Darwin.rename(temporary.path, path.path) == 0 else { throw POSIXError(.EIO) }
        }
      }
      return true
    }
    try verify()
  }
  private func removeRegular(_ url: URL) throws {
    try DiskStore.requireDescendant(cloneData, url)
    guard DiskStore.isRegular(try DiskStore.info(url)) else {
      throw SimulatorError("Refusing non-regular cloned registry: \(url.path)")
    }
    try DiskStore.fm.removeItem(at: url)
  }
  func verify() throws {
    try validate()
    try DiskStore.walk(cloneRoot) { path, info in
      if DiskStore.isLink(info) {
        let original = try DiskStore.fm.destinationOfSymbolicLink(atPath: path.path)
        let target = URL(fileURLWithPath: original, relativeTo: path.deletingLastPathComponent())
          .standardizedFileURL
        if sourceReference(target) || target.pathComponents.contains(source.udid) {
          throw SimulatorError("Clone still links to the source simulator: \(path.path)")
        }
      } else if DiskStore.isRegular(info) {
        let canonicalPath = path.resolvingSymlinksInPath().path
        let canonicalRoot = cloneRoot.resolvingSymlinksInPath().path
        let relative = canonicalPath.dropFirst(canonicalRoot.count)
        let counterpart = URL(fileURLWithPath: sourceRoot.resolvingSymlinksInPath().path + relative)
        if let sourceInfo = try? DiskStore.info(counterpart), DiskStore.isRegular(sourceInfo),
          sourceInfo.st_dev == info.st_dev && sourceInfo.st_ino == info.st_ino
        {
          throw SimulatorError("Clone contains a hard link to a source file: \(path.path)")
        }
      }
      return true
    }
  }
  func audit(_ output: String) throws -> Bool {
    var pid = 0
    var hasRecords = false
    for line in output.split(separator: "\n") {
      if line.first == "p" { pid = Int(line.dropFirst()) ?? 0 }
      if line.first == "n", pid > 0 {
        hasRecords = true
        let path = URL(fileURLWithPath: String(line.dropFirst()))
        if sourceReference(path) {
          throw SimulatorError("Clone process \(pid) still has a source path open: \(path.path)")
        }
      }
    }
    return hasRecords
  }
}

extension SimSlimBackend {
  func clone(udid: String, name: String) async throws -> SimulatorMutationResult {
    let name = try Self.normalizedName(name)
    let source = try await find(udid)
    let sourceData = try DiskStore.dataDirectory(source)
    guard ["Booted", "Shutdown"].contains(source.state) else {
      throw SimulatorError("Wait for the source simulator to finish changing state.")
    }
    var created: RawDevice?
    var failure: Error?
    var ready = false
    do {
      stage("Reading source service profile…", source)
      try await bootAndWait(source)
      let desired = try await disabled(source).intersection(ServiceCatalog.slimmable).subtracting(
        ServiceCatalog.compatibility)
      try await stop(source)
      stage("Cloning simulator…", source)
      let output = try await simctl(source, ["clone", udid, name], timeout: 600)
      guard UUID(uuidString: output.text) != nil else {
        throw SimulatorError("simctl returned an invalid clone UUID.")
      }
      // Keep the exact returned UUID for cleanup even if the next lookup fails.
      created = RawDevice(
        udid: output.text, name: name, state: "Shutdown", isAvailable: true, dataPath: nil,
        set: source.set, osVersion: source.osVersion)
      let clone = try await find(output.text, set: source.set)
      created = clone
      let paths = ClonePaths(
        source: source, clone: clone, sourceData: sourceData,
        cloneData: try DiskStore.dataDirectory(clone))
      stage("Preparing independent clone files…", source)
      try await Task.detached { try paths.sanitize() }.value
      try await ensure(clone, desired: desired)
      stage("Checking clone independence…", source)
      try await auditClone(paths)
      try await stop(clone)
      try await Task.detached { try paths.verify() }.value
      ready = true
    } catch { failure = error }
    // Recovery runs independently of cancellation so neither an unsafe clone
    // nor the temporarily changed source state is silently left behind.
    if !ready, let clone = created {
      do {
        try await Task.detached {
          try? await stop(clone)
          try await simctl(clone, ["delete", clone.udid])
        }.value
      } catch {
        failure = SimulatorError(
          "\(failure?.localizedDescription ?? "Clone failed.")\nCould not delete incomplete clone \(clone.udid): \(error.localizedDescription)"
        )
      }
    }
    do {
      try await Task.detached {
        if source.isBooted { try await bootAndWait(source) } else { try await stop(source) }
      }.value
    } catch {
      throw SimulatorError(
        "\(failure?.localizedDescription ?? "Clone prepared: \(created?.udid ?? "unknown").")\nCould not restore source boot state: \(error.localizedDescription)"
      )
    }
    if let failure { throw failure }
    guard ready, let clone = created else { throw SimulatorError("Clone was not prepared.") }
    return .init(action: "clone", udid: clone.udid, name: name, sourceUdid: udid)
  }
  func auditClone(_ paths: ClonePaths) async throws {
    for attempt in 0..<3 {
      let ps = try await runner.run("/bin/ps", ["eww", "-axo", "pid=,command="], log: false)
        .checked()
      let pids = ps.text.split(separator: "\n").compactMap { line -> Int? in
        guard line.contains("SIMULATOR_UDID=" + paths.clone.udid),
          let first = line.split(whereSeparator: \.isWhitespace).first
        else { return nil }
        return Int(first)
      }.filter { $0 > 0 }
      if !pids.isEmpty {
        let output = try await runner.run(
          "/usr/sbin/lsof",
          ["-n", "-P", "-Fpn", "-p", pids.map(String.init).joined(separator: ",")],
          udid: paths.clone.udid)
        if try paths.audit(output.text) { return }
      }
      if attempt < 2 { try await Task.sleep(for: .milliseconds(100)) }
    }
    throw SimulatorError("Could not obtain a meaningful snapshot of the clone's open files.")
  }
}
