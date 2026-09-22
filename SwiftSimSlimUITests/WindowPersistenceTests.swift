import AppKit
import XCTest

@MainActor
final class WindowPersistenceTests: XCTestCase {
  func testWindowSizeSurvivesRelaunch() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    // Match a normal launch: XCTest otherwise suppresses saved window state.
    app.launchArguments = ["-ApplePersistenceIgnoreState", "NO"]
    app.launchEnvironment["SWIFTSIMSLIM_EMPTY_UI_TEST"] = "1"
    defer { app.terminate() }
    app.terminate()
    app.launch()
    try reopenApplication()
    let window = app.windows.firstMatch
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    XCTAssertFalse(app.menuItems["New Window"].exists)
    XCTAssertEqual(app.windows.count, 1)
    let original = window.frame
    let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
      .withOffset(CGVector(dx: -1, dy: -1))
    corner.click(
      forDuration: 0.2,
      thenDragTo: corner.withOffset(
        CGVector(
          dx: (abs(original.width - 1450) > 40 ? 1450 : 1570) - original.width,
          dy: 880 - original.height)))
    let resized = window.frame
    XCTAssertGreaterThan(
      abs(resized.width - original.width), 40,
      "Resize must actually occur: \(original) -> \(resized)")
    XCTAssertGreaterThan(abs(resized.width - 1260), 40, "Must differ from the default size")
    app.menuBars.menuBarItems["SwiftSimSlim"].click()
    app.menuItems["Quit SwiftSimSlim"].click()
    XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
    app.launch()
    try reopenApplication()
    XCTAssertTrue(window.waitForExistence(timeout: 10))
    XCTAssertEqual(window.frame.width, resized.width, accuracy: 2)
    XCTAssertEqual(window.frame.height, resized.height, accuracy: 2)
    try reopenApplication()
    XCTAssertEqual(app.windows.count, 1)
    print("Window restored: \(resized.size) -> \(window.frame.size)")
  }

  private func reopenApplication() throws {
    // XCTest launches the process without the reopen event sent by Finder or the Dock.
    let application = try XCTUnwrap(
      NSRunningApplication.runningApplications(
        withBundleIdentifier: "com.buildsucceeded.SwiftSimSlim"
      ).first)
    let url = try XCTUnwrap(application.bundleURL)
    NSWorkspace.shared.openApplication(at: url, configuration: .init())
  }

}
