import AppKit
import SwiftUI

@main
enum SwiftSimSlimEntryPoint {
  @MainActor static func main() {
    #if DEBUG
      if ProcessInfo.processInfo.environment["SWIFTSIMSLIM_UNIT_TESTS"] == "1" {
        SwiftSimSlimTestHost.main()
        return
      }
    #endif
    SwiftSimSlimApp.main()
  }
}

#if DEBUG
  private struct SwiftSimSlimTestHost: App {
    // XCTest needs the process, not a misleading empty simulator window.
    // Snapshot tests create and close their own explicit windows.
    var body: some Scene { Settings { EmptyView() } }
  }
#endif

struct SwiftSimSlimApp: App {
  @State private var model: AppModel = {
    #if DEBUG
      if let root = ProcessInfo.processInfo.environment["SWIFTSIMSLIM_DISK_UI_TEST"] {
        do { return try AppModel.diskLayoutUITest(root: root) } catch {
          let model = AppModel(deviceSets: [])
          model.presentedError = .init(message: error.localizedDescription)
          return model
        }
      }
      if let root = ProcessInfo.processInfo.environment["SWIFTSIMSLIM_SAFETY_UI_ROOT"] {
        do { return try AppModel.serviceSafetyUITest(root: root) } catch {
          let model = AppModel(deviceSets: [])
          model.presentedError = .init(
            message: "UI test setup failed: \(error.localizedDescription)")
          return model
        }
      }
      if ProcessInfo.processInfo.environment["SWIFTSIMSLIM_UNIT_TESTS"] == "1"
        || ProcessInfo.processInfo.environment["SWIFTSIMSLIM_EMPTY_UI_TEST"] == "1"
      {
        return AppModel(deviceSets: [])
      }
      if let set = ProcessInfo.processInfo.environment["SWIFTSIMSLIM_DEVICE_SET"],
        set.hasPrefix("/")
      {
        return AppModel(deviceSets: [set])
      }
    #endif
    return AppModel()
  }()

  var body: some Scene {
    mainWindow
  }

  private var testModeDescription: String? {
    #if DEBUG
      let environment = ProcessInfo.processInfo.environment
      if environment["SWIFTSIMSLIM_DISK_UI_TEST"] != nil {
        return "UI TEST — synthetic disk layout. Your simulators are not shown or changed."
      }
      if environment["SWIFTSIMSLIM_SAFETY_UI_ROOT"] != nil {
        return "UI TEST — synthetic device. Your simulators are not shown or changed."
      }
      if environment["SWIFTSIMSLIM_EMPTY_UI_TEST"] == "1" {
        return "UI TEST — intentionally empty device list. Your simulators are not shown."
      }
      if environment["SWIFTSIMSLIM_DEVICE_SET"] != nil {
        return "UI TEST — isolated device set. Your normal simulator list is not shown."
      }
    #endif
    return nil
  }

  private var mainWindow: some Scene {
    Window("SwiftSimSlim", id: "swiftsimslim-main") {
      ContentView()
        .safeAreaInset(edge: .bottom, spacing: 0) {
          if let testModeDescription {
            Text(testModeDescription)
              .font(.callout.bold())
              .frame(maxWidth: .infinity)
              .padding(8)
              .background(Color.yellow.opacity(0.25))
          }
        }
        .environment(model)
        .background(ToolbarDisplayModeConfigurator().frame(width: 0, height: 0))
        .frame(minWidth: 1080, minHeight: 700)
        .task { await model.load() }
    }
    .defaultSize(width: 1260, height: 820)
    .windowStyle(.titleBar)
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      CommandMenu("Simulator") {
        Button("Full Slim & Clean…") { model.requestsFullSlimAndClean = true }
          .disabled(!model.canOperateOnSelection)
      }
      CommandGroup(after: .toolbar) {
        Button("Refresh Simulators") {
          Task { await model.refresh() }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.isRefreshing)
      }
    }
  }
}

private struct ToolbarDisplayModeConfigurator: NSViewRepresentable {
  func makeNSView(context: Context) -> ToolbarDisplayModeView { ToolbarDisplayModeView() }
  func updateNSView(_ view: ToolbarDisplayModeView, context: Context) { view.applyDisplayMode() }
}

private final class ToolbarDisplayModeView: NSView {
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyDisplayMode()
    DispatchQueue.main.async { [weak self] in self?.applyDisplayMode() }
  }
  func applyDisplayMode() {
    // SwiftUI owns the item array; never remove or insert its toolbar spacers.
    guard let toolbar = window?.toolbar, toolbar.displayMode != .iconAndLabel else { return }
    toolbar.displayMode = .iconAndLabel
  }
}
