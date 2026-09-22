import AppKit
import SwiftUI

struct ContentView: View {
  @Environment(AppModel.self) private var model
  @State private var searchText = ""
  @State private var searchIsExpanded = false
  @State private var managementSheet: SimulatorManagementSheet?
  @State private var slimmingMode: SlimmingMode = .memory

  private var filteredDevices: [SimulatorDevice] {
    guard !searchText.isEmpty else { return model.devices }
    return model.devices.filter {
      $0.name.localizedCaseInsensitiveContains(searchText)
        || $0.udid.localizedCaseInsensitiveContains(searchText)
        || $0.osVersion.localizedCaseInsensitiveContains(searchText)
    }
  }

  private var filteredUDIDs: Set<String> {
    Set(filteredDevices.map(\.udid))
  }

  private var singleSelectedDevice: SimulatorDevice? {
    let selected = model.selectedDevices
    return selected.count == 1 ? selected[0] : nil
  }

  private var selectedCleanableDiskCategories: [DiskCleanupCategory] {
    model.diskCleanupCategories.filter {
      $0.canClean && model.selectedDiskCleanupCategoryIDs.contains($0.id)
    }
  }

  private var automaticDiskAnalysisID: String {
    guard slimmingMode == .disk else { return "memory" }
    return "disk:" + model.diskAnalysisRequestID
  }

  var body: some View {
    NavigationSplitView {
      ProfileSidebar(mode: $slimmingMode)
        .navigationSplitViewColumnWidth(min: 340, ideal: 390, max: 460)
    } detail: {
      VStack(spacing: 0) {
        header
        Divider()
        selectionBar
        Divider()
        simulatorTable
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
          .layoutPriority(1)
        Divider()
        ActivityPanel()
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .toolbar {
      if slimmingMode == .memory {
        ToolbarItem(placement: .automatic) {
          Button {
            managementSheet = .slimmingRecommendation(model.selectedDevices)
          } label: {
            ToolbarActionLabel("Slim", systemImage: "minus.circle")
          }
          .disabled(!model.canOperateOnSelection)
          .help("Apply the selected service profile")
        }

        ToolbarItem(placement: .automatic) {
          Button {
            managementSheet = .servicePreview(model.selectedDevices, unslim: true)
          } label: {
            ToolbarActionLabel("Unslim", systemImage: "plus.circle")
          }
          .disabled(!model.canOperateOnSelection)
          .help("Restore all SwiftSimSlim-managed services")
        }
        ToolbarItem(placement: .automatic) {
          Menu {
            Button("Preview Service Changes…") {
              managementSheet = .servicePreview(model.selectedDevices, unslim: false)
            }
            .disabled(!model.canOperateOnSelection)
            if let device = singleSelectedDevice {
              SavedStateActions(device: device)
            }
          } label: {
            ToolbarActionLabel("Service State", systemImage: "arrow.uturn.backward.circle")
          }
        }
      } else {
        ToolbarItem(placement: .automatic) {
          Button(role: .destructive) {
            managementSheet = .diskCleanup(model.selectedDevices, selectedCleanableDiskCategories)
          } label: {
            ToolbarActionLabel("Clean Disk", systemImage: "externaldrive.badge.xmark")
          }
          .disabled(!model.canCleanDiskSelection)
          .help("Permanently clean the selected disk categories")
        }
      }

      if #available(macOS 26.0, *) {
        ToolbarSpacer(.flexible)
      }

      ToolbarItemGroup(placement: .automatic) {
        Button {
          guard let device = singleSelectedDevice else { return }
          managementSheet = .clone(device)
        } label: {
          ToolbarActionLabel("Clone", systemImage: "plus.square.on.square")
        }
        .disabled(singleSelectedDevice == nil || !model.canOperateOnSelection)
        .help("Clone for backup or general-purpose use")

        Button(role: .destructive) {
          managementSheet = .erase(model.selectedDevices)
        } label: {
          ToolbarActionLabel("Erase", systemImage: "eraser")
        }
        .disabled(!model.canOperateOnSelection)
        .help("Erase Simulator")

        Button(role: .destructive) {
          managementSheet = .delete(model.selectedDevices)
        } label: {
          ToolbarActionLabel("Delete", systemImage: "trash")
        }
        .disabled(!model.canOperateOnSelection)
        .help("Delete Simulator")
      }

      if #available(macOS 26.0, *) {
        ToolbarSpacer(.flexible)
      }

      ToolbarItemGroup(placement: .automatic) {
        Button {
          guard let device = singleSelectedDevice else { return }
          Task { await model.bootSimulator(device) }
        } label: {
          ToolbarActionLabel("Boot", systemImage: "play.fill")
        }
        .disabled(
          singleSelectedDevice == nil || singleSelectedDevice?.isBooted == true
            || !model.canOperateOnSelection
        )
        .help("Boot Simulator")

        Button {
          guard let device = singleSelectedDevice else { return }
          Task { await model.shutdownSimulator(device) }
        } label: {
          ToolbarActionLabel("Kill", systemImage: "stop.fill")
        }
        .disabled(
          singleSelectedDevice == nil || singleSelectedDevice?.isBooted == false
            || !model.canOperateOnSelection
        )
        .help("Shut Down Simulator")

        Button {
          guard let device = singleSelectedDevice else { return }
          managementSheet = .rename(device)
        } label: {
          ToolbarActionLabel("Rename", systemImage: "pencil")
        }
        .disabled(singleSelectedDevice == nil || !model.canOperateOnSelection)
        .help("Rename Simulator")
      }

      if #available(macOS 26.0, *) {
        ToolbarSpacer(.flexible)
      }

      ToolbarItemGroup(placement: .automatic) {
        Button {
          Task { await model.refresh() }
        } label: {
          ToolbarActionLabel("Refresh", systemImage: "arrow.clockwise")
        }
        .disabled(model.isRefreshing)
        .help("Refresh simulator status")

        Menu {
          Button("Select Visible") { model.select(filteredUDIDs) }
            .disabled(filteredDevices.isEmpty)
          Button("Clear Selection") { model.clearSelection() }
            .disabled(model.selectionCount == 0)
        } label: {
          ToolbarActionLabel("Selection", systemImage: "checklist")
        }
      }

      if #available(macOS 26.0, *) {
        ToolbarSpacer(.flexible)
      }

      ToolbarItem(placement: .automatic) {
        CollapsibleToolbarSearch(
          text: $searchText,
          prompt: "Find a simulator",
          isExpanded: $searchIsExpanded
        )
      }
    }
    .sheet(item: $managementSheet) { sheet in
      managementSheetContent(for: sheet)
    }
    .fileExporter(
      isPresented: Binding(
        get: { model.serviceBackupExport != nil },
        set: { if !$0 { model.serviceBackupExport = nil } }),
      document: model.serviceBackupExport.map { ServiceBackupDocument(data: $0.data) },
      contentType: .json,
      defaultFilename:
        "SwiftSimSlim-\(model.serviceBackupExport?.udid ?? "simulator")-original-state"
    ) { result in
      if case .failure(let error) = result {
        model.presentedError = .init(message: error.localizedDescription)
      }
    }
    .alert(item: Binding(get: { model.presentedError }, set: { model.presentedError = $0 })) {
      error in
      Alert(
        title: Text("SwiftSimSlim couldn’t finish"),
        message: Text(error.message),
        dismissButton: .default(Text("OK"))
      )
    }
    .task(id: automaticDiskAnalysisID) {
      guard slimmingMode == .disk, model.selectionCount > 0 else { return }
      await model.analyzeDiskSelectionIfNeeded()
    }
  }

  private var header: some View {
    HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Installed Simulators")
          .font(.system(size: 27, weight: .bold, design: .rounded))
        Text(lastUpdatedText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer()

      MetricPill(value: "\(model.devices.count)", label: "Installed", color: .blue)
      MetricPill(value: "\(model.bootedCount)", label: "Booted", color: .orange)
      MetricPill(value: "\(model.selectionCount)", label: "Selected", color: .purple)
    }
    .padding(.horizontal, 20)
    .padding(.vertical, 15)
  }

  private var selectionBar: some View {
    VStack(spacing: 10) {
      HStack(spacing: 12) {
        Button {
          if !filteredDevices.isEmpty && filteredUDIDs.isSubset(of: model.selectedUDIDs) {
            model.select(model.selectedUDIDs.subtracting(filteredUDIDs))
          } else {
            model.select(model.selectedUDIDs.union(filteredUDIDs))
          }
        } label: {
          Image(systemName: selectionAllImage)
            .font(.title3)
            .foregroundStyle(filteredDevices.isEmpty ? Color.secondary : Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled(filteredDevices.isEmpty)
        .help("Select or deselect all visible simulators")

        if model.selectionCount == 0 {
          Text(
            slimmingMode == .memory
              ? "Select simulators to change their service profile"
              : "Select simulators to review reclaimable disk data"
          )
          .foregroundStyle(.secondary)
        } else {
          Text("\(model.selectionCount) selected")
            .fontWeight(.semibold)
          if slimmingMode == .memory {
            Text("· profile will disable \(model.disabledDaemonCount) services")
              .foregroundStyle(.secondary)
          } else if model.isAnalyzingDisk {
            Text("· analyzing disk usage…")
              .foregroundStyle(.secondary)
          } else if model.diskAnalysisCoversSelection {
            Text("· \(model.selectedDiskCleanupSizeText()) selected for cleanup")
              .foregroundStyle(.orange)
          } else {
            Text("· disk analysis pending")
              .foregroundStyle(.secondary)
          }
        }

        Spacer()
      }
      .controlSize(.regular)

      ForEach(model.batches) { progress in
        VStack(spacing: 5) {
          ProgressView(value: progress.fraction)
            .progressViewStyle(.linear)
          HStack {
            Text(progress.action)
            Spacer()
            Text("\(progress.completed) of \(progress.total)")
              .monospacedDigit()
          }
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 11)
    .background(.bar)
    .animation(.easeInOut(duration: 0.2), value: model.batches)
  }

  private var simulatorTable: some View {
    GeometryReader { viewport in
      ScrollView(.horizontal) {
        VStack(spacing: 0) {
          tableHeader
          Divider()

          GeometryReader { geometry in
            Group {
              if model.isRefreshing && model.devices.isEmpty {
                VStack(spacing: 12) {
                  ProgressView()
                  Text("Loading simulators…")
                    .foregroundStyle(.secondary)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
              } else if filteredDevices.isEmpty {
                ContentUnavailableView(
                  searchText.isEmpty ? "No iOS Simulators" : "No Matches",
                  systemImage: "iphone.slash",
                  description: Text(
                    searchText.isEmpty
                      ? "Install an iOS Simulator runtime in Xcode."
                      : "Try a different name, UDID, or iOS version.")
                )
                .frame(width: geometry.size.width, height: geometry.size.height)
              } else {
                ScrollView {
                  LazyVStack(spacing: 0) {
                    ForEach(filteredDevices) { device in
                      SimulatorRow(
                        device: device,
                        diskCleanupCategories: selectedCleanableDiskCategories,
                        managementSheet: $managementSheet
                      )
                      Divider().padding(.leading, 48)
                    }
                  }
                  .frame(width: geometry.size.width, alignment: .top)
                }
              }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
          }
        }
        .frame(width: max(viewport.size.width, 950), height: viewport.size.height, alignment: .top)
      }
    }
  }

  private var tableHeader: some View {
    HStack(spacing: 12) {
      Color.clear.frame(width: 30, height: 1)
      Text("SIMULATOR")
        .frame(minWidth: 255, maxWidth: .infinity, alignment: .leading)
      Text("RUNTIME").frame(width: 74, alignment: .leading)
      Text("BOOT").frame(width: 86, alignment: .leading)
      Text("SERVICES").frame(width: 150, alignment: .leading)
      Text("DISK SIZE").frame(width: 105, alignment: .leading)
      Text("RAM USAGE").frame(width: 82, alignment: .leading)
      Color.clear.frame(width: 28, height: 1)
    }
    .font(.system(size: 10, weight: .semibold))
    .foregroundStyle(.secondary)
    .padding(.horizontal, 18)
    .padding(.vertical, 8)
    .background(Color(nsColor: .controlBackgroundColor).opacity(0.65))
  }

  private var selectionAllImage: String {
    if !filteredDevices.isEmpty && filteredUDIDs.isSubset(of: model.selectedUDIDs) {
      return "checkmark.square.fill"
    }
    if !filteredUDIDs.intersection(model.selectedUDIDs).isEmpty {
      return "minus.square.fill"
    }
    return "square"
  }

  private var lastUpdatedText: String {
    guard let date = model.lastUpdated else { return "Loading simulator status…" }
    return "Updated \(date.formatted(date: .omitted, time: .shortened))"
  }

  @ViewBuilder
  private func managementSheetContent(for sheet: SimulatorManagementSheet) -> some View {
    switch sheet {
    case .servicePreview(let devices, let unslim):
      ServiceSafetyView(devices: devices, unslim: unslim)
    case .clone(let device):
      SimulatorNameSheet(
        title: "Clone Simulator",
        actionTitle: "Clone Simulator",
        systemImage: "plus.square.on.square",
        explanation:
          "The clone copies the source simulator’s apps, data, settings, and current SwiftSimSlim service profile. SwiftSimSlim rebases simulator-local links, rebuilds generated app registrations, and audits the running clone for open paths into the source. SwiftSimSlim may briefly boot a shutdown source to read its profile, or briefly shut down a booted source to make the copy. The source returns to its original boot state, and the clone finishes shutdown.",
        initialName: "\(device.name) Copy",
        device: device
      ) { name in
        Task { await model.cloneSimulator(device, named: name) }
      }

    case .slimmingRecommendation(let devices):
      SlimmingRecommendationSheet(devices: devices) { device in
        presentAfterSheetDismissal(.clone(device))
      } onContinue: {
        presentAfterSheetDismissal(.servicePreview(devices, unslim: false))
      }

    case .rename(let device):
      SimulatorNameSheet(
        title: "Rename Simulator",
        actionTitle: "Rename Simulator",
        systemImage: "pencil",
        explanation:
          "Renaming changes only the simulator’s display name. Its apps, data, runtime, and service profile stay the same.",
        initialName: device.name,
        device: device
      ) { name in
        Task { await model.renameSimulator(device, to: name) }
      }

    case .erase(let devices):
      SimulatorDestructiveSheet(action: .erase, devices: devices) {
        Task { await model.eraseSimulators(devices) }
      }

    case .delete(let devices):
      SimulatorDestructiveSheet(action: .delete, devices: devices) {
        Task { await model.deleteSimulators(devices) }
      }

    case .diskCleanup(let devices, let categories):
      DiskCleanupConfirmationSheet(devices: devices, categories: categories) { device in
        presentAfterSheetDismissal(.clone(device))
      } onConfirm: { categoryIDs in
        Task { await model.cleanDisk(devices, categoryIDs: categoryIDs) }
      }
    }
  }

  private func presentAfterSheetDismissal(_ sheet: SimulatorManagementSheet) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
      managementSheet = sheet
    }
  }
}

#if DEBUG
  #Preview("Simulator management") {
    ContentView()
      .environment(AppModel.preview())
      .frame(width: 1500, height: 900)
  }
#endif
