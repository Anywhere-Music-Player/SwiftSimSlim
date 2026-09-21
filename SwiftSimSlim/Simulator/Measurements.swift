import Foundation

extension SwiftSimSlimBackend {
  func measure(udid: String) async throws -> SimulatorMeasurement {
    let device = try await find(udid)
    let result = await measurements([device])
    guard let value = result.values[udid] else {
      throw SimulatorError(result.errors[udid] ?? "Could not measure simulator memory.")
    }
    return value
  }
  func measurements(_ devices: [RawDevice]) async -> (
    values: [String: SimulatorMeasurement], errors: [String: String]
  ) {
    guard !devices.isEmpty else { return ([:], [:]) }
    var values: [String: SimulatorMeasurement] = [:]
    var errors: [String: String] = [:]
    do {
      let ps = try await runner.run("/bin/ps", ["-axo", "pid,ppid,%cpu,comm"], log: false).checked()
      let top = try await runner.run("/usr/bin/top", ["-l", "1", "-stats", "pid,mem"], log: false)
        .checked()
      let children = MemoryParser.children(ps.text)
      let footprint = MemoryParser.footprints(top.text)
      for device in devices {
        do {
          let output = try await runner.run(
            "/usr/bin/pgrep", ["-f", device.udid + "/data/var/run/launchd_bootstrap"], log: false
          ).checked()
          guard let field = output.text.split(whereSeparator: \.isWhitespace).first,
            let root = Int(field)
          else { throw SimulatorError("Simulator is not booted.") }
          let pids = MemoryParser.tree(root: root, children: children)
          values[device.udid] = .init(
            processes: pids.count, bytes: pids.reduce(0) { $0 + (footprint[$1] ?? 0) })
        } catch { errors[device.udid] = error.localizedDescription }
      }
    } catch { for device in devices { errors[device.udid] = error.localizedDescription } }
    return (values, errors)
  }
  func diskSize(udid: String) async throws -> SimulatorDiskMeasurement {
    let device = try await find(udid)
    let root = try DiskStore.dataDirectory(device)
    let bytes = try await Task.detached(priority: .utility) { try DiskStore.allocatedSize(root) }
      .value
    return .init(bytes: bytes)
  }
}

enum MemoryParser {
  static func children(_ text: String) -> [Int: [Int]] {
    var result: [Int: [Int]] = [:]
    for line in text.split(separator: "\n") {
      let parts = line.split(whereSeparator: \.isWhitespace)
      if parts.count >= 4, let pid = Int(parts[0]), let parent = Int(parts[1]) {
        result[parent, default: []].append(pid)
      }
    }
    return result
  }
  static func tree(root: Int, children: [Int: [Int]]) -> Set<Int> {
    var seen = Set<Int>()
    var stack = [root]
    while let next = stack.popLast() {
      if seen.insert(next).inserted { stack.append(contentsOf: children[next] ?? []) }
    }
    return seen
  }
  static func bytes(_ text: String) -> Int64 {
    var value = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
      of: "+", with: "")
    let multiplier: Double
    switch value.last {
    case "K":
      multiplier = 1024
      value.removeLast()
    case "M":
      multiplier = 1024 * 1024
      value.removeLast()
    case "G":
      multiplier = 1024 * 1024 * 1024
      value.removeLast()
    case "B":
      multiplier = 1
      value.removeLast()
    default: multiplier = 1
    }
    guard let number = Double(value), number.isFinite, number >= 0,
      number * multiplier < Double(Int64.max)
    else { return 0 }
    return Int64(number * multiplier)
  }
  static func footprints(_ text: String) -> [Int: Int64] {
    var result: [Int: Int64] = [:]
    for line in text.split(separator: "\n") {
      let fields = line.split(whereSeparator: \.isWhitespace)
      if fields.count >= 2, let pid = Int(fields[0]) { result[pid] = bytes(String(fields[1])) }
    }
    return result
  }
}
