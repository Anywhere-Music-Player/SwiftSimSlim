import XCTest

@MainActor
final class SimulatorInterfaceTests: XCTestCase {
  func testIsolatedSimulatorInterface() throws {
    continueAfterFailure = false
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "SwiftSimSlim-UI-" + UUID().uuidString)
    let set = root.appendingPathComponent("Devices").path
    try FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
    let uuid = try simctl([
      "--set", set, "create", "UI Acceptance Only",
      "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro",
      "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
    ])
    XCTAssertNotNil(UUID(uuidString: uuid))
    let app = XCUIApplication()
    app.launchEnvironment["SWIFTSIMSLIM_DEVICE_SET"] = set
    defer {
      app.terminate()
      // Only the UUID just created in our unique set may be removed.
      _ = try? simctl(["--set", set, "shutdown", uuid])
      _ = try? simctl(["--set", set, "delete", uuid])
    }
    app.launch()
    let selection = app.buttons["select-" + uuid]
    XCTAssertTrue(selection.waitForExistence(timeout: 60))
    XCTAssertEqual(
      app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "select-")).count, 1)
    selection.click()
    let rename = app.toolbars.buttons["Rename"]
    XCTAssertTrue(rename.waitForExistence(timeout: 10))
    XCTAssertTrue(rename.isEnabled)
    attach(app, "Simulator list")
    rename.click()
    let sheet = app.sheets.firstMatch
    XCTAssertTrue(sheet.waitForExistence(timeout: 5))
    let name = sheet.textFields.firstMatch
    name.click()
    name.typeKey("a", modifierFlags: .command)
    name.typeText("UI Acceptance Renamed")
    attach(app, "Rename confirmation")
    sheet.buttons["Rename Simulator"].click()
    XCTAssertTrue(app.staticTexts["UI Acceptance Renamed"].waitForExistence(timeout: 30))
    app.buttons["Command Details"].click()
    XCTAssertTrue(app.buttons["Copy Log"].isEnabled)
    XCTAssertTrue(
      app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Exit 0")).firstMatch
        .waitForExistence(timeout: 10))
    attach(app, "Live command log")
    app.toolbars.buttons["Slim"].click()
    XCTAssertTrue(app.sheets.staticTexts["Clone Before Slimming?"].waitForExistence(timeout: 5))
    attach(app, "Slim confirmation")
    app.sheets.buttons["Cancel"].click()
    let disk = app.buttons["Disk Size"]
    if disk.exists { disk.click() } else { app.radioButtons["Disk Size"].click() }
    XCTAssertTrue(app.toolbars.buttons["Clean Disk"].waitForExistence(timeout: 10))
    attach(app, "Disk analysis")
  }

  private func attach(_ app: XCUIApplication, _ name: String) {
    let attachment = XCTAttachment(screenshot: app.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func simctl(_ args: [String]) throws -> String {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["simctl"] + args
    process.standardOutput = pipe.fileHandleForWriting
    process.standardError = pipe.fileHandleForWriting
    try process.run()
    try pipe.fileHandleForWriting.close()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0 else {
      throw NSError(
        domain: "simctl", code: Int(process.terminationStatus),
        userInfo: [NSLocalizedDescriptionKey: text])
    }
    return text
  }
}
