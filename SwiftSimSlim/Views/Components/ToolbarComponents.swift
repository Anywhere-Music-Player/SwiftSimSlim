import AppKit
import SwiftUI

struct ToolbarActionLabel: View {
  let title: String
  let systemImage: String

  init(_ title: String, systemImage: String) {
    self.title = title
    self.systemImage = systemImage
  }

  var body: some View {
    Label(title, systemImage: systemImage)
      .accessibilityLabel(title)
  }
}

struct CollapsibleToolbarSearch: View {
  @Binding var text: String
  let prompt: String
  @Binding var isExpanded: Bool

  @ViewBuilder
  var body: some View {
    if isExpanded {
      if #available(macOS 26.0, *) {
        searchContent
          .padding(.horizontal, 10)
          .frame(width: 300, height: 32)
      } else {
        searchContent
          .padding(.horizontal, 10)
          .frame(width: 280, height: 30)
          .background(.regularMaterial, in: Capsule())
      }
    } else {
      Button {
        withAnimation(.easeInOut(duration: 0.16)) {
          isExpanded = true
        }
      } label: {
        ToolbarActionLabel(
          "Search",
          systemImage: text.isEmpty ? "magnifyingglass" : "magnifyingglass.circle.fill"
        )
      }
      .help(text.isEmpty ? prompt : "\(prompt) — filter active")
      .accessibilityLabel(text.isEmpty ? prompt : "\(prompt), filter active")
    }
  }

  private var searchContent: some View {
    HStack(spacing: 7) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)

      AutofocusingToolbarTextField(
        text: $text,
        prompt: prompt,
        onSubmit: {
          if text.isEmpty {
            collapse()
          }
        },
        onCancel: collapse
      )
      .frame(maxWidth: .infinity)

      if !text.isEmpty {
        Button {
          text = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Clear search")
      }

      Button {
        collapse()
      } label: {
        Image(systemName: "chevron.right")
          .foregroundStyle(.secondary)
      }
      .buttonStyle(.plain)
      .help("Collapse search")
      .accessibilityLabel("Collapse search")
    }
    .onExitCommand(perform: collapse)
  }

  private func collapse() {
    withAnimation(.easeInOut(duration: 0.16)) {
      isExpanded = false
    }
  }
}

struct AutofocusingToolbarTextField: NSViewRepresentable {
  @Binding var text: String
  let prompt: String
  let onSubmit: () -> Void
  let onCancel: () -> Void

  func makeCoordinator() -> Coordinator {
    Coordinator(parent: self)
  }

  func makeNSView(context: Context) -> AutofocusingTextField {
    let textField = AutofocusingTextField()
    textField.delegate = context.coordinator
    textField.stringValue = text
    textField.placeholderString = prompt
    textField.isBezeled = false
    textField.drawsBackground = false
    textField.focusRingType = .none
    textField.usesSingleLineMode = true
    textField.lineBreakMode = .byTruncatingTail
    textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
    textField.setAccessibilityLabel(prompt)
    return textField
  }

  func updateNSView(_ textField: AutofocusingTextField, context: Context) {
    context.coordinator.parent = self
    if textField.stringValue != text {
      textField.stringValue = text
    }
    textField.placeholderString = prompt
    textField.setAccessibilityLabel(prompt)
  }

  final class Coordinator: NSObject, NSTextFieldDelegate {
    var parent: AutofocusingToolbarTextField

    init(parent: AutofocusingToolbarTextField) {
      self.parent = parent
    }

    func controlTextDidChange(_ notification: Notification) {
      guard let textField = notification.object as? NSTextField else { return }
      if parent.text != textField.stringValue {
        parent.text = textField.stringValue
      }
    }

    func control(
      _ control: NSControl,
      textView: NSTextView,
      doCommandBy commandSelector: Selector
    ) -> Bool {
      if commandSelector == #selector(NSResponder.insertNewline(_:)) {
        parent.onSubmit()
        return true
      }
      if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
        parent.onCancel()
        return true
      }
      return false
    }
  }
}

final class AutofocusingTextField: NSTextField {
  private var hasRequestedFocus = false

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil, !hasRequestedFocus else { return }
    hasRequestedFocus = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.window?.makeFirstResponder(self)
    }
  }
}

struct MetricPill: View {
  let value: String
  let label: String
  let color: Color

  var body: some View {
    HStack(spacing: 7) {
      Text(value)
        .font(.system(.title3, design: .rounded, weight: .bold))
        .foregroundStyle(color)
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(color.opacity(0.1), in: Capsule())
  }
}
