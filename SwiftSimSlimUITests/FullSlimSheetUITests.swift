import AppKit
import XCTest

@MainActor
final class FullSlimSheetUITests: XCTestCase {
  func testCheckboxDefaultsAndResizableConfirmation() async throws {
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
    let select = app.buttons["select-00000000-0000-0000-0000-000000000101"]
    XCTAssertTrue(select.waitForExistence(timeout: 10))
    select.click()
    app.menuBars.menuBarItems["Simulator"].click()
    app.menuItems["Full Slim & Clean…"].click()
    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 5))
    let checks = sheet.checkBoxes.matching(
      NSPredicate(format: "identifier BEGINSWITH %@", "full-slim-"))
    XCTAssertGreaterThan(checks.count, 5)
    for checkbox in checks.allElementsBoundByIndex {
      XCTAssertEqual((checkbox.value as? NSNumber)?.intValue, 1)
    }
    func capture(_ name: String) {
      let shot = XCTAttachment(screenshot: sheet.screenshot())
      shot.name = name
      shot.lifetime = .keepAlways
      add(shot)
    }
    capture("Full Slim defaults")
    let original = sheet.frame
    let corner = sheet.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
      .withOffset(CGVector(dx: -1, dy: -1))
    corner.click(forDuration: 0.2, thenDragTo: corner.withOffset(CGVector(dx: 150, dy: 100)))
    XCTAssertGreaterThan(sheet.frame.width - original.width, 70)
    XCTAssertGreaterThan(sheet.frame.height - original.height, 40)
    capture("Full Slim resized larger")
    for checkbox in checks.allElementsBoundByIndex { checkbox.click() }
    let confirm = sheet.buttons["Full Slim & Clean"]
    XCTAssertFalse(confirm.isEnabled)
    sheet.checkBoxes["full-slim-category-caches"].click()
    XCTAssertTrue(confirm.isEnabled)
    XCTAssertEqual((sheet.checkBoxes["full-slim-services"].value as? NSNumber)?.intValue, 0)
    capture("Full Slim cache only")
    let largeCorner = sheet.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
      .withOffset(CGVector(dx: -1, dy: -1))
    largeCorner.click(
      forDuration: 0.2, thenDragTo: largeCorner.withOffset(CGVector(dx: -290, dy: -280)))
    XCTAssertLessThan(sheet.frame.width, original.width)
    XCTAssertLessThan(sheet.frame.height, original.height)
    XCTAssertTrue(confirm.isHittable)
    XCTAssertTrue(sheet.buttons["Cancel"].isHittable)
    capture("Full Slim resized smaller")
    sheet.buttons["Cancel"].click()
    XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    app.menuBars.menuBarItems["Simulator"].click()
    app.menuItems["Full Slim & Clean…"].click()
    XCTAssertTrue(sheet.waitForExistence(timeout: 5))
    for checkbox in checks.allElementsBoundByIndex {
      XCTAssertEqual((checkbox.value as? NSNumber)?.intValue, 1)
    }
    sheet.buttons["Cancel"].click()
  }
}
