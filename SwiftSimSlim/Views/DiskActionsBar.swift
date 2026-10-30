import SwiftUI

/// Disk actions stay visible above the simulator list while the category sidebar scrolls.
struct DiskActionsBar: View {
  @Environment(AppModel.self) private var model
  let onClean: () -> Void

  var body: some View {
    ViewThatFits(in: .horizontal) {
      HStack(spacing: 20) {
        summary
        Spacer(minLength: 12)
        actions
      }
      VStack(alignment: .leading, spacing: 12) {
        summary
        actions
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 20)
    .padding(.vertical, 14)
    .background(Color.accentColor.opacity(0.05))
  }

  private var summary: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text("Disk Cleanup").font(.headline)
      if model.selectionCount == 0 {
        Text("Select a simulator, then choose cleanup categories.")
          .foregroundStyle(.secondary)
      } else {
        Text("Selected for cleanup: \(model.selectedDiskCleanupSizeText())")
          .foregroundStyle(.secondary)
      }
      if let result = model.selectedDiskCleanupResultText {
        Label(result, systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      }
    }
    .font(.callout)
    .fixedSize(horizontal: false, vertical: true)
  }

  private var actions: some View {
    HStack(spacing: 10) {
      Button {
        Task { await model.analyzeDiskSelection() }
      } label: {
        Label("Re-analyze Selected", systemImage: "arrow.clockwise")
      }
      .buttonStyle(.bordered)
      .disabled(!model.canOperateOnSelection)
      .help("Refresh disk sizes and cleanup estimates for the selected simulators")

      Button(role: .destructive, action: onClean) {
        Label("Clean Disk…", systemImage: "externaldrive.badge.xmark")
      }
      .buttonStyle(.borderedProminent)
      .tint(.red)
      .fontWeight(.bold)
      .disabled(!model.canCleanDiskSelection)
      .help("Review the selected categories and confirm permanent cleanup")
    }
    .controlSize(.large)
    .fixedSize()
  }
}

#if DEBUG
  @MainActor private func diskActionsPreviewModel() -> AppModel {
    let udid = "00000000-0000-0000-0000-000000000001"
    return AppModel.preview(
      diskPlan: .init(
        udid: udid, totalBytes: 3_260_000_000, cleanableBytes: 2_800_000_000,
        categories: [.init(id: "wallpaper-cache", bytes: 2_800_000_000, targets: 100)], storage: []),
      cleanupResult: .init(
        udid: udid, categoryIds: ["caches"], beforeBytes: 367_000_000,
        afterBytes: 0, reclaimedBytes: 367_000_000, wasBooted: false, bootStateRestored: false))
  }

  #Preview("Disk actions — wide") {
    DiskActionsBar(onClean: {}).environment(diskActionsPreviewModel()).frame(width: 1050)
  }

  #Preview("Disk actions — narrow") {
    DiskActionsBar(onClean: {}).environment(diskActionsPreviewModel()).frame(width: 620)
  }
#endif
