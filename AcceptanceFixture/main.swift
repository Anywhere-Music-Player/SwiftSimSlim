import UIKit

@MainActor
final class AcceptanceAppDelegate: UIResponder, UIApplicationDelegate {
  var window: UIWindow?
  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
  ) -> Bool {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let sentinel = documents.appendingPathComponent("source-document.txt")
    if !FileManager.default.fileExists(atPath: sentinel.path) {
      try? Data("source-value".utf8).write(to: sentinel)
    }
    let controller = UIViewController()
    controller.view.backgroundColor = .systemBackground
    let label = UILabel()
    label.text = "SwiftSimSlim Acceptance Fixture"
    label.textAlignment = .center
    label.frame = CGRect(x: 10, y: 100, width: 380, height: 100)
    controller.view.addSubview(label)
    let window = UIWindow(frame: UIScreen.main.bounds)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    self.window = window
    return true
  }
}
UIApplicationMain(
  CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AcceptanceAppDelegate.self))
