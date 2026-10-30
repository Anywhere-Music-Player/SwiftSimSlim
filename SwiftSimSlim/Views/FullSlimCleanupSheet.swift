import SwiftUI

struct FullSlimCleanupSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var reopen = true
  let devices: [SimulatorDevice]

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Full Slim & Clean", systemImage: "wand.and.stars")
        .font(.title2.bold())
      Text(
        "Apply Full Slim and clear all supported cleanup categories on \(devices.count) selected simulator\(devices.count == 1 ? "" : "s")."
      )
      .fixedSize(horizontal: false, vertical: true)
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(devices) { device in
            Text(device.name).fontWeight(.semibold)
          }
          Divider()
          Label(
            "Disable \(ServiceCatalog.slimmable.count) optional services",
            systemImage: "minus.circle")
          ForEach(DiskStore.categories.filter(\.canClean)) { category in
            Label(category.name, systemImage: "checkmark.circle")
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
      }
      .frame(height: 260)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
      Text(
        "Apps, documents, photos, and app settings are kept. Caches, logs, downloaded speech/models, wallpaper snapshots, and learned system history are permanently removed. Siri and other optional features may stop working; iOS may recreate downloads and indexes."
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Text(
        "Simulators shut down for cleanup. Full Slim reduces service memory use; it does not empty all RAM or erase the entire disk."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      Toggle("Reopen previously booted simulators", isOn: $reopen)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Full Slim & Clean", role: .destructive) {
          let restoreBoot = reopen
          dismiss()
          Task { await model.fullSlimAndClean(devices, preserveBootState: restoreBoot) }
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .fontWeight(.bold)
        .disabled(!model.operations.canReserve(devices))
      }
    }
    .padding(24)
    .frame(width: 580)
  }
}

#if DEBUG
  #Preview("Full Slim & Clean") {
    let model = AppModel.preview(
      diskPlan: .init(
        udid: "00000000-0000-0000-0000-000000000001", totalBytes: 0, cleanableBytes: 0,
        categories: [], storage: []))
    FullSlimCleanupSheet(devices: Array(model.devices.prefix(1))).environment(model)
  }
#endif
