#if DEBUG
  import Foundation

  /// Opt-in synthetic lifecycle for the wallpaper confirmation UI test. Never invokes simctl.
  actor WallpaperModeUITestFixture {
    private var devices: [RawDevice]
    private var states: [String: String] = [:]
    private var disabled: Set<String> = []
    private var loaded: Set<String> = []
    init(data: Data) throws {
      struct Response: Decodable { let devices: [String: [RawDevice]] }
      devices = try JSONDecoder().decode(Response.self, from: data).devices.values.flatMap { $0 }
    }
    func execute(_ args: [String]) throws -> CommandResult {
      var text = ""
      if args.contains("devices") {
        let rows = devices.map { device -> [String: Any] in
          [
            "udid": device.udid, "name": device.name,
            "state": states[device.udid] ?? "Shutdown", "isAvailable": true,
            "dataPath": device.dataPath ?? "",
          ]
        }
        let json = try JSONSerialization.data(withJSONObject: [
          "devices": ["com.apple.CoreSimulator.SimRuntime.iOS-27-2": rows]
        ])
        return .init(data: json, errorData: Data(), status: 0)
      }
      guard let udid = args.first(where: { UUID(uuidString: $0) != nil }),
        devices.contains(where: { $0.udid == udid })
      else { throw SimulatorError("Unsupported synthetic wallpaper command") }
      if args.contains("print-disabled") {
        text =
          "disabled services = {\n"
          + (disabled.contains(udid) ? "\"com.apple.PosterBoard\" => disabled\n" : "") + "}"
      } else if args.contains("list") {
        text =
          "PID Status Label\n1 0 com.apple.SpringBoard\n"
          + (loaded.contains(udid) ? "2 0 com.apple.PosterBoard\n" : "")
      } else if args.contains("disable"), args.last == "system/com.apple.PosterBoard" {
        disabled.insert(udid)
      } else if args.contains("bootout"), args.last == "system/com.apple.PosterBoard" {
        loaded.remove(udid)
      } else if args.contains("boot") {
        states[udid] = "Booted"
        if !disabled.contains(udid) { loaded.insert(udid) }
      } else if args.contains("shutdown") {
        states[udid] = "Shutdown"
        loaded.remove(udid)
      } else if !args.contains("bootstatus") {
        throw SimulatorError("Unsupported synthetic wallpaper command: \(args)")
      }
      return .init(data: Data(text.utf8), errorData: Data(), status: 0)
    }
  }
#endif
