import AppKit
import SwiftUI

struct ActivityPanel: View {
  @Environment(AppModel.self) private var model
  @State private var showsCommands = false

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Label("Activity", systemImage: "list.bullet.rectangle")
          .font(.subheadline.weight(.semibold))
        if model.isBusy {
          ProgressView().controlSize(.small)
          Text(model.operationSummary).font(.caption).foregroundStyle(.secondary)
        }
        Spacer()
        Button {
          withAnimation { showsCommands.toggle() }
        } label: {
          Label("Command Details", systemImage: showsCommands ? "chevron.down" : "chevron.right")
        }
        .buttonStyle(.borderless)
        Button("Copy Log", systemImage: "doc.on.doc") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(model.commandLog.joined(separator: "\n"), forType: .string)
        }
        .disabled(model.commandLog.isEmpty)
        Button("Clear") { model.clearActivity() }
          .disabled(model.activity.isEmpty && model.commandLog.isEmpty)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 8)
      if showsCommands {
        ScrollViewReader { reader in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 3) {
              if model.commandLog.isEmpty {
                Text("Commands and output will appear here when an operation starts.")
                  .foregroundStyle(.secondary)
              }
              ForEach(Array(model.commandLog.enumerated()), id: \.offset) { item in
                Text(item.element).textSelection(.enabled).frame(
                  maxWidth: .infinity, alignment: .leading)
              }
              Color.clear.frame(height: 1).id("latest")
            }
            .font(.system(.caption, design: .monospaced))
            .padding(.horizontal, 16)
          }
          .onChange(of: model.commandLog.last) { _, _ in reader.scrollTo("latest", anchor: .bottom)
          }
        }
        .frame(height: 190)
      } else if model.activity.isEmpty {
        Label(
          model.isBusy
            ? "Operation in progress. Open Command Details to follow each step."
            : "Ready. Select simulators, then choose an action from the toolbar.",
          systemImage: model.isBusy ? "clock" : "checkmark.circle"
        )
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.bottom, 10)
      } else {
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(model.activity.prefix(7)) { entry in
              HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(
                  systemName: entry.level == .failure
                    ? "exclamationmark.triangle.fill"
                    : entry.level == .success ? "checkmark.circle.fill" : "arrow.right.circle"
                )
                .foregroundStyle(
                  entry.level == .failure ? .red : entry.level == .success ? .green : .blue)
                Text(entry.date.formatted(date: .omitted, time: .standard)).monospacedDigit()
                  .foregroundStyle(.tertiary)
                Text(entry.message).textSelection(.enabled)
                Spacer()
              }.font(.caption)
            }
          }.padding(.horizontal, 16).padding(.bottom, 9)
        }.frame(height: 85)
      }
    }.background(.bar)
  }
}
