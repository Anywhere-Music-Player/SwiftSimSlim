import SwiftUI
import UniformTypeIdentifiers

struct ServiceBackupDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  let data: Data
  init(data: Data) { self.data = data }
  init(configuration: ReadConfiguration) throws {
    data = configuration.file.regularFileContents ?? Data()
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

struct SavedStateActions: View {
  @Environment(AppModel.self) private var model
  let device: SimulatorDevice

  var body: some View {
    Group {
      Button("Restore Saved State") {
        Task { await model.restoreSavedState(for: device) }
      }
      .disabled(model.serviceBackups[device.udid] == nil || model.isOperating(device))
      Button("Export Saved State…") {
        do {
          guard let backup = model.serviceBackups[device.udid] else { return }
          model.serviceBackupExport = .init(udid: device.udid, data: try backup.exportedData())
        } catch { model.presentedError = .init(message: error.localizedDescription) }
      }
      .disabled(model.serviceBackups[device.udid] == nil)
    }
  }
}

struct ServiceSafetyView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let devices: [SimulatorDevice]
  var unslim = false
  @State private var profile: ServiceProfileSnapshot?
  @State private var plans: [ServiceChangePlan] = []
  @State private var loading = true
  @State private var errorMessage: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(unslim ? "Preview Unslim" : "Preview Service Changes")
        .font(.title2.bold())
      Text(
        "Preview only reads state. Applying saves the original service state first, then verifies the new profile after boot. A stopped simulator is briefly booted to capture its original state."
      )
      .font(.subheadline).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      if loading {
        ProgressView("Reading service state…").frame(maxWidth: .infinity)
      }
      if let errorMessage {
        Text(errorMessage).foregroundStyle(.red).textSelection(.enabled)
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          ForEach(plans) { plan in
            VStack(alignment: .leading, spacing: 8) {
              Text("\(plan.device.name) · iOS \(plan.device.osVersion)").font(.headline)
              Text(plan.device.udid).font(.caption.monospaced()).foregroundStyle(.secondary)
              Text(
                plan.isLive
                  ? "Live state · \(plan.capturedAt.formatted())"
                  : "Offline estimate — actual changes will be resolved from live state when applied."
              )
              .font(.caption).foregroundStyle(plan.isLive ? Color.secondary : .orange)
              Text("\(plan.disable.count) to disable · \(plan.enable.count) to enable")
                .font(.subheadline.weight(.medium))
              if plan.disable.isEmpty && plan.enable.isEmpty {
                Text("No service changes in this snapshot.").foregroundStyle(.secondary)
              }
              ForEach(plan.disable, id: \.self) { label in
                Text("− Disable  \(label)").font(.caption.monospaced())
              }
              ForEach(plan.enable, id: \.self) { label in
                Text("+ Enable   \(label)").font(.caption.monospaced())
              }
            }
            Divider()
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
      }
      Text(
        "Restore Saved State returns managed services and boot state to the latest saved snapshot. Required services stay enabled; unmanaged settings are preserved. Unslim enables all managed services."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Refresh Preview") { Task { await refresh() } }.disabled(loading)
        Spacer()
        Button(unslim ? "Apply Unslim" : "Apply Profile") {
          guard let profile else { return }
          let reviewed = plans
          dismiss()
          Task { await model.applyReviewedProfile(profile, plans: reviewed, to: devices) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(loading || plans.count != devices.count || !model.operations.canReserve(devices))
      }
    }
    .padding(24)
    .frame(width: 690, height: 640)
    .task {
      do {
        profile = try ServiceProfileSnapshot(
          categories: unslim ? [] : model.keptCategoryIDs,
          labels: unslim ? ServiceCatalog.slimmable : model.keptServiceLabels,
          preserveBootState: model.preserveBootState)
        await refresh()
      } catch {
        errorMessage = error.localizedDescription
        loading = false
      }
    }
  }

  private func refresh() async {
    guard let profile else { return }
    loading = true
    plans = []
    errorMessage = nil
    await model.previewProfile(profile, for: devices)
    plans = devices.compactMap { model.servicePlans[$0.udid] }
    if plans.count != devices.count {
      errorMessage =
        "Could not read every simulator. See Activity for details, then refresh the preview."
    }
    loading = false
  }
}

#if DEBUG
  #Preview("Service change preview") {
    let device = SimulatorDevice(
      udid: "00000000-0000-0000-0000-000000000001", name: "iPhone QA", state: "Booted",
      osVersion: "27.0", managedDisabled: 0, managedTotal: ServiceCatalog.slimmable.count,
      statusError: nil, memory: nil, memoryError: nil)
    let model = AppModel(
      deviceSets: ["/preview-only"],
      runner: CommandRunner(executor: { _, arguments in
        let output: String
        if arguments.contains("list") {
          output =
            "{\"devices\":{\"com.apple.CoreSimulator.SimRuntime.iOS-27-0\":[{\"udid\":\"00000000-0000-0000-0000-000000000001\",\"name\":\"iPhone QA\",\"state\":\"Booted\",\"isAvailable\":true}]}}"
        } else {
          output = "disabled services = {\n\"com.apple.sharingd\" => disabled\n}"
        }
        return .init(data: Data(output.utf8), errorData: Data(), status: 0)
      }), defaults: UserDefaults(suiteName: "SwiftSimSlim-Preview-\(UUID())")!,
      automaticallyMeasureDisk: false)
    ServiceSafetyView(devices: [device]).environment(model)
  }
#endif
