import UIKit
import DiagnosticMenu

@main
@MainActor
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: session.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

@MainActor
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    private let diagnostics = DiagnosticMenu()

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view.backgroundColor = .systemIndigo
        let label = UILabel()
        label.text = "BR Menu Demo\nОтдельное приложение для проверки меню\n\nНажми фон: 0"
        label.numberOfLines = 0
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: controller.view.centerYAnchor),
            label.widthAnchor.constraint(equalTo: controller.view.widthAnchor, constant: -32)
        ])
        let button = UIButton(type: .system)
        button.setTitle("Проверить касания фона", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.accessibilityIdentifier = "demo.backgroundButton"
        button.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            button.bottomAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])
        var taps = 0
        button.addAction(UIAction { _ in
            taps += 1
            label.text = "BR Menu Demo\nОтдельное приложение для проверки меню\n\nНажми фон: \(taps)"
        }, for: .touchUpInside)
        label.accessibilityIdentifier = "demo.backgroundCount"
        window.rootViewController = controller
        self.window = window
        window.makeKeyAndVisible()
        diagnostics.install(in: scene)
    }
    func sceneDidDisconnect(_ scene: UIScene) { diagnostics.uninstall() }
}
