import AppKit
import SwiftUI

struct ProfileSidebar: View {
  @Environment(AppModel.self) private var model
  @Binding var mode: SlimmingMode
  @State private var serviceSearchText = ""

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 12) {
        Image(nsImage: NSApplication.shared.applicationIconImage)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
          .frame(width: 46, height: 46)
        VStack(alignment: .leading, spacing: 2) {
          Text("SimSlim")
            .font(.title2.bold())
          Text(mode == .memory ? "Service slimming · reversible" : "Disk analysis & cleanup")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(18)

      Picker("Slimming mode", selection: $mode) {
        ForEach(SlimmingMode.allCases) { option in
          Text(option.rawValue).tag(option)
        }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 16)
      .padding(.bottom, 14)

      Divider()

      ScrollView {
        Group {
          if mode == .memory {
            memoryContent
          } else {
            diskContent
          }
        }
        .padding(16)
      }
    }
    .background(.regularMaterial)
  }

  private var sortedMemoryCategories: [SlimCategory] {
    model.categories.sorted {
      if $0.approxMemoryMB == $1.approxMemoryMB {
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      return $0.approxMemoryMB > $1.approxMemoryMB
    }
  }

  private var filteredMemoryCategories: [SlimCategory] {
    let query = serviceSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return sortedMemoryCategories }
    return sortedMemoryCategories.filter { category in
      category.name.localizedCaseInsensitiveContains(query)
        || category.description.localizedCaseInsensitiveContains(query)
        || category.downside.localizedCaseInsensitiveContains(query)
        || category.labels.contains {
          $0.localizedCaseInsensitiveContains(query)
        }
        || category.labels.contains {
          category.serviceDescription(for: $0).localizedCaseInsensitiveContains(query)
        }
        || category.alwaysEnabledServices.contains {
          $0.label.localizedCaseInsensitiveContains(query)
            || $0.reason.localizedCaseInsensitiveContains(query)
        }
    }
  }

  private var sortedDiskCategories: [DiskCleanupCategory] {
    model.diskCleanupCategories.filter(\.canClean).sorted {
      let left = model.diskCleanupBytes(for: $0.id) ?? 0
      let right = model.diskCleanupBytes(for: $1.id) ?? 0
      if left == right {
        if $0.canClean != $1.canClean { return $0.canClean }
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
      return left > right
    }
  }

  private var memoryContent: some View {
    VStack(alignment: .leading, spacing: 15) {
      stateLegend
      if !model.activeOperations.isEmpty {
        Text(
          "Profile changes apply to new operations. Running and queued operations keep their original settings."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text("Services to keep")
            .font(.headline)
          Spacer()
          Button("Full Slim") { model.resetProfile() }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .disabled(
              (model.keptCategoryIDs.isEmpty && model.keptServiceLabels.isEmpty))
        }
        Text(
          "Sorted by estimated idle memory use. Enable categories your tests need; estimates vary and are not additive."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }

      SidebarServiceSearch(text: $serviceSearchText)

      VStack(alignment: .leading, spacing: 8) {
        ForEach(filteredMemoryCategories) { category in
          CategoryToggle(
            category: category,
            serviceQuery: serviceSearchText
          )
        }

        if !serviceSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
          && filteredMemoryCategories.isEmpty
        {
          Text("No services match \u{201c}\(serviceSearchText)\u{201d}")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 72)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Toggle(
        "Preserve current boot state",
        isOn: Binding(get: { model.preserveBootState }, set: { model.preserveBootState = $0 })
      )
      .font(.subheadline.weight(.medium))
      Text(
        "A simulator that starts shutdown will return to shutdown after its service profile is changed."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)

      VStack(alignment: .leading, spacing: 7) {
        Label("\(model.disabledDaemonCount) services will be disabled", systemImage: "circle")
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.green)
        Text("Core workflow and deadlock-prone daemons are never disabled.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
    }
  }

  private var diskContent: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 5) {
        HStack {
          Text("Cleanup")
            .font(.headline)
          Spacer()
          Text(model.selectedDiskCleanupSizeText())
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(model.diskAnalysisCoversSelection ? Color.orange : Color.secondary)
        }
        Text("Updates automatically when your selection changes. Analysis is read-only.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        Button {
          Task { await model.analyzeDiskSelection() }
        } label: {
          Label("Re-analyze Selected", systemImage: "arrow.clockwise")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(!model.canOperateOnSelection)
        .help("Refresh disk usage for the selected simulators")
      }

      VStack(alignment: .leading, spacing: 8) {
        ForEach(sortedDiskCategories) { category in
          DiskCleanupCategoryToggle(category: category)
        }
      }

      if model.diskAnalysisCoversSelection {
        VStack(alignment: .leading, spacing: 8) {
          Text("Storage breakdown")
            .font(.headline)
          Text("Read-only sizes. These files are never selected for cleanup.")
            .font(.caption)
            .foregroundStyle(.secondary)

          ForEach(model.diskStorageRows) { storage in
            DiskStorageRow(
              storage: storage,
              sizeText: model.diskStorageSizeText(for: storage.id)
            )
          }
        }
      }

      Toggle(
        "Reopen previously booted simulators",
        isOn: Binding(get: { model.preserveBootState }, set: { model.preserveBootState = $0 })
      )
      .font(.subheadline.weight(.medium))

      VStack(alignment: .leading, spacing: 7) {
        Text(
          "Required Siri assets aren’t offered for deletion — iOS restores them automatically on launch."
        )
        .font(.caption.weight(.semibold))
        .foregroundStyle(.blue)
        Text("Built-in apps and core OS resources are never modified.")
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var stateLegend: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Service state")
        .font(.headline)
      HStack(spacing: 13) {
        LegendItem(icon: "circle.fill", label: "Stock")
        LegendItem(icon: "circle.lefthalf.filled", label: "Partial")
        LegendItem(icon: "circle", label: "Slim")
      }
      .foregroundStyle(.secondary)
    }
  }
}

struct SidebarServiceSearch: View {
  @Binding var text: String

  var body: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      TextField("Find a service", text: $text)
        .textFieldStyle(.plain)
        .accessibilityLabel("Find a service")

      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear service search")
      }
    }
    .padding(.horizontal, 9)
    .frame(height: 29)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
    .overlay {
      RoundedRectangle(cornerRadius: 7)
        .stroke(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
    }
  }
}

struct DiskCleanupCategoryToggle: View {
  @Environment(AppModel.self) private var model
  let category: DiskCleanupCategory

  private var isSelected: Binding<Bool> {
    Binding(
      get: { model.selectedDiskCleanupCategoryIDs.contains(category.id) },
      set: { model.setDiskCleanupCategory(category, selected: $0) }
    )
  }

  private var accentColor: Color {
    category.id == "linguistic-data" ? .blue : .orange
  }

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      VStack(alignment: .leading, spacing: 6) {
        VStack(alignment: .leading, spacing: 4) {
          Text(category.name)
            .font(.subheadline.weight(.medium))
          if category.risk != "Lower risk" {
            Text(category.risk.uppercased())
              .font(.system(size: 8, weight: .bold))
              .lineLimit(1)
              .fixedSize(horizontal: true, vertical: false)
              .foregroundStyle(accentColor)
              .padding(.horizontal, 5)
              .padding(.vertical, 2)
              .background(accentColor.opacity(0.1), in: Capsule())
          }
        }

        Label(model.diskCleanupSizeText(for: category.id), systemImage: "internaldrive")
          .font(.caption.weight(.semibold))
          .foregroundStyle(accentColor)

        (Text("Impact: ").fontWeight(.semibold) + Text(category.downside))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        (Text("Afterward: ").fontWeight(.semibold) + Text(category.recovery))
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)

        if !category.canClean {
          Text("Unable to delete — iOS restores automatically on launch.")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.blue)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      if category.canClean {
        Toggle("Remove \(category.name)", isOn: isSelected)
          .labelsHidden()
          .toggleStyle(.switch)
          .padding(.top, 1)
      } else {
        Image(systemName: "lock.fill")
          .foregroundStyle(.secondary)
          .frame(width: 38, height: 24)
          .accessibilityLabel("Deletion unavailable")
          .padding(.top, 1)
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    .help(category.recovery)
  }
}

struct DiskStorageRow: View {
  let storage: SimulatorDiskStorageMeasurement
  let sizeText: String

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: storage.systemImage)
        .foregroundStyle(.secondary)
        .frame(width: 17)

      VStack(alignment: .leading, spacing: 2) {
        Text(storage.name)
          .font(.subheadline.weight(.medium))
        Text(storage.description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 8)

      Text(sizeText)
        .font(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(.secondary)
    }
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
  }
}

struct LegendItem: View {
  let icon: String
  let label: String

  var body: some View {
    Label(label, systemImage: icon)
      .font(.caption)
  }
}

struct CategoryToggle: View {
  @Environment(AppModel.self) private var model
  let category: SlimCategory
  let serviceQuery: String
  @State private var isExpanded = false

  private var isKeptEnabled: Binding<Bool> {
    Binding(
      get: { model.categoryIsKept(category) },
      set: { model.setCategory(category, keptEnabled: $0) }
    )
  }

  private var showsServices: Bool {
    isExpanded || !normalizedQuery.isEmpty
  }

  private var serviceCount: Int {
    category.labels.count + category.alwaysEnabledServices.count
  }

  private var normalizedQuery: String {
    serviceQuery.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var categoryMetadataMatchesQuery: Bool {
    guard !normalizedQuery.isEmpty else { return false }
    return category.name.localizedCaseInsensitiveContains(normalizedQuery)
      || category.description.localizedCaseInsensitiveContains(normalizedQuery)
      || category.downside.localizedCaseInsensitiveContains(normalizedQuery)
  }

  private var visibleLabels: [String] {
    guard !normalizedQuery.isEmpty, !categoryMetadataMatchesQuery else { return category.labels }
    return category.labels.filter {
      $0.localizedCaseInsensitiveContains(normalizedQuery)
        || category.serviceDescription(for: $0).localizedCaseInsensitiveContains(normalizedQuery)
    }
  }

  private var visibleAlwaysEnabledServices: [AlwaysEnabledService] {
    guard !normalizedQuery.isEmpty, !categoryMetadataMatchesQuery else {
      return category.alwaysEnabledServices
    }
    return category.alwaysEnabledServices.filter {
      $0.label.localizedCaseInsensitiveContains(normalizedQuery)
        || $0.reason.localizedCaseInsensitiveContains(normalizedQuery)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Button {
          withAnimation(.easeInOut(duration: 0.16)) {
            isExpanded.toggle()
          }
        } label: {
          HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: showsServices ? "chevron.down" : "chevron.right")
              .font(.caption2.weight(.bold))
              .foregroundStyle(.secondary)
              .frame(width: 9)

            Text(category.name)
              .font(.subheadline.weight(.medium))
              .fixedSize(horizontal: false, vertical: true)

            Text("\(serviceCount)")
              .font(.caption2.monospacedDigit())
              .foregroundStyle(.secondary)
              .padding(.horizontal, 5)
              .padding(.vertical, 1)
              .background(.quaternary, in: Capsule())
          }
        }
        .buttonStyle(.plain)
        .help(showsServices ? "Hide individual services" : "Show individual services")

        Spacer(minLength: 4)

        Toggle("Keep \(category.name) enabled", isOn: isKeptEnabled)
          .labelsHidden()
          .toggleStyle(.switch)
          .padding(.top, 1)
          .help("Keep all controllable services in \(category.name) enabled")
      }

      Label(category.approximateMemoryText, systemImage: "memorychip")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.blue)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Color.blue.opacity(0.1), in: Capsule())
        .help(category.approximateMemoryText)

      (Text("When disabled: ").fontWeight(.semibold) + Text(category.downside))
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if showsServices {
        Divider()

        VStack(alignment: .leading, spacing: 6) {
          ForEach(visibleLabels, id: \.self) { label in
            ServiceToggle(label: label, category: category)
          }

          ForEach(visibleAlwaysEnabledServices) { service in
            AlwaysEnabledServiceRow(service: service)
          }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
  }
}

struct ServiceToggle: View {
  @Environment(AppModel.self) private var model
  let label: String
  let category: SlimCategory

  private var isKeptEnabled: Binding<Bool> {
    Binding(
      get: { model.serviceIsKept(label) },
      set: { model.setService(label, in: category, keptEnabled: $0) }
    )
  }

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "gearshape.2")
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(width: 15)

      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .font(.caption.monospaced())
          .lineLimit(2)
          .textSelection(.enabled)
        Text(category.serviceDescription(for: label))
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer(minLength: 4)

      Toggle("Keep \(label) enabled", isOn: isKeptEnabled)
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 7))
  }
}

struct AlwaysEnabledServiceRow: View {
  let service: AlwaysEnabledService

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: "lock.fill")
        .font(.caption)
        .foregroundStyle(.blue)
        .frame(width: 15)

      VStack(alignment: .leading, spacing: 2) {
        Text(service.label)
          .font(.caption.monospaced())
          .lineLimit(2)
          .textSelection(.enabled)
        Text(service.reason)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 4)

      Text("Always on")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.blue)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Color.blue.opacity(0.1), in: Capsule())
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .background(Color.blue.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
  }
}
