import UIKit

@MainActor
final class AcceptanceAppDelegate: UIResponder, UIApplicationDelegate {
  func application(
    _ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
    configuration.delegateClass = AcceptanceSceneDelegate.self
    return configuration
  }
}

@MainActor
final class AcceptanceSceneDelegate: UIResponder, UIWindowSceneDelegate {
  var window: UIWindow?
  func scene(
    _ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions
  ) {
    guard let scene = scene as? UIWindowScene else { return }
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
    let window = UIWindow(windowScene: scene)
    window.rootViewController = controller
    window.makeKeyAndVisible()
    self.window = window
    if let index = CommandLine.arguments.firstIndex(of: "--safety-probe"),
      CommandLine.arguments.indices.contains(index + 1)
    {
      try? Data(CommandLine.arguments[index + 1].utf8).write(
        to: documents.appendingPathComponent("launch-probe.txt"), options: .atomic)
    }
  }
}
UIApplicationMain(
  CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(AcceptanceAppDelegate.self))
