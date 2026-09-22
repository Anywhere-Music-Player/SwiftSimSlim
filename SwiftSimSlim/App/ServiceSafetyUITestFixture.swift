#if DEBUG
  import Foundation

  /// In-memory service backend for clicking the real macOS controls without booting iOS.
  actor ServiceSafetyUITestFixture {
    static let udid = "00000000-0000-0000-0000-000000000099"
    private let root: URL
    private var state = "Booted"
    private var disabled: Set<String> = ["com.apple.FamilyControlsAgent"]

    init(root: URL) { self.root = root }

    func writeOverrides(_ desired: Set<String>) throws {
      disabled = desired
      try JSONEncoder().encode(disabled.sorted()).write(
        to: root.appendingPathComponent("applied-labels.json"), options: .atomic)
    }

    func execute(_ executable: String, _ arguments: [String]) throws -> CommandResult {
      let text: String
      if arguments.contains("list") {
        text = """
          {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-27-0":[
          {"udid":"\(Self.udid)","name":"Service Safety UI Fixture","state":"\(state)","isAvailable":true}]}}
          """
      } else if arguments.contains("print-disabled") {
        text =
          "disabled services = {\n"
          + disabled.sorted().map { "\"\($0)\" => disabled" }.joined(separator: "\n") + "\n}"
      } else if arguments.contains("shutdown") {
        state = "Shutdown"
        text = ""
      } else if arguments.contains("boot") {
        state = "Booted"
        text = ""
      } else if arguments.contains("bootstatus") || executable == "/bin/ps" {
        text = ""
      } else {
        throw SimulatorError("Unsupported synthetic UI command: \(arguments)")
      }
      return CommandResult(data: Data(text.utf8), errorData: Data(), status: 0)
    }
  }
#endif
