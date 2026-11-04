import SwiftUI

struct FullSlimCleanupSheet: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var reopen = true
  @State private var applyFullSlim = true
  @State private var categories = Set(DiskStore.categories.filter(\.canClean).map(\.id))
  let devices: [SimulatorDevice]

  var body: some View {
    if #available(macOS 15, *) {
      content.presentationSizing(.fitted)
    } else {
      content
    }
  }

  private var content: some View {
    VStack(alignment: .leading, spacing: 16) {
      Label("Full Slim & Clean", systemImage: "wand.and.stars")
        .font(.title2.bold())
      Text(
        "Choose what to optimize on \(devices.count) selected simulator\(devices.count == 1 ? "" : "s")."
      )
      .fixedSize(horizontal: false, vertical: true)
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(devices) { device in
            Text(device.name).fontWeight(.semibold)
          }
          Divider()
          Toggle(
            "Full Slim — disable \(ServiceCatalog.slimmable.count) optional services",
            isOn: $applyFullSlim
          )
          .accessibilityIdentifier("full-slim-services")
          ForEach(DiskStore.categories.filter(\.canClean)) { category in
            Toggle(
              category.name,
              isOn: Binding(
                get: { categories.contains(category.id) },
                set: { selected in
                  if selected {
                    categories.insert(category.id)
                  } else {
                    categories.remove(category.id)
                  }
                })
            )
            .accessibilityIdentifier("full-slim-category-" + category.id)
          }
        }
        .toggleStyle(.checkbox)
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
      }
      .frame(minHeight: 120, idealHeight: 280, maxHeight: .infinity)
      .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
      Text(
        "Apps, documents, photos, and app settings are kept. Only checked categories are permanently cleaned. Siri and other optional features may stop working; iOS may recreate downloads and indexes."
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
        .toggleStyle(.checkbox)
        .controlSize(.small)
      HStack {
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }
          .keyboardShortcut(.cancelAction)
        Button("Full Slim & Clean", role: .destructive) {
          let restoreBoot = reopen
          let slim = applyFullSlim
          let selected = categories
          dismiss()
          Task {
            await model.fullSlimAndClean(
              devices, preserveBootState: restoreBoot, applyFullSlim: slim, categories: selected)
          }
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .fontWeight(.bold)
        .disabled((!applyFullSlim && categories.isEmpty) || !model.operations.canReserve(devices))
      }
    }
    .padding(24)
    .frame(
      minWidth: 480, idealWidth: 620, maxWidth: .infinity,
      minHeight: 480, idealHeight: 660, maxHeight: .infinity
    )
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
