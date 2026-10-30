import SwiftUI

struct AppStorageView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  let device: SimulatorDevice
  @State private var search = ""
  @State private var selection: String?
  @State private var confirmation: AppStorageConfirmation?

  private var snapshot: SimulatorAppStorage? { model.appStorageSnapshots[device.udid] }
  private var busy: Bool { model.isOperating(device) }
  private var apps: [InstalledSimulatorApp] {
    (snapshot?.apps ?? []).filter {
      search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
        || $0.bundleID.localizedCaseInsensitiveContains(search)
    }
  }
  private var selected: InstalledSimulatorApp? { apps.first { $0.id == selection } }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Apps & Data · \(device.name)").font(.title2.bold())
      Text(
        "Developer-installed apps, largest first. Sizes use allocated disk space; APFS sharing means reclaimed space can differ. System runtime apps are excluded."
      )
      .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      TextField("Find an app or bundle identifier", text: $search)
        .textFieldStyle(.roundedBorder)
      if busy {
        ProgressView(model.activeOperations[device.udid] ?? "Working…")
      }
      if let error = model.appStorageErrors[device.udid] {
        Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
      }
      Table(apps, selection: $selection) {
        TableColumn("App") { app in
          VStack(alignment: .leading) {
            Text(app.name).fontWeight(.medium)
            Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
          }
          .help(app.issue ?? app.bundleID)
        }.width(min: 200, ideal: 270)
        TableColumn("Bundle") { app in Text(size(app.bundleBytes)) }.width(85)
        TableColumn("Documents") { app in Text(size(app.documentsBytes)) }.width(90)
        TableColumn("Other Data") { app in Text(size(app.otherDataBytes)) }.width(90)
        TableColumn("Total") { app in
          Text(size(app.totalBytes) + (app.hasCompleteSize ? "" : " + ?"))
        }.width(110)
      }
      .frame(minHeight: 240)
      if let app = selected {
        if let issue = app.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
        HStack {
          ForEach(AppStorageAction.allCases) { action in
            Button(action.title + "…", role: .destructive) {
              confirmation = .init(app: app, action: action)
            }
            .disabled(busy || !app.canManage || (action != .uninstall && app.dataPath == nil))
          }
        }
      } else {
        Text("Select one app to review deletion options.").font(.callout).foregroundStyle(
          .secondary)
      }
      if let snapshot {
        Text(
          "Shared App Groups: \(size(snapshot.sharedBytes)) · User Media: \(size(snapshot.mediaBytes))"
        )
        .font(.callout.weight(.medium))
        Text(
          "App totals include the bundle and its main private container. Shared groups and extension containers are not attributed to individual apps. Photos-library files are managed through Photos, so its database stays consistent."
        )
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        Text("Measured \(snapshot.capturedAt.formatted()). Running apps can change these sizes.")
          .font(.caption).foregroundStyle(.secondary)
      }
      HStack {
        Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Refresh") { Task { await model.inspectApps(device) } }.disabled(busy)
        Spacer()
        Button("Open Photos in Simulator") { Task { await model.openPhotos(device) } }
          .disabled(busy)
          .help("Starts the simulator if needed. Select and delete photos or videos in Photos.")
      }
    }
    .padding(22)
    .frame(width: 850, height: 620)
    .task { await model.inspectApps(device) }
    .sheet(item: $confirmation) { request in
      AppStorageConfirmationView(request: request, device: device) {
        Task { await model.manageApp(request.app, action: request.action, on: device) }
      }
    }
  }

  private func size(_ bytes: Int64?) -> String {
    bytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "Unknown"
  }
}

private struct AppStorageConfirmation: Identifiable {
  let id = UUID()
  let app: InstalledSimulatorApp
  let action: AppStorageAction
}

private struct AppStorageConfirmationView: View {
  @Environment(\.dismiss) private var dismiss
  let request: AppStorageConfirmation
  let device: SimulatorDevice
  let onConfirm: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(request.action.title + "?").font(.title2.bold())
      Text(request.app.name + "\n" + request.app.bundleID).textSelection(.enabled)
      Text("Simulator: \(device.name)\n\(device.udid)").font(.caption).textSelection(.enabled)
      Text(request.action.explanation).fixedSize(horizontal: false, vertical: true)
      Text(
        "This is permanent and has no automatic backup. Clone the simulator first if you need to keep this data. The simulator may briefly boot for validation; file cleanup waits for shutdown. Its original boot state is restored afterward."
      )
      .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Spacer()
        Button(request.action.title, role: .destructive) {
          dismiss()
          onConfirm()
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .fontWeight(.bold)
      }
    }
    .padding(24).frame(width: 520)
  }
}
