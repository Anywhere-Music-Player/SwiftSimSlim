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
      VStack(spacing: 0) {
        if let testModeDescription {
          Text(testModeDescription)
            .font(.callout.bold())
            .frame(maxWidth: .infinity)
            .padding(8)
            .background(Color.yellow.opacity(0.25))
        }
        ContentView()
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
  func makeNSView(context: Context) -> ToolbarDisplayModeView {
    ToolbarDisplayModeView()
  }

  func updateNSView(_ view: ToolbarDisplayModeView, context: Context) {
    view.applyDisplayMode()
  }
}

private final class ToolbarDisplayModeView: NSView {
  private weak var observedToolbar: NSToolbar?
  private var isArrangingToolbar = false
  private var arrangementIsScheduled = false

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    applyDisplayMode()
    DispatchQueue.main.async { [weak self] in
      self?.applyDisplayMode()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      self?.applyDisplayMode()
    }
  }

  func applyDisplayMode() {
    guard let toolbar = window?.toolbar else { return }
    observeToolbarChanges(toolbar)
    toolbar.displayMode = .iconAndLabel
    scheduleArrangement(in: toolbar)
  }

  private func observeToolbarChanges(_ toolbar: NSToolbar) {
    guard observedToolbar !== toolbar else { return }

    NotificationCenter.default.removeObserver(self)
    observedToolbar = toolbar

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(toolbarItemsWillChange(_:)),
      name: NSToolbar.willAddItemNotification,
      object: toolbar
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(toolbarItemsDidChange(_:)),
      name: NSToolbar.didRemoveItemNotification,
      object: toolbar
    )
  }

  @objc private func toolbarItemsWillChange(_ notification: Notification) {
    guard !isArrangingToolbar, let toolbar = notification.object as? NSToolbar else { return }
    scheduleArrangement(in: toolbar)
  }

  @objc private func toolbarItemsDidChange(_ notification: Notification) {
    guard !isArrangingToolbar, let toolbar = notification.object as? NSToolbar else { return }
    scheduleArrangement(in: toolbar)
  }

  private func scheduleArrangement(in toolbar: NSToolbar) {
    guard !arrangementIsScheduled else { return }
    arrangementIsScheduled = true

    DispatchQueue.main.async { [weak self, weak toolbar] in
      guard let self else { return }
      self.arrangementIsScheduled = false
      guard let toolbar, toolbar === self.observedToolbar else { return }
      self.arrangeFlexibleSpaces(in: toolbar)
    }
  }

  private func arrangeFlexibleSpaces(in toolbar: NSToolbar) {
    guard !isArrangingToolbar else { return }
    guard toolbar.items.contains(where: { $0.label == "Rename" }) else { return }

    let boundaryLabels = [
      toolbar.items.contains(where: { $0.label == "Unslim" }) ? "Unslim" : "Clean Disk",
      "Delete",
      "Rename",
      "Selection",
    ]

    let spaceIndices = toolbar.items.indices.filter {
      let identifier = toolbar.items[$0].itemIdentifier
      return identifier == .flexibleSpace || identifier == .space
    }

    let spacesAreAlreadyCorrect =
      spaceIndices.count == boundaryLabels.count
      && boundaryLabels.allSatisfy { label in
        guard let index = toolbar.items.firstIndex(where: { $0.label == label }) else {
          return false
        }
        let spaceIndex = index + 1
        guard toolbar.items.indices.contains(spaceIndex) else { return false }
        return toolbar.items[spaceIndex].itemIdentifier == .flexibleSpace
      }
    guard !spacesAreAlreadyCorrect else { return }

    isArrangingToolbar = true
    defer { isArrangingToolbar = false }

    for index in spaceIndices.reversed() {
      toolbar.removeItem(at: index)
    }

    for label in boundaryLabels {
      guard let index = toolbar.items.firstIndex(where: { $0.label == label }) else { continue }
      toolbar.insertItem(withItemIdentifier: .flexibleSpace, at: index + 1)
    }
  }
}
