import UIKit

/// Entry is invoked by the native load initializer, on the main queue.
@objc(BRMenuEntry)
@MainActor
public final class BRMenuEntry: NSObject {
    private static let coordinator = BRMenuEntry()
    #if BRMENU_LICENSED
    private var licenseAllowed = false
    private lazy var licenseGate: LicenseGate = {
        let gate = LicenseGate()
        gate.onAccessChange = { [weak self] allowed in
            guard let self else { return }
            self.licenseAllowed = allowed
            if allowed { self.attachActiveScenes() }
            else {
                for menu in self.menus.values { menu.uninstall() }
                self.menus.removeAll(); BRPlayerSnapshot.stopControls()
            }
        }
        return gate
    }()
    @objc private func licenseBackground() { licenseGate.suspend() }
    #endif
    private var started = false
    private var menus: [String: DiagnosticMenu] = [:]

    @objc public static func start() { coordinator.activate() }

    private func activate() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(self, selector: #selector(sceneActive(_:)), name: UIScene.didActivateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sceneDisconnected(_:)), name: UIScene.didDisconnectNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        #if BRMENU_LICENSED
        NotificationCenter.default.addObserver(self, selector: #selector(licenseBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        #endif
        NSLog("[BRMenu] dylib entry started")
        attachActiveScenes()
    }
    @objc private func appActive() { attachActiveScenes() }
    private func attachActiveScenes() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes
        where scene.activationState == .foregroundActive { attach(scene) }
    }
    @objc private func sceneActive(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        attach(scene)
    }
    private func attach(_ scene: UIWindowScene) {
        let key = scene.session.persistentIdentifier
        guard menus[key] == nil else { return }
        guard scene.windows.contains(where: { $0.windowLevel == .normal && !$0.isHidden }) else {
            // UIKit may announce a scene before its main window has been shown.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak scene] in
                guard let self, let scene, scene.activationState == .foregroundActive else { return }
                self.attach(scene)
            }
            return
        }
        #if BRMENU_LICENSED
        guard licenseAllowed else { licenseGate.present(in: scene); return }
        #endif
        let menu = DiagnosticMenu()
        menu.playerProvider = { walls, distance in BRPlayerSnapshot.snapshot(ignoringRenderFlags: walls, maxDistance: distance) }
        menu.shotEventProvider = { BRPlayerSnapshot.ownShotCount() }
        menu.playerStatusProvider = { BRPlayerSnapshot.status() }
        menu.projectionProvider = { BRPlayerSnapshot.projectionMatrix().map { $0.doubleValue } }
        menu.aspectConfigurationProvider = { BRPlayerSnapshot.configureAspect($0) }
        menu.aspectStateProvider = { BRPlayerSnapshot.aspectState() }
        menu.aimFrameProvider = { width, height, stretch in BRPlayerSnapshot.aimFrame(width: width, height: height, stretch: stretch) }
        menu.aimConfigurationProvider = { enabled, radius, miss, head, whitelist in
            BRPlayerSnapshot.configureAim(["enabled": enabled, "radius": radius, "miss": miss, "head": head, "whitelist": whitelist])
        }
        menu.localStateProvider = { BRPlayerSnapshot.localState() }
        menu.controlTickProvider = { BRPlayerSnapshot.tickControls($0) }
        menu.controlStopProvider = { BRPlayerSnapshot.stopControls() }
        menu.controlConfigurationProvider = { values in BRPlayerSnapshot.configureControls(values.mapValues { NSNumber(value: $0) }) }
        menu.gameActionProvider = { action, values in
            BRPlayerSnapshot.perform(action: action, values: values.mapValues { NSNumber(value: $0) })
        }
        menus[key] = menu
        menu.install(in: scene)
        menu.append("Модуль загружен в процесс приложения")
        NSLog("[BRMenu] menu attached")
    }
    @objc private func sceneDisconnected(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene else { return }
        menus.removeValue(forKey: scene.session.persistentIdentifier)?.uninstall()
    }
}
