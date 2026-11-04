import AppKit
import XCTest

@MainActor
final class WallpaperCleanupUITests: XCTestCase {
  func testWallpaperCleanupRequiresConfirmationAndPreservesApps() async throws {
    continueAfterFailure = false
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SwiftSimSlim-ui-disk-\(UUID())")
    let data = root.appendingPathComponent("00000000-0000-0000-0000-000000000101/data")
    let version = data.appendingPathComponent(
      "Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/com.apple.MercuryPoster/configurations/00000000-0000-0000-0000-000000000001/versions/0"
    )
    let texture = version.appendingPathComponent(
      "RuntimeSnapshot-" + String(repeating: "a", count: 64) + "-home.atx")
    let original = version.appendingPathComponent("contents/original.HEIC")
    try FileManager.default.createDirectory(
      at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(repeating: 7, count: 3_170_056).write(to: texture)
    try Data("original wallpaper".utf8).write(to: original)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = XCUIApplication()
    app.launchEnvironment["SWIFTSIMSLIM_DISK_UI_TEST"] = root.path
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    defer { app.terminate() }
    app.launch()
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    let first = app.buttons["select-00000000-0000-0000-0000-000000000101"]
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    let disk = app.buttons["Disk Size"]
    if disk.exists { disk.click() } else { app.radioButtons["Disk Size"].click() }
    first.click()
    let clean = app.buttons["Clean Wallpaper Cache…"]
    let ready = NSPredicate { _, _ in clean.exists && clean.isEnabled }
    await fulfillment(of: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 30)
    for _ in 0..<12 {
      if clean.isHittable && clean.frame.maxY < window.frame.maxY - 80 { break }
      app.scrollViews["profile-sidebar-scroll"].scroll(byDeltaX: 0, deltaY: -180)
      try await Task.sleep(for: .milliseconds(150))
    }
    XCTAssertTrue(clean.isHittable)
    let card = XCTAttachment(screenshot: window.screenshot())
    card.name = "Wallpaper cleanup control"
    card.lifetime = .keepAlways
    add(card)
    clean.click()
    let confirm = app.sheets.buttons["Clean Wallpaper Cache"].firstMatch
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    XCTAssertTrue(confirm.isEnabled)
    XCTAssertTrue(app.sheets.staticTexts["18 Pro 1"].exists)
    XCTAssertTrue(
      app.sheets.staticTexts.matching(
        NSPredicate(format: "label CONTAINS '3.2 MB' OR value CONTAINS '3.2 MB'")
      ).firstMatch.exists, app.sheets.debugDescription)
    XCTAssertTrue(FileManager.default.fileExists(atPath: texture.path))
    let sheet = XCTAttachment(screenshot: app.sheets.firstMatch.screenshot())
    sheet.name = "Wallpaper cleanup confirmation"
    sheet.lifetime = .keepAlways
    add(sheet)
    app.sheets.buttons["Cancel"].firstMatch.click()
    XCTAssertTrue(confirm.waitForNonExistence(timeout: 5))
    XCTAssertTrue(FileManager.default.fileExists(atPath: texture.path))

    // Snapshot every non-wallpaper file, including the fixture's apps, documents and caches.
    func readRetainedFiles() throws -> [URL: Data] {
      var retained: [URL: Data] = [:]
      let enumerator = try XCTUnwrap(FileManager.default.enumerator(atPath: data.path))
      for case let path as String in enumerator {
        let url = data.appendingPathComponent(path)
        if !url.path.hasPrefix(version.path),
          (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
        {
          retained[url] = try Data(contentsOf: url)
        }
      }
      return retained
    }
    let retained = try readRetainedFiles()
    XCTAssertFalse(retained.isEmpty)
    clean.click()
    XCTAssertTrue(confirm.waitForExistence(timeout: 5))
    confirm.click()
    let removed = NSPredicate { _, _ in !FileManager.default.fileExists(atPath: texture.path) }
    await fulfillment(of: [XCTNSPredicateExpectation(predicate: removed, object: nil)], timeout: 30)
    XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "original wallpaper")
    for (url, bytes) in retained { XCTAssertEqual(try Data(contentsOf: url), bytes) }
  }
}
