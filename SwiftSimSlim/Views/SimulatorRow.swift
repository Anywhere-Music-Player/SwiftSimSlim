import AppKit
import SwiftUI

struct SimulatorRow: View {
  @Environment(AppModel.self) private var model
  let device: SimulatorDevice
  let diskCleanupCategories: [DiskCleanupCategory]
  @Binding var managementSheet: SimulatorManagementSheet?

  private var isSelected: Bool { model.selectedUDIDs.contains(device.udid) }
  private var operation: String? { model.activeOperations[device.udid] }

  var body: some View {
    VStack(spacing: 7) {
      HStack(spacing: 12) {
        Button {
          model.toggleSelection(device.udid)
        } label: {
          Image(systemName: isSelected ? "checkmark.square.fill" : "square")
            .font(.title3)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
            .frame(width: 30, height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("select-\(device.udid)")
        .accessibilityLabel("Select \(device.name)")

        HStack(spacing: 10) {
          Image(systemName: "iphone")
            .font(.system(size: 19, weight: .medium))
            .foregroundStyle(device.isBooted ? Color.blue : Color.secondary)
            .frame(width: 35, height: 35)
            .background(
              (device.isBooted ? Color.blue : Color.secondary).opacity(0.09),
              in: RoundedRectangle(cornerRadius: 9))
          VStack(alignment: .leading, spacing: 2) {
            Text(device.name)
              .font(.subheadline.weight(.semibold))
            HStack(spacing: 5) {
              Text(device.udid)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .textSelection(.enabled)

              Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(device.udid, forType: .string)
              } label: {
                Image(systemName: "doc.on.doc")
                  .font(.system(size: 9, weight: .medium))
                  .frame(width: 14, height: 14)
              }
              .buttonStyle(.plain)
              .foregroundStyle(.secondary)
              .help("Copy UDID")
              .accessibilityLabel("Copy UDID for \(device.name)")
            }
          }
        }
        .frame(minWidth: 255, maxWidth: .infinity, alignment: .leading)

        Text("iOS \(device.osVersion)")
          .font(.subheadline)
          .frame(width: 74, alignment: .leading)

        BootStateView(isBooted: device.isBooted)
          .frame(width: 86, alignment: .leading)

        ServiceStateView(
          state: model.slimState(for: device),
          isCached: model.stateIsCached(for: device),
          operation: operation
        )
        .frame(width: 150, alignment: .leading)

        Text(model.diskSizeText(for: device))
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(model.diskSizes[device.udid] == nil ? .tertiary : .secondary)
          .frame(width: 105, alignment: .leading)
          .help("Current allocated size of this simulator on disk")

        Group {
          if let measurement = model.measurements[device.udid] {
            Text(measurement.memoryText)
              .font(.subheadline.monospacedDigit())
          } else {
            Text("—")
              .foregroundStyle(.tertiary)
          }
        }
        .frame(width: 82, alignment: .leading)

        Menu {
          Section("Power") {
            if device.isBooted {
              Button {
                Task { await model.shutdownSimulator(device) }
              } label: {
                Label("Shut Down Simulator", systemImage: "stop.fill")
              }
            } else {
              Button {
                Task { await model.bootSimulator(device) }
              } label: {
                Label("Boot Simulator", systemImage: "play.fill")
              }
            }
          }
          .disabled(model.isOperating(device))

          Section("Service Profile") {
            Button {
              managementSheet = .slimmingRecommendation([device])
            } label: {
              Label("Slim Simulator", systemImage: "minus.circle")
            }

            Button {
              Task { await model.restoreOriginalServices(for: device) }
            } label: {
              Label("Unslim Simulator", systemImage: "plus.circle")
            }
          }
          .disabled(model.isOperating(device))

          Section("Disk Space") {
            Button(role: .destructive) {
              managementSheet = .diskCleanup([device], diskCleanupCategories)
            } label: {
              Label("Clean Disk Data", systemImage: "externaldrive.badge.xmark")
            }
            .disabled(!model.canCleanDisk([device]))
          }
          .disabled(model.isOperating(device))

          Section("Simulator") {
            Button {
              managementSheet = .clone(device)
            } label: {
              Label("Clone Simulator", systemImage: "plus.square.on.square")
            }

            Button {
              managementSheet = .rename(device)
            } label: {
              Label("Rename Simulator", systemImage: "pencil")
            }
          }
          .disabled(model.isOperating(device))

          Section("Finder") {
            Button {
              openInFinder(simulatorDirectoryURL)
            } label: {
              Label("Show Simulator in Finder", systemImage: "folder")
            }

            Button {
              openInFinder(appDataContainersURL)
            } label: {
              Label("Show App Data Containers in Finder", systemImage: "folder.badge.gearshape")
            }
          }

          Section("Status") {
            Button {
              Task { await model.refresh() }
            } label: {
              Label("Refresh Simulator Status", systemImage: "arrow.clockwise")
            }

            Button {
              Task { await model.measure(device) }
            } label: {
              Label("Refresh RAM", systemImage: "memorychip")
            }
            .disabled(!device.isBooted || model.isOperating(device))
          }

          Section("Selection") {
            Button(isSelected ? "Deselect Simulator" : "Select Simulator") {
              model.toggleSelection(device.udid)
            }
          }

          Section("Destructive Actions") {
            Button(role: .destructive) {
              managementSheet = .erase([device])
            } label: {
              Label("Erase Simulator", systemImage: "eraser")
            }

            Button(role: .destructive) {
              managementSheet = .delete([device])
            } label: {
              Label("Delete Simulator", systemImage: "trash")
            }
          }
          .disabled(model.isOperating(device))
        } label: {
          Image(systemName: "ellipsis")
            .frame(width: 20)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(width: 28)
      }

      if let operation {
        HStack(spacing: 8) {
          ProgressView()
            .controlSize(.small)
          Text(operation)
          if let started = model.operationStarted[device.udid] {
            Text(started, style: .timer).monospacedDigit().foregroundStyle(.secondary)
          }
          Spacer()
          Text("Booting and rebooting can take a few minutes")
            .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 48)
      }
    }
    .padding(.horizontal, 18)
    .padding(.vertical, 9)
    .background(isSelected ? Color.accentColor.opacity(0.075) : Color.clear)
    .animation(.easeInOut(duration: 0.16), value: isSelected)
    .animation(.easeInOut(duration: 0.16), value: operation)
  }

  private var simulatorDirectoryURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Developer/CoreSimulator/Devices", isDirectory: true)
      .appendingPathComponent(device.udid, isDirectory: true)
  }

  private var appDataContainersURL: URL {
    simulatorDirectoryURL
      .appendingPathComponent("data", isDirectory: true)
      .appendingPathComponent("Containers/Data/Application", isDirectory: true)
  }

  private func openInFinder(_ url: URL) {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else {
      model.presentedError = PresentedError(
        message: "The directory for \(device.name) does not exist at \(url.path)."
      )
      return
    }
    guard NSWorkspace.shared.open(url) else {
      model.presentedError = PresentedError(
        message: "Finder could not open \(url.path)."
      )
      return
    }
  }
}

struct BootStateView: View {
  let isBooted: Bool

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(isBooted ? Color.green : Color.gray)
        .frame(width: 7, height: 7)
      Text(isBooted ? "Booted" : "Shutdown")
        .font(.subheadline)
        .foregroundStyle(isBooted ? Color.primary : Color.secondary)
    }
  }
}

struct ServiceStateView: View {
  let state: ServiceSlimState
  let isCached: Bool
  let operation: String?

  var body: some View {
    HStack(spacing: 8) {
      if operation != nil {
        ProgressView()
          .controlSize(.small)
          .frame(width: 17)
      } else {
        Image(systemName: state.systemImage)
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 17)
      }
      VStack(alignment: .leading, spacing: 1) {
        Text(operation == nil ? state.title : "Changing…")
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
        if isCached && operation == nil {
          Text("last verified")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
      }
    }
    .help(
      isCached
        ? "Last verified while booted; launchd state cannot be queried live while this simulator is shutdown."
        : state.title
    )
    .accessibilityLabel("Service slimming: \(state.title)")
  }

}
