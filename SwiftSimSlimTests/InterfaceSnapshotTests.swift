#if DEBUG
  import AppKit
  import SwiftUI
  import Testing

  @testable import SwiftSimSlim

  @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTSIMSLIM_SNAPSHOT_DIR"] != nil))
  @MainActor
  func renderInterfaceSnapshot() async throws {
    let root = URL(
      fileURLWithPath: try #require(
        ProcessInfo.processInfo.environment["SWIFTSIMSLIM_SNAPSHOT_DIR"]))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    _ = NSApplication.shared
    for size in [CGSize(width: 1500, height: 900), CGSize(width: 1080, height: 700)] {
      let model = try await AppModel.parallelPreview()
      let content = ContentView().environment(model).frame(width: size.width, height: size.height)
      let host = NSHostingView(rootView: content)
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
        styleMask: [.titled],
        backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      window.contentView = host
      window.orderFront(nil)
      defer {
        window.orderOut(nil)
        window.close()
      }
      try await Task.sleep(for: .seconds(1))
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      let png = try #require(bitmap.representation(using: .png, properties: [:]))
      #expect(png.count > 10_000)
      try png.write(to: root.appendingPathComponent("simulator-management-\(Int(size.width)).png"))
    }
  }

#endif

#if DEBUG
  @Test(.enabled(if: ProcessInfo.processInfo.environment["SWIFTSIMSLIM_SNAPSHOT_DIR"] != nil))
  @MainActor
  func renderServiceSafetySnapshot() async throws {
    let root = URL(
      fileURLWithPath: try #require(
        ProcessInfo.processInfo.environment["SWIFTSIMSLIM_SNAPSHOT_DIR"]))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let fake = FakeSimulator()
    await fake.writeOverrides(ServiceCatalog.compatibility)
    let model = AppModel(
      deviceSets: ["/synthetic-snapshot-set"],
      runner: CommandRunner(executor: { try await fake.execute($0, $1) }),
      defaults: UserDefaults(suiteName: "SwiftSimSlim-Snapshot-\(UUID())")!,
      automaticallyMeasureDisk: false)
    await model.load()
    model.keptServiceLabels = ServiceCatalog.slimmable.subtracting(
      ServiceCatalog.slimmable.sorted().prefix(3))
    let content = ServiceSafetyView(devices: model.devices).environment(model)
      .background(Color(nsColor: .windowBackgroundColor))
    let host = NSHostingView(rootView: content)
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 690, height: 640), styleMask: [.titled],
      backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    window.orderFront(nil)
    defer {
      window.orderOut(nil)
      window.close()
    }
    for _ in 0..<100 where model.servicePlans.isEmpty {
      try await Task.sleep(for: .milliseconds(20))
    }
    try #require(model.servicePlans.count == 1)
    try await Task.sleep(for: .seconds(1))
    host.layoutSubtreeIfNeeded()
    let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: bitmap)
    let png = try #require(bitmap.representation(using: .png, properties: [:]))
    try png.write(to: root.appendingPathComponent("service-safety.png"))
  }
#endif
