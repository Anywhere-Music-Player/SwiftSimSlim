import AppKit
import XCTest

@MainActor
final class DiskLayoutUITests: XCTestCase {
  func testDiskSelectionKeepsHeaderBelowToolbar() async throws {
    continueAfterFailure = false
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SwiftSimSlim-ui-disk-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = XCUIApplication()
    app.launchEnvironment["SWIFTSIMSLIM_DISK_UI_TEST"] = root.path
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    defer { app.terminate() }
    app.launch()
    let running = try XCTUnwrap(
      NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.buildsucceeded.SwiftSimSlim"
      ).first)
    _ = try await NSWorkspace.shared.openApplication(
      at: try XCTUnwrap(running.bundleURL), configuration: .init())
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    let first = app.buttons["select-00000000-0000-0000-0000-000000000101"]
    XCTAssertTrue(first.waitForExistence(timeout: 10))
    XCTAssertEqual(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'select-'")).count, 7)
    let disk = app.buttons["Disk Size"]
    if disk.exists { disk.click() } else { app.radioButtons["Disk Size"].click() }
    let header = app.staticTexts["Installed Simulators"]
    for size in [
      CGSize(width: 1570, height: 960), CGSize(width: 1080, height: 700),
      CGSize(width: 1500, height: 900),
    ] {
      let frame = window.frame
      let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(
        CGVector(dx: -1, dy: -1))
      corner.click(
        forDuration: 0.2,
        thenDragTo: corner.withOffset(
          CGVector(dx: size.width - frame.width, dy: size.height - frame.height)))
      try await Task.sleep(for: .milliseconds(350))
      let initialY = header.frame.minY
      if size.width > 1400 { assertToolbarGroups(in: app, window: window) }
      for index in 101...103 {
        app.buttons[String(format: "select-00000000-0000-0000-0000-%012d", index)].click()
        XCTAssertEqual(header.frame.minY, initialY, accuracy: 2)
      }
      let reanalyze = app.buttons["Re-analyze Selected"]
      let ready = NSPredicate { _, _ in reanalyze.isEnabled }
      await fulfillment(of: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 20)
      let initialRowY = first.frame.minY
      reanalyze.click()
      try await Task.sleep(for: .milliseconds(350))
      XCTAssertEqual(first.frame.minY, initialRowY, accuracy: 2)
      XCTAssertFalse(app.staticTexts["Changing…"].exists)
      let attachment = XCTAttachment(screenshot: window.screenshot())
      attachment.name = "Seven devices during analysis at \(Int(size.width))"
      attachment.lifetime = .keepAlways
      add(attachment)
      await fulfillment(of: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 20)
      XCTAssertEqual(first.frame.minY, initialRowY, accuracy: 2)
      XCTAssertEqual(header.frame.minY, initialY, accuracy: 2)
      if size.width > 1400 { assertToolbarGroups(in: app, window: window) }
      XCTAssertGreaterThanOrEqual(header.frame.minY, app.toolbars.firstMatch.frame.maxY)
      let cache = app.descendants(matching: .any).matching(identifier: "Remove System & App Caches")
        .firstMatch
      XCTAssertTrue(cache.waitForExistence(timeout: 5))
      cache.click()
      cache.click()
      let settled = XCTAttachment(screenshot: window.screenshot())
      settled.name = "Seven devices after analysis at \(Int(size.width))"
      settled.lifetime = .keepAlways
      add(settled)
      app.descendants(matching: .any).matching(identifier: "Selection").firstMatch.click()
      app.menuItems["Clear Selection"].click()
    }
    first.click()
    let ready = NSPredicate { _, _ in app.buttons["Re-analyze Selected"].isEnabled }
    await fulfillment(of: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 20)
    app.toolbars.buttons["Apps & Data"].click()
    let appsSheet = app.sheets.firstMatch
    let sampleApp = appsSheet.staticTexts["Music Demo"]
    XCTAssertTrue(sampleApp.waitForExistence(timeout: 10))
    XCTAssertTrue(appsSheet.staticTexts["Notes Demo"].exists)
    XCTAssertTrue(appsSheet.staticTexts["Browser Demo"].exists)
    sampleApp.click()
    XCTAssertTrue(appsSheet.buttons["Delete Documents…"].isEnabled)
    let appsScreenshot = XCTAttachment(screenshot: appsSheet.screenshot())
    appsScreenshot.name = "Apps and private data inventory"
    appsScreenshot.lifetime = .keepAlways
    add(appsScreenshot)
    appsSheet.buttons["Delete Documents…"].click()
    let deleteSheet = app.sheets.buttons["Delete Documents"].firstMatch
    XCTAssertTrue(deleteSheet.waitForExistence(timeout: 5))
    XCTAssertTrue(deleteSheet.isEnabled)
    app.sheets.buttons["Cancel"].firstMatch.click()
    XCTAssertTrue(deleteSheet.waitForNonExistence(timeout: 5))
    appsSheet.buttons["Close"].click()
    XCTAssertTrue(appsSheet.waitForNonExistence(timeout: 5))
    app.menuBars.menuBarItems["Simulator"].click()
    app.menuItems["Full Slim & Clean…"].click()
    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 5))
    XCTAssertTrue(sheet.buttons["Full Slim & Clean"].isEnabled)
    let confirmation = XCTAttachment(screenshot: window.screenshot())
    confirmation.name = "Combined cleanup confirmation"
    confirmation.lifetime = .keepAlways
    add(confirmation)
    sheet.buttons["Cancel"].click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    let memory = app.buttons["Memory Use"]
    if memory.exists { memory.click() } else { app.radioButtons["Memory Use"].click() }
    assertToolbarGroups(in: app, window: window)
    let memoryToolbar = XCTAttachment(screenshot: window.screenshot())
    memoryToolbar.name = "Distributed toolbar in Memory Use"
    memoryToolbar.lifetime = .keepAlways
    add(memoryToolbar)
  }

  private func assertToolbarGroups(in app: XCUIApplication, window: XCUIElement) {
    let toolbar = app.toolbars.firstMatch
    XCTAssertGreaterThan(
      toolbar.buttons["Boot"].frame.minX, toolbar.buttons["Delete"].frame.maxX + 30)
    XCTAssertGreaterThan(
      toolbar.buttons["Refresh"].frame.minX, toolbar.buttons["Rename"].frame.maxX + 30)
    XCTAssertGreaterThan(
      toolbar.buttons["Search"].frame.maxX, window.frame.maxX - 60)
  }
}
