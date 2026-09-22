import AppKit
import XCTest

@MainActor
final class ServiceSafetyUITests: XCTestCase {
  func testExportCancelSaveAndRestore() throws {
    continueAfterFailure = false
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("SwiftSimSlim-ui-safety-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = XCUIApplication()
    app.launchEnvironment["SWIFTSIMSLIM_SAFETY_UI_ROOT"] = root.path
    app.launchArguments = ["-ApplePersistenceIgnoreState", "YES"]
    defer { app.terminate() }
    app.launch()
    let running = try XCTUnwrap(
      NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.buildsucceeded.SwiftSimSlim"
      ).first)
    NSWorkspace.shared.openApplication(
      at: try XCTUnwrap(running.bundleURL), configuration: .init())
    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
    XCTAssertTrue(app.staticTexts["Service Safety UI Fixture"].waitForExistence(timeout: 10))

    func menuAction(_ name: String) {
      let menu = app.descendants(matching: .any).matching(identifier: "Service State").firstMatch
      XCTAssertTrue(menu.waitForExistence(timeout: 5), app.debugDescription)
      menu.click()
      let item = app.menuItems[name]
      XCTAssertTrue(item.waitForExistence(timeout: 5), app.debugDescription)
      XCTAssertTrue(item.isEnabled)
      item.click()
    }

    menuAction("Export Saved State…")
    let savePanel = app.sheets.firstMatch
    XCTAssertTrue(savePanel.waitForExistence(timeout: 5), app.debugDescription)
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = "Saved-state export panel"
    attachment.lifetime = .keepAlways
    add(attachment)
    savePanel.buttons["Cancel"].click()
    XCTAssertTrue(savePanel.waitForNonExistence(timeout: 5))

    menuAction("Export Saved State…")
    XCTAssertTrue(savePanel.waitForExistence(timeout: 5))
    let filename = savePanel.textFields.firstMatch
    XCTAssertTrue(filename.exists, app.debugDescription)
    filename.click()
    filename.typeKey("a", modifierFlags: .command)
    filename.typeText("export.json")
    app.typeKey("g", modifierFlags: [.command, .shift])
    app.typeText(root.path)
    app.typeKey(.return, modifierFlags: [])
    savePanel.buttons["Save"].click()
    XCTAssertTrue(savePanel.waitForNonExistence(timeout: 10), app.debugDescription)
    let exported = root.appendingPathComponent("export.json")
    let data = try Data(contentsOf: exported)
    let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(json["udid"] as? String, "00000000-0000-0000-0000-000000000099")
    XCTAssertEqual(json["disabled"] as? [String], [])
    XCTAssertEqual(json["bootState"] as? String, "Booted")

    menuAction("Restore Saved State")
    let changed = root.appendingPathComponent("applied-labels.json")
    let restored = NSPredicate { _, _ in FileManager.default.fileExists(atPath: changed.path) }
    expectation(for: restored, evaluatedWith: nil)
    waitForExpectations(timeout: 10)
    let labels = try JSONDecoder().decode([String].self, from: Data(contentsOf: changed))
    XCTAssertEqual(labels, [])
    XCTAssertTrue(
      app.staticTexts["Service Safety UI Fixture: Restoring saved state… Done"]
        .waitForExistence(timeout: 10), app.debugDescription)
    print("UI verified: cancel export, save and decode JSON, restore saved profile through UI.")
  }
}
