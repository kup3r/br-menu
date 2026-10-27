import UIKit
import Darwin
import GLKit
import QuartzCore
import AVFoundation
import UniformTypeIdentifiers

/// Local diagnostics for an app you control. Install on the main actor.
@MainActor
public final class DiagnosticMenu: NSObject, UIGestureRecognizerDelegate, UIDocumentPickerDelegate {
    private weak var scene: UIWindowScene?
    private weak var appWindow: UIWindow?
    private var window: UIWindow?
    private let host = MenuController()
    private let decor = DiagnosticDecor()
    private weak var sampledController: GLKViewController?
    private var sampledCount = 0
    private var sampledTime: CFTimeInterval = 0
    private var gameRate: Double?
    public var playerProvider: ((Bool, Double) -> [[String: Any]])?
    public var playerStatusProvider: (() -> String)?
    public var projectionProvider: (() -> [Double])?
    public var aspectConfigurationProvider: ((Double) -> Void)?
    public var aspectStateProvider: (() -> [String: Any])?
    public var aimFrameProvider: ((Double, Double, Double) -> [String: Any])?
    public var aimConfigurationProvider: ((Bool, Double, Double, Bool, String) -> Void)?
    private var lastAimState: [String: Any] = [:]
    public var localStateProvider: (() -> [String: Any])?
    public var controlTickProvider: ((Double) -> Void)?
    public var controlStopProvider: (() -> Void)?
    public var controlConfigurationProvider: (([String: Double]) -> Void)?
    private var controlTimestamp: CFTimeInterval = 0
    public var gameActionProvider: ((String, [String: Double]) -> String)?
    private let espQueue = DispatchQueue(label: "local.brmenu.esp", qos: .userInitiated)
    private var espBusy = false
    private var espGeneration = 0
    private var espLastRequest: CFTimeInterval = 0
    private var espLastStatus: CFTimeInterval = 0
    public var coordinateProvider: (() -> SIMD3<Double>?)?
    private var lastModelStatus = ""

    private var coordinateText = "Позиция: источник не найден"
    private var gestures: [UITapGestureRecognizer] = []
    public var commandSendProvider: ((String) -> String)?
    public var commandAliasesConfigurationProvider: ((String) -> Void)?
    public var extensionStatusProvider: (() -> String)?
    public var shotEventProvider: (() -> UInt64)?
    private var lastShotEvent: UInt64?
    private let shotAudio = ReactShotAudio()
    private var dragOrigin: CGPoint?
    private var timer: Timer?
    private var link: CADisplayLink?
    private var previousTimestamp: CFTimeInterval = 0
    private var sampleStart: CFTimeInterval = 0
    private var frames = 0
    private var refreshRate: Double = 0
    private var installed = false

    public override init() { super.init() }

    public func install(in scene: UIWindowScene) {
        guard !installed else { return }
        installed = true
        self.scene = scene
        appWindow = scene.windows.first(where: { $0.isKeyWindow })
            ?? scene.windows.first(where: { $0.windowLevel == .normal })
        UIDevice.current.isBatteryMonitoringEnabled = true
        lastShotEvent = shotEventProvider?()
        let overlay = PassthroughWindow(windowScene: scene)
        overlay.windowLevel = .alert + 1
        overlay.backgroundColor = .clear
        let container = UIViewController()
        container.view.backgroundColor = .clear
        overlay.rootViewController = container
        container.addChild(host)
        decor.isUserInteractionEnabled = false
        container.view.addSubview(decor)
        container.view.addSubview(host.view)
        host.didMove(toParent: container)
        overlay.panel = host.view
        window = overlay
        host.onAction = { [weak self] action in self?.perform(action) }
        host.onChange = { [weak self] in self?.configureControls(); self?.decor.rebuildLabels(); self?.updateMetrics(); self?.refreshPlayers() }
        host.onMove = { [weak self] in self?.placeWindow() }
        host.onDrag = { [weak self] delta in
            guard let self else { return }
            let origin = self.dragOrigin ?? self.host.view.frame.origin
            self.dragOrigin = CGPoint(x: origin.x + delta.x, y: origin.y + delta.y)
            self.placeWindow()
        }
        refreshGestureWindows()
        host.loadViewIfNeeded()
        placeWindow()
        overlay.isHidden = false // Does not take keyboard focus from the host app.
        let display = CADisplayLink(target: self, selector: #selector(tick(_:)))
        display.add(to: .main, forMode: .common)
        link = display
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMetrics() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(background), name: UIScene.didEnterBackgroundNotification, object: scene)
        NotificationCenter.default.addObserver(self, selector: #selector(foreground), name: UIScene.didActivateNotification, object: scene)
        append("React Modifications подключено")
        configureControls(); updateMetrics()
    }

    /// Call when disconnecting the scene; releases CADisplayLink's target reference.
    public func uninstall() {
        controlStopProvider?()
        shotAudio.stop(); lastShotEvent = nil
        restoreStretch()
        espGeneration += 1
        timer?.invalidate(); timer = nil
        link?.invalidate(); link = nil
        NotificationCenter.default.removeObserver(self)
        for gesture in gestures { gesture.view?.removeGestureRecognizer(gesture) }
        gestures.removeAll()
        host.willMove(toParent: nil)
        host.view.removeFromSuperview()
        host.removeFromParent()
        window?.isHidden = true; window = nil
        scene = nil; appWindow = nil; installed = false
    }

    /// Supply values only from a verified host-app data source.
    public func setLocalCoordinates(x: Double, y: Double, z: Double) {
        guard x.isFinite, y.isFinite, z.isFinite else { return }
        coordinateText = String(format: "XYZ: %.2f / %.2f / %.2f", x, y, z)
        host.coordinates.text = coordinateText
    }

    public func append(_ message: String) {
        host.messages.append("\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium))  \(message)")
        host.messages = Array(host.messages.suffix(100))
        host.refreshLog()
    }


    /// Rebind after the launcher/game replaces its normal UIWindow.
    private func refreshGestureWindows() {
        guard let scene else { return }
        let candidates = scene.windows.filter { !$0.isHidden && ($0.windowLevel == .normal || $0 === window) }
        gestures.removeAll { recognizer in
            guard let attached = recognizer.view as? UIWindow,
                  candidates.contains(where: { $0 === attached }) else {
                recognizer.view?.removeGestureRecognizer(recognizer); return true
            }
            return false
        }
        if let active = candidates.first(where: { $0.isKeyWindow && $0 !== window })
            ?? candidates.first(where: { $0.windowLevel == .normal }) { appWindow = active }
        for target in candidates where !gestures.contains(where: { $0.view === target }) {
            let gesture = UITapGestureRecognizer(target: self, action: #selector(toggleMenu))
            gesture.numberOfTouchesRequired = 3; gesture.numberOfTapsRequired = 2
            gesture.delegate = self; gesture.cancelsTouchesInView = false
            gesture.delaysTouchesBegan = false; gesture.delaysTouchesEnded = false
            gesture.requiresExclusiveTouchType = false
            target.addGestureRecognizer(gesture); gestures.append(gesture)
        }
    }
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    @objc private func toggleMenu() { perform("collapse") }
    @objc private func background() { shotAudio.stop(); lastShotEvent = nil; restoreStretch(); controlStopProvider?(); controlTimestamp = 0; link?.isPaused = true; append("Приложение в фоне") }
    @objc private func foreground() {
        sampledController = nil; sampledTime = 0; gameRate = nil
        frames = 0; previousTimestamp = 0; sampleStart = 0; refreshRate = 0; controlTimestamp = 0
        configureControls(); link?.isPaused = false; placeWindow(); append("Возврат в приложение")
    }
    @objc private func tick(_ display: CADisplayLink) {
        if scene?.activationState == .foregroundActive, let count = shotEventProvider?() {
            if let previous = lastShotEvent, count > previous, MenuPreferences.shared.flag("customShotSound") {
                shotAudio.play()
            }
            lastShotEvent = count
        }
        if scene?.activationState == .foregroundActive, MenuPreferences.shared.needsPlayers {
            refreshPlayers()
            let matrix = projectionProvider?() ?? []
            decor.camera = matrix.count == 16 ? matrix : nil
            if CACurrentMediaTime() - decor.receivedAt > 0.3 { decor.camera = nil }
            decor.renderESP()
        } else { decor.hideESP() }
        let prefs = MenuPreferences.shared
        if (prefs.flag("silentAim") || prefs.flag("triggerBot")), scene?.activationState == .foregroundActive {
            lastAimState = aimFrameProvider?(Double(decor.bounds.width), Double(decor.bounds.height), Double(decor.horizontalScale)) ?? [:]
            decor.updateAim(lastAimState)
        } else { decor.hideAim(); lastAimState = [:] }
        if controlTimestamp == 0 { controlTimestamp = display.timestamp }
        let controlElapsed = display.timestamp - controlTimestamp
        if controlElapsed >= 0.05 {
            if scene?.activationState == .foregroundActive { controlTickProvider?(controlElapsed) }
            else { controlStopProvider?() }
            controlTimestamp = display.timestamp
        }
        if previousTimestamp == 0 { sampleStart = display.timestamp }
        previousTimestamp = display.timestamp
        frames += 1
        let elapsed = display.timestamp - sampleStart
        if elapsed >= 1 {
            refreshRate = Double(max(0, frames - 1)) / elapsed
            sampleStart = display.timestamp; frames = 1
        }
    }
    private func placeWindow() {
        guard let scene, let window else { return }
        let bounds = scene.coordinateSpace.bounds
        window.frame = bounds
        decor.frame = CGRect(origin: .zero, size: bounds.size)
        appWindow?.layoutIfNeeded()
        let insets = appWindow?.safeAreaInsets ?? .zero
        let topInset = max(insets.top, scene.statusBarManager?.statusBarFrame.height ?? 0)
        let area = CGRect(x: insets.left + 12, y: topInset + 12,
                          width: max(58, bounds.width - insets.left - insets.right - 24),
                          height: max(58, bounds.height - topInset - insets.bottom - 24))
        let width = host.collapsed ? 58.0 : min(MenuPreferences.shared.large ? 420.0 : 350.0, area.width)
        let height = host.collapsed ? 58.0 : min(520.0, area.height)
        let defaultX = host.rightSide ? area.maxX - width : area.minX
        let desired = dragOrigin ?? CGPoint(x: defaultX, y: area.minY)
        let x = min(max(area.minX, desired.x), area.maxX - width)
        let y = min(max(area.minY, desired.y), area.maxY - height)
        host.view.frame = CGRect(x: x, y: y, width: width, height: height)
        host.view.isHidden = host.collapsed && !host.showBubble
        host.view.alpha = MenuPreferences.shared.opacity
        host.view.setNeedsLayout()
    }
    private func updateMetrics() {
        refreshGestureWindows()
        placeWindow()
        sampleGameRate()
        applyStretch()
        host.extensionStatus.text = extensionStatusProvider?() ?? ""
        if MenuPreferences.shared.flag("silentAim") {
            let candidates = (lastAimState["candidates"] as? NSNumber)?.intValue ?? 0
            host.aimStatus.text = "Целей: \(candidates)"
        } else { host.aimStatus.text = "Silent Aim выключен" }
        if let position = coordinateProvider?() { setLocalCoordinates(x: position.x, y: position.y, z: position.z) }
        else if let state = localStateProvider?(), let x = state["x"] as? NSNumber,
                let y = state["y"] as? NSNumber, let z = state["z"] as? NSNumber {
            setLocalCoordinates(x: x.doubleValue, y: y.doubleValue, z: z.doubleValue)
            host.flightStatus.text = (state["flightActive"] as? NSNumber)?.boolValue == true ? "AirBrake включён · удерживай стрелки" : "AirBrake выключен"
            let hp = (state["hp"] as? NSNumber)?.doubleValue ?? -1, armor = (state["armor"] as? NSNumber)?.doubleValue ?? -1
            let stamina = (state["stamina"] as? NSNumber)?.doubleValue ?? -1, maxStamina = (state["maxStamina"] as? NSNumber)?.doubleValue ?? -1
            let car = (state["vehicleHP"] as? NSNumber)?.doubleValue ?? -1
            let modelStatus = state["modelStatus"] as? String ?? ""
            if modelStatus != lastModelStatus {
                if !lastModelStatus.isEmpty { host.actionStatus.text = modelStatus; append(modelStatus) }
                lastModelStatus = modelStatus
            }
            host.carStatus.text = "Модель: \((state["carModel"] as? NSNumber)?.intValue ?? -1)  ·  ID авто: \((state["carID"] as? NSNumber)?.intValue ?? -1)"
            host.weaponStatus.text = "Оружие: \((state["weapon"] as? NSNumber)?.intValue ?? -1)  ·  магазин \((state["clip"] as? NSNumber)?.intValue ?? -1) / \((state["capacity"] as? NSNumber)?.intValue ?? -1)\nЗапас: \((state["ammo"] as? NSNumber)?.intValue ?? -1)"
            host.selfStatus.text = String(format: "Локально: HP %.0f · AP %.0f\nВыносливость: %.0f / %.0f · HP авто: %.0f", hp, armor, stamina, maxStamina, car) + "\nСкин: \((state["skin"] as? NSNumber)?.intValue ?? -1)"
        } else { coordinateText = "Позиция: персонаж не найден"; host.selfStatus.text = "Персонаж не найден" }
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        let memory = result == KERN_SUCCESS ? String(format: "%.1f МиБ", Double(info.resident_size) / 1048576) : "недоступно"
        let battery = UIDevice.current.batteryLevel
        let charge = battery < 0 ? "недоступно" : "\(Int(battery * 100))%"
        let maxHz = scene?.screen.maximumFramesPerSecond ?? 0
        let fps = gameRate.map { String(format: "%.0f FPS GLK", $0) } ?? "FPS GLK: ожидание"
        host.metrics.text = "\(fps)  •  UI \(Int(refreshRate)) Гц\nRAM \(memory)  •  Заряд \(charge)\nНагрев: \(thermalName())  •  Экран \(maxHz) Гц"
        host.coordinates.text = coordinateText
        decor.update(text: "\(fps)   •   \(memory)\n\(coordinateText)", insets: appWindow?.safeAreaInsets ?? .zero)

    }
    private func refreshPlayers() {
        guard MenuPreferences.shared.needsPlayers, scene?.activationState == .foregroundActive else {
            espGeneration += 1
            if !decor.players.isEmpty { decor.players = []; decor.setNeedsDisplay() }
            host.espStatus.text = "ESP выключен"; return
        }
        guard !espBusy, let provider = playerProvider else { return }
        let now = CACurrentMediaTime()
        guard now - espLastRequest + 0.0005 >= 1.0 / MenuPreferences.shared.espRate else { return }
        espLastRequest = now
        espBusy = true
        let generation = espGeneration
        let statusProvider = playerStatusProvider
        let walls = MenuPreferences.shared.flag("espWalls", fallback: true) || MenuPreferences.shared.flag("silentAim")
        let maxDistance = MenuPreferences.shared.maxDistance
        espQueue.async { [weak self] in
            let started = CACurrentMediaTime()
            let players = provider(walls, maxDistance)
            let status = statusProvider?() ?? "Источник ESP не подключён"
            let elapsed = (CACurrentMediaTime() - started) * 1000
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.espBusy = false
                guard self.installed, generation == self.espGeneration,
                      MenuPreferences.shared.needsPlayers, self.scene?.activationState == .foregroundActive else { return }
                self.decor.players = players
                self.decor.receivedAt = started
                if self.espLastStatus == 0 || self.decor.receivedAt - self.espLastStatus >= 0.5 {
                    self.host.espStatus.text = status + String(format: " · сбор %.1f мс", elapsed)
                    self.espLastStatus = self.decor.receivedAt
                }
                self.decor.setNeedsDisplay()
            }
        }
    }
    private func sampleGameRate() {
        var seen = Set<ObjectIdentifier>()
        func find(_ controller: UIViewController?) -> GLKViewController? {
            guard let controller, seen.insert(ObjectIdentifier(controller)).inserted else { return nil }
            if let presented = find(controller.presentedViewController) { return presented }
            for child in controller.children.reversed() { if let match = find(child) { return match } }
            if let glk = controller as? GLKViewController, glk.isViewLoaded,
               glk.view.window != nil, !glk.view.isHidden { return glk }
            return nil
        }
        guard let controller = find(appWindow?.rootViewController) else {
            sampledController = nil; sampledTime = 0; gameRate = nil; return
        }
        let now = CACurrentMediaTime(), count = controller.framesDisplayed
        if sampledController === controller, sampledTime > 0, now - sampledTime < 0.5 { return }
        if sampledController === controller, sampledTime > 0, count >= sampledCount {
            gameRate = Double(count - sampledCount) / max(0.001, now - sampledTime)
        } else { gameRate = nil }
        sampledController = controller; sampledCount = count; sampledTime = now
    }
    private func restoreStretch() {
        aspectConfigurationProvider?(1); decor.horizontalScale = 1
    }
    private func applyStretch() {
        decor.horizontalScale = 1 // Projection comes from the engine camera; HUD/window are never scaled.
        let factor = MenuPreferences.shared.stretch
        guard scene?.activationState == .foregroundActive else { restoreStretch(); return }
        aspectConfigurationProvider?(factor)
        let state = aspectStateProvider?() ?? [:]
        if factor <= 1.001 { host.stretchStatus.text = "Обычная 3D-проекция" }
        else if (state["ready"] as? NSNumber)?.boolValue != true { host.stretchStatus.text = "Настройка изображения недоступна" }
        else if (state["observed"] as? NSNumber)?.boolValue != true { host.stretchStatus.text = "Ожидание первого кадра 3D-проекции" }
        else { host.stretchStatus.text = String(format: "3D-проекция: ×%.2f · игровой интерфейс в границах экрана", factor) }
    }
    private func thermalName() -> String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return "норма"
        case .fair: return "тёплый"
        case .serious: return "горячий"
        case .critical: return "критическое"
        @unknown default: return "неизвестно"
        }
    }
    private func perform(_ action: String) {
        switch action {
        case "collapse":
            _ = gameActionProvider?("flightRelease", [:])
            let changes = { self.host.collapsed.toggle(); self.host.applyCollapse(); self.placeWindow(); self.configureControls() }
            if MenuPreferences.shared.animations && !UIAccessibility.isReduceMotionEnabled {
                UIView.transition(with: host.view, duration: 0.22, options: [.transitionCrossDissolve, .allowUserInteraction], animations: changes)
            } else { changes() }
        case "side":
            host.rightSide.toggle(); dragOrigin = nil
            if MenuPreferences.shared.animations && !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) { self.placeWindow() }
            } else { placeWindow() }
        case "bubble": host.showBubble.toggle(); MenuPreferences.shared.set("bubble", host.showBubble); placeWindow()
        case "copy":
            UIPasteboard.general.string = [host.metrics.text, host.coordinates.text, host.log.text].compactMap { $0 }.joined(separator: "\n")
            append("Диагностика скопирована")
        case "flightToggle": runGame("flightToggle", [:])
        case "flightRelease": _ = gameActionProvider?("flightRelease", [:])
        case "flightForward", "flightBack", "flightLeft", "flightRight", "flightUp", "flightDown":
            let directions: [String: [Double]] = ["flightForward": [0,1,0], "flightBack": [0,-1,0], "flightLeft": [-1,0,0], "flightRight": [1,0,0], "flightUp": [0,0,1], "flightDown": [0,0,-1]]
            if let d = directions[action] { _ = gameActionProvider?("flightInput", ["x": d[0], "y": d[1], "z": d[2], "speed": MenuPreferences.shared.flightSpeed]) }
        case "savePoint":
            guard let s = localStateProvider?(), let x = s["x"] as? NSNumber,
                  let y = s["y"] as? NSNumber, let z = s["z"] as? NSNumber else {
                append("Персонаж не найден"); return
            }
            MenuPreferences.shared.savedPoint = [x.doubleValue, y.doubleValue, z.doubleValue]
            host.actionStatus.text = "Точка сохранена"; append("Точка сохранена")
        case "returnPoint":
            guard let point = MenuPreferences.shared.savedPoint else { append("Сначала сохрани точку"); return }
            runGame("teleport", ["x": point[0], "y": point[1], "z": point[2]])
        case "aimWhitelist": requestAimWhitelist()
        case "aimExcludeTarget":
            guard let id = (lastAimState["target"] as? NSNumber)?.intValue, id >= 0 else { append("Сначала выбери цель в FOV"); return }
            let prefs = MenuPreferences.shared
            prefs.aimWhitelist = prefs.aimWhitelist.isEmpty ? String(id) : prefs.aimWhitelist + ", " + String(id)
            configureControls(); decor.hideAim(); append("ID \(id) добавлен в исключения")
        case "aimClearWhitelist": MenuPreferences.shared.aimWhitelist = ""; configureControls(); append("Исключения очищены")
        case "waypoint", "waypointCancel": runGame(action, [:])
        case "stretchReset": MenuPreferences.shared.stretch = 1; host.resetStretch(); restoreStretch()
        case "teleportXYZ": requestCoordinates()
        case "teleportPlayer": requestPlayer()
        case "teleportVehicle": requestVehicle()
        case "skinSet", "carSet", "weaponGive": requestAppearance(action)
        case "skinRestore", "carRestore", "modelCancel": runGame(action, [:])
        case "nearestVehicle": runGame("nearestVehicle", [:])
        case "ammoRefill", "magazineFill", "repairVehicle", "gravityReset", "unlockVehicle", "startEngine", "respawn": runGame(action, [:])
        case "gravityPed", "gravityVehicle": runGame(action, ["factor": MenuPreferences.shared.gravityFactor])
        case "resetControls":
            MenuPreferences.shared.stretch = 1; host.resetStretch(); restoreStretch()
            MenuPreferences.shared.set("silentAim", false); decor.hideAim()
            for key in MenuPreferences.controlKeys { MenuPreferences.shared.set(key, false) }
            controlStopProvider?(); host.syncControlToggles(); configureControls()
            host.actionStatus.text = "Игровые переключатели выключены"; append("Игровые переключатели выключены")
        case "hop": runGame("hop", ["power": MenuPreferences.shared.hopPower])
        case "suicide":
            for key in ["autoHealth", "localProof", "noFall", "noAnim", "fastAnim"] { MenuPreferences.shared.set(key, false) }
            host.syncControlToggles(); configureControls(); runGame(action, [:])
        case "heal", "armor", "healVehicle": runGame(action, [:])
        case "dash": runGame("dash", ["power": MenuPreferences.shared.hopPower])
        case "stopVehicle": runGame("stopVehicle", [:])
        case "boostVehicle": runGame("boostVehicle", ["factor": MenuPreferences.shared.boostPower])
        case "flipVehicle": runGame("flipVehicle", [:])
        case "massPed", "massVehicle": runGame(action, ["factor": MenuPreferences.shared.massFactor])
        case "massReset": runGame("massReset", [:])
        case "aspectOriginal": MenuPreferences.shared.stretch = 1; host.setStretch(1); configureControls(); updateMetrics()
        case "aspectTablet": MenuPreferences.shared.stretch = 1.5; host.setStretch(1.5); configureControls(); updateMetrics()
        case "aspectWide": MenuPreferences.shared.stretch = 1.6; host.setStretch(1.6); configureControls(); updateMetrics()
        case "shotPreview": shotAudio.play()
        case "shotImport": importShotSound()
        case "shotReset": shotAudio.reset(); host.actionStatus.text = "Выбран мягкий щелчок"
        case "commandCompose": composeCommand()
        case "commandAliases": editCommandAliases()
        case "clear": host.messages.removeAll(); host.refreshLog()
        default: break
        }
    }
    private func configureControls() {
        var values = Dictionary(uniqueKeysWithValues: MenuPreferences.controlKeys.map { ($0, MenuPreferences.shared.flag($0) ? 1.0 : 0.0) })
        values["triggerBot"] = MenuPreferences.shared.flag("triggerBot") && host.collapsed ? 1 : 0
        values["triggerAimOnly"] = MenuPreferences.shared.flag("triggerAimOnly", fallback: true) ? 1 : 0
        values["triggerRadius"] = MenuPreferences.shared.triggerRadius
        values["triggerDelay"] = MenuPreferences.shared.triggerDelay
        values["lagInterval"] = MenuPreferences.shared.lagInterval
        values["fireRate"] = MenuPreferences.shared.fireRate
        values["animationRate"] = MenuPreferences.shared.animationRate
        values["runMultiplier"] = MenuPreferences.shared.runMultiplier
        values["cameraFOV"] = MenuPreferences.shared.cameraFOV
        values["worldHour"] = MenuPreferences.shared.worldHour
        values["worldMinute"] = MenuPreferences.shared.worldMinute
        values["worldWeather"] = MenuPreferences.shared.worldWeather
        commandAliasesConfigurationProvider?(MenuPreferences.shared.commandAliases)
        controlConfigurationProvider?(values)
        aspectConfigurationProvider?(MenuPreferences.shared.stretch)
        let prefs = MenuPreferences.shared
        aimConfigurationProvider?(prefs.flag("silentAim"), prefs.fovRadius, prefs.aimMiss, prefs.flag("aimHead"), prefs.aimWhitelist)
    }
    private func runGame(_ action: String, _ values: [String: Double]) {
        let result = gameActionProvider?(action, values) ?? "Источник управления не подключён"
        host.actionStatus.text = result
        append(result)
        updateMetrics()
    }

    private func importShotSound() {
        guard host.presentedViewController == nil else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.audio], asCopy: true)
        picker.delegate = self; picker.allowsMultipleSelection = false
        window?.makeKey(); host.present(picker, animated: true)
    }
    public func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        defer { appWindow?.makeKey() }
        guard let url = urls.first else { return }
        do { try shotAudio.importFile(url); host.actionStatus.text = "Звук выстрела сохранён" }
        catch { host.actionStatus.text = "Нужен аудиофайл до 1 МиБ и длительностью до 2 секунд" }
    }
    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { appWindow?.makeKey() }
    private func composeCommand() {
        guard host.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Быстрая команда", message: commandSendProvider == nil ? "Команда будет скопирована" : "Введи /cf и аргументы. Команда отправится в игру", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "/cf 17"; $0.autocorrectionType = .no; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { [weak self] _ in self?.appWindow?.makeKey() })
        alert.addAction(UIAlertAction(title: commandSendProvider == nil ? "Скопировать" : "Отправить", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }; self.appWindow?.makeKey()
            let command = ReactCommandAliases.expand(alert?.textFields?.first?.text ?? "", rules: MenuPreferences.shared.commandAliases)
            guard !command.isEmpty else { return }
            if let send = self.commandSendProvider { self.host.actionStatus.text = send(command) }
            else { UIPasteboard.general.string = command; self.host.actionStatus.text = "Скопировано: " + command }
        })
        window?.makeKey(); host.present(alert, animated: true)
    }
    private func editCommandAliases() {
        guard host.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Сокращения команд", message: "Формат: /cf=/cuff; /короткая=/полная. Включи «Сокращения в чате» для автоматической замены.", preferredStyle: .alert)
        alert.addTextField { $0.text = MenuPreferences.shared.commandAliases; $0.autocorrectionType = .no; $0.autocapitalizationType = .none }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { [weak self] _ in self?.appWindow?.makeKey() })
        alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { [weak self, weak alert] _ in
            self?.appWindow?.makeKey()
            MenuPreferences.shared.commandAliases = String((alert?.textFields?.first?.text ?? "").prefix(2048))
            self?.configureControls()
        })
        window?.makeKey(); host.present(alert, animated: true)
    }
    private func requestAimWhitelist() {
        guard host.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Исключения Silent Aim", message: "ID или точные ники через запятую. Например: 17, 202, Ivan_Ivanov. Ники сравниваются без учёта регистра.", preferredStyle: .alert)
        alert.addTextField { field in
            field.text = MenuPreferences.shared.aimWhitelist; field.autocorrectionType = .no; field.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { [weak self] _ in self?.appWindow?.makeKey() })
        alert.addAction(UIAlertAction(title: "Сохранить", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }; self.appWindow?.makeKey()
            MenuPreferences.shared.aimWhitelist = String((alert?.textFields?.first?.text ?? "").prefix(4096))
            self.configureControls(); self.decor.hideAim(); self.append("Исключения сохранены")
        })
        window?.makeKey(); host.present(alert, animated: MenuPreferences.shared.animations)
    }
    private func requestCoordinates() {
        guard host.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Телепорт по XYZ", message: "Находясь пешком. Сервер может вернуть прежнюю позицию.", preferredStyle: .alert)
        let state = localStateProvider?() ?? [:]
        for key in ["x", "y", "z"] {
            alert.addTextField { field in
                field.placeholder = key.uppercased(); field.keyboardType = .numbersAndPunctuation
                if let value = state[key] as? NSNumber { field.text = String(format: "%.2f", value.doubleValue) }
            }
        }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { [weak self] _ in self?.appWindow?.makeKey() })
        alert.addAction(UIAlertAction(title: "Переместиться", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }; self.appWindow?.makeKey()
            let inputs = (alert?.textFields ?? []).compactMap { Double(($0.text ?? "").replacingOccurrences(of: ",", with: ".")) }
            guard inputs.count == 3, inputs.allSatisfy({ $0.isFinite }) else { self.append("Введи три конечных числа"); return }
            self.runGame("teleport", ["x": inputs[0], "y": inputs[1], "z": inputs[2]])
        })
        window?.makeKey(); host.present(alert, animated: MenuPreferences.shared.animations)
    }
    private func requestAppearance(_ action: String) {
        guard host.presentedViewController == nil else { return }
        let state = localStateProvider?() ?? [:]
        let weapon = action == "weaponGive", car = action == "carSet"
        let title = weapon ? "Выдать оружие" : (car ? "Подмена машины" : "Скин по ID")
        let message = weapon ? "Локальная выдача огнестрельного оружия в активный слот. Сервер может отклонять владение или урон." : (car ? "Сядь за руль обычной машины без пассажиров. Меняется модель; прежний handling сохраняется." : "Локальный скин из каталога этой сборки. Модель загрузится автоматически.")
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = weapon ? "ID оружия: 1–254" : "ID модели"
            field.keyboardType = .numberPad
            let key = weapon ? "weapon" : (car ? "carModel" : "skin")
            if let value = state[key] as? NSNumber, value.intValue >= 0 { field.text = value.stringValue }
        }
        if weapon { alert.addTextField { $0.placeholder = "Патроны: 1–99999"; $0.text = "300"; $0.keyboardType = .numberPad } }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { [weak self] _ in self?.appWindow?.makeKey() })
        alert.addAction(UIAlertAction(title: "Применить", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }; self.appWindow?.makeKey()
            guard let fields = alert?.textFields, let text = fields.first?.text, let id = Int(text), (0...1000000).contains(id) else {
                self.host.actionStatus.text = "Некорректный ID"; return
            }
            var values = ["id": Double(id)]
            if weapon {
                guard fields.count == 2, let ammo = Int(fields[1].text ?? ""), (1...99999).contains(ammo), (1...254).contains(id) else {
                    self.host.actionStatus.text = "Проверь ID оружия и число патронов"; return
                }
                values["ammo"] = Double(ammo)
            }
            self.runGame(action, values)
        })
        window?.makeKey(); host.present(alert, animated: MenuPreferences.shared.animations)
    }
    private func requestVehicle() {
        guard host.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "К транспорту по ID", message: "ID 0–1999. Транспорт должен быть загружен в клиенте; персонаж — пешком.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "ID транспорта"; $0.keyboardType = .numberPad }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { [weak self] _ in self?.appWindow?.makeKey() })
        alert.addAction(UIAlertAction(title: "Переместиться", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }; self.appWindow?.makeKey()
            guard let text = alert?.textFields?.first?.text, let id = Int(text), (0..<2000).contains(id) else { self.append("Некорректный ID"); return }
            self.runGame("vehicleTarget", ["id": Double(id)])
        })
        window?.makeKey(); host.present(alert, animated: MenuPreferences.shared.animations)
    }
    private func requestPlayer() {
        guard host.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "К загруженному игроку", message: "ID из ESP, от 0 до 1503. Телепорт доступен пешком.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "ID игрока"; $0.keyboardType = .numberPad }
        alert.addAction(UIAlertAction(title: "Отмена", style: .cancel) { [weak self] _ in self?.appWindow?.makeKey() })
        alert.addAction(UIAlertAction(title: "Переместиться", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }; self.appWindow?.makeKey()
            guard let text = alert?.textFields?.first?.text, let id = Int(text), (0..<1504).contains(id) else { self.append("Некорректный ID"); return }
            self.runGame("player", ["id": Double(id)])
        })
        window?.makeKey(); host.present(alert, animated: MenuPreferences.shared.animations)
    }

}

@MainActor
private final class MenuPreferences {
    static let shared = MenuPreferences()
    static let controlKeys = ["autoHealth", "autoArmor", "stamina", "autoVehicleHealth", "slowFall", "noClip", "localProof", "noFall", "vehicleProof", "infiniteAmmo", "noReload", "rapidFire", "noCollision", "noSpread", "noAnim", "fastAnim", "cameraFOVOverride", "worldTimeOverride", "worldWeatherOverride", "aliasesAuto", "runSpeed", "fakeLag", "antiFreeze", "triggerBot"]
    private let defaults = UserDefaults(suiteName: "local.brmenu.settings.v6") ?? .standard
    func flag(_ key: String, fallback: Bool = false) -> Bool { defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key) }
    func set(_ key: String, _ value: Bool) { defaults.set(value, forKey: key) }
    var lagInterval: Double {
        get { defaults.object(forKey: "lagInterval") == nil ? 200 : max(50, min(500, defaults.double(forKey: "lagInterval"))) }
        set { defaults.set(newValue, forKey: "lagInterval") }
    }
    var triggerRadius: Double {
        get { defaults.object(forKey: "triggerRadius") == nil ? 10 : max(2, min(30, defaults.double(forKey: "triggerRadius"))) }
        set { defaults.set(newValue, forKey: "triggerRadius") }
    }
    var triggerDelay: Double {
        get { defaults.object(forKey: "triggerDelay") == nil ? 120 : max(0, min(500, defaults.double(forKey: "triggerDelay"))) }
        set { defaults.set(newValue, forKey: "triggerDelay") }
    }
    var runMultiplier: Double {
        get { defaults.object(forKey: "runMultiplier") == nil ? 1.5 : max(1, min(3, defaults.double(forKey: "runMultiplier"))) }
        set { defaults.set(newValue, forKey: "runMultiplier") }
    }
    var cameraFOV: Double {
        get { defaults.object(forKey: "cameraFOV") == nil ? 70 : max(50, min(120, defaults.double(forKey: "cameraFOV"))) }
        set { defaults.set(newValue, forKey: "cameraFOV") }
    }
    var worldHour: Double {
        get { max(0, min(23, defaults.double(forKey: "worldHour"))) }
        set { defaults.set(newValue.rounded(), forKey: "worldHour") }
    }
    var worldMinute: Double {
        get { max(0, min(59, defaults.double(forKey: "worldMinute"))) }
        set { defaults.set(newValue.rounded(), forKey: "worldMinute") }
    }
    var worldWeather: Double {
        get { max(0, min(21, defaults.double(forKey: "worldWeather"))) }
        set { defaults.set(newValue.rounded(), forKey: "worldWeather") }
    }
    var commandAliases: String {
        get { defaults.string(forKey: "commandAliases") ?? "/cf=/cuff" }
        set { defaults.set(newValue, forKey: "commandAliases") }
    }
    var opacity: CGFloat {
        get { defaults.object(forKey: "opacity") == nil ? 0.96 : max(0.45, min(1, CGFloat(defaults.double(forKey: "opacity")))) }
        set { defaults.set(Double(newValue), forKey: "opacity") }
    }
    var maxDistance: Double {
        get { defaults.object(forKey: "espDistance") == nil ? 150 : max(25, min(500, defaults.double(forKey: "espDistance"))) }
        set { defaults.set(newValue, forKey: "espDistance") }
    }
    var animationRate: Double {
        get { defaults.object(forKey: "animationRate") == nil ? 2 : max(1, min(4, defaults.double(forKey: "animationRate"))) }
        set { defaults.set(newValue, forKey: "animationRate") }
    }
    var fireRate: Double {
        get { defaults.object(forKey: "fireRate") == nil ? 2 : max(1, min(5, defaults.double(forKey: "fireRate"))) }
        set { defaults.set(newValue, forKey: "fireRate") }
    }
    var gravityFactor: Double {
        get { defaults.object(forKey: "gravityFactor") == nil ? 1 : max(-2, min(3, defaults.double(forKey: "gravityFactor"))) }
        set { defaults.set(newValue, forKey: "gravityFactor") }
    }
    var espRate: Double {
        get { defaults.object(forKey: "espRate") == nil ? 20 : max(10, min(30, defaults.double(forKey: "espRate"))) }
        set { defaults.set(newValue, forKey: "espRate") }
    }
    var massFactor: Double {
        get { defaults.object(forKey: "massFactor") == nil ? 1 : max(0.1, min(5, defaults.double(forKey: "massFactor"))) }
        set { defaults.set(newValue, forKey: "massFactor") }
    }
    var boostPower: Double {
        get { defaults.object(forKey: "boostPower") == nil ? 1.5 : max(1, min(3, defaults.double(forKey: "boostPower"))) }
        set { defaults.set(newValue, forKey: "boostPower") }
    }
    var flightSpeed: Double {
        get { defaults.object(forKey: "flightSpeed") == nil ? 5 : max(1, min(30, defaults.double(forKey: "flightSpeed"))) }
        set { defaults.set(newValue, forKey: "flightSpeed") }
    }
    var savedPoint: [Double]? {
        get { guard let p = defaults.array(forKey: "savedPoint") as? [Double], p.count == 3, p.allSatisfy({ $0.isFinite }) else { return nil }; return p }
        set { defaults.set(newValue, forKey: "savedPoint") }
    }
    var hopPower: Double {
        get { defaults.object(forKey: "hopPower") == nil ? 1 : max(1, min(5, defaults.double(forKey: "hopPower"))) }
        set { defaults.set(newValue, forKey: "hopPower") }
    }
    var needsPlayers: Bool { flag("esp") || flag("silentAim") || flag("triggerBot") }
    var aimMiss: Double {
        get { max(0, min(100, defaults.double(forKey: "aimMiss"))) }
        set { defaults.set(newValue, forKey: "aimMiss") }
    }
    var aimWhitelist: String {
        get { defaults.string(forKey: "aimWhitelist") ?? "" }
        set { defaults.set(newValue, forKey: "aimWhitelist") }
    }
    var stretch: Double {
        get { defaults.object(forKey: "stretch") == nil ? 1 : max(1, min(1.6, defaults.double(forKey: "stretch"))) }
        set { defaults.set(newValue, forKey: "stretch") }
    }
    var fovRadius: Double {
        get { defaults.object(forKey: "fovRadius") == nil ? 100 : max(30, min(300, defaults.double(forKey: "fovRadius"))) }
        set { defaults.set(newValue, forKey: "fovRadius") }
    }
    var animations: Bool { flag("animations", fallback: true) }
    var large: Bool { flag("large") }
    var accent: UIColor { defaults.integer(forKey: "accent") == 1 ? .systemOrange : .systemCyan }
    var accentIndex: Int { get { defaults.integer(forKey: "accent") } set { defaults.set(newValue, forKey: "accent") } }
}

@MainActor
private final class DiagnosticDecor: UIView {
    private let hud = UILabel()
    private let aimCircle = CAShapeLayer(), aimCircleOutline = CAShapeLayer()
    private let shootLabel = CATextLayer()
    func hideAim() {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        aimCircle.path = nil; aimCircleOutline.path = nil; shootLabel.isHidden = true
        CATransaction.commit()
    }
    func updateAim(_ state: [String: Any]) {
        let prefs = MenuPreferences.shared
        guard prefs.flag("silentAim") else { hideAim(); return }
        let armed = (state["ready"] as? NSNumber)?.boolValue == true
        let id = (state["target"] as? NSNumber)?.intValue ?? -1
        CATransaction.begin(); CATransaction.setDisableActions(true)
        aimCircle.strokeColor = (armed ? UIColor.systemGreen : UIColor.systemOrange).cgColor
        aimCircle.lineDashPattern = armed ? nil : [6, 4]
        if prefs.flag("aimFOV", fallback: true), !armed || !prefs.flag("aimFOVOnlyTarget", fallback: false) || id >= 0 {
            let r = CGFloat(prefs.fovRadius)
            let rect = CGRect(x: bounds.midX-r, y: bounds.midY-r, width: r*2, height: r*2)
            let circle = UIBezierPath(ovalIn: rect).cgPath; aimCircle.path = circle; aimCircleOutline.path = circle
        } else { aimCircle.path = nil; aimCircleOutline.path = nil }
        shootLabel.isHidden = id < 0 || !prefs.flag("aimShoot", fallback: true)
        if !shootLabel.isHidden {
            let text = armed ? "Shoot [\(id)]" : "Цель [\(id)]"
            if (shootLabel.string as? NSAttributedString)?.string != text {
                shootLabel.string = NSAttributedString(string: text, attributes: [.font: UIFont.monospacedSystemFont(ofSize: 12, weight: .bold), .foregroundColor: armed ? UIColor.green : UIColor.systemOrange, .strokeColor: UIColor.black, .strokeWidth: -2])
            }
            let x = CGFloat((state["x"] as? NSNumber)?.doubleValue ?? 0.5)*bounds.width
            let y = CGFloat((state["y"] as? NSNumber)?.doubleValue ?? 0.5)*bounds.height
            shootLabel.frame = CGRect(x: max(4, min(bounds.width-124, x-60)), y: max(4, y-22), width: 120, height: 20)
        }
        CATransaction.commit()
    }
    struct Actor {
        var lo: SIMD3<Double>, hi: SIMD3<Double>, hp: Double, distance: Double
        var name: String, id: Int, armor: Double
        var label = NSAttributedString(string: "")
        var labelWidth: CGFloat = 0
    }
    var camera: [Double]?
    var horizontalScale: CGFloat = 1
    var receivedAt: CFTimeInterval = 0
    private var actors: [Actor] = []
    private let espOutline = CAShapeLayer(), espLines = CAShapeLayer()
    private let hpBackground = CAShapeLayer(), hpGood = CAShapeLayer(), hpLow = CAShapeLayer()
    private var labelLayers: [Int: CATextLayer] = [:]
    var players: [[String: Any]] = [] {
        didSet {
            actors = players.compactMap { player in
                guard let b = player["bounds"] as? [NSNumber], b.count == 6 else { return nil }
                let v = b.map { $0.doubleValue }; guard v.allSatisfy({ $0.isFinite }) else { return nil }
                return Actor(lo: SIMD3(v[0],v[1],v[2]), hi: SIMD3(v[3],v[4],v[5]),
                    hp: (player["hp"] as? NSNumber)?.doubleValue ?? 0,
                    distance: (player["distance"] as? NSNumber)?.doubleValue ?? -1,
                    name: player["name"] as? String ?? "Player", id: (player["id"] as? NSNumber)?.intValue ?? -1,
                    armor: (player["armor"] as? NSNumber)?.doubleValue ?? 0)
            }
            rebuildLabels()
        }
    }
    func rebuildLabels() {
        let prefs = MenuPreferences.shared
        let showName = prefs.flag("espName", fallback: true), showHP = prefs.flag("espHP", fallback: true)
        let showArmor = prefs.flag("espArmor"), showDistance = prefs.flag("espDistance")
        let font = UIFont.monospacedSystemFont(ofSize: 10, weight: .semibold)
        let shadow = NSShadow(); shadow.shadowColor = UIColor.black; shadow.shadowBlurRadius = 0; shadow.shadowOffset = CGSize(width: 1, height: 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.white, .shadow: shadow]
        for index in actors.indices {
            let actor = actors[index]; var lines: [String] = []
            if showName { lines.append("\(actor.name) [\(actor.id)]") }
            if showHP { lines.append("HP \(Int(actor.hp))") }
            if showArmor { lines.append("AP \(Int(actor.armor))") }
            if showDistance && actor.distance >= 0 { lines.append(String(format: "%.0f м от камеры", actor.distance)) }
            let text = lines.joined(separator: " · ")
            actors[index].label = NSAttributedString(string: text, attributes: attributes)
            actors[index].labelWidth = min(220, actors[index].label.size().width)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        espLines.strokeColor = prefs.accent.cgColor
        let currentIDs = Set(actors.map { $0.id })
        for id in Array(labelLayers.keys) where !currentIDs.contains(id) {
            labelLayers.removeValue(forKey: id)?.removeFromSuperlayer()
        }
        for actor in actors {
            let text: CATextLayer
            if let existing = labelLayers[actor.id] { text = existing }
            else {
                text = CATextLayer(); text.isWrapped = true; text.truncationMode = .end
                text.alignmentMode = .center; text.contentsScale = max(1, contentScaleFactor)
                text.isHidden = true; labelLayers[actor.id] = text; layer.addSublayer(text)
            }
            if (text.string as? NSAttributedString)?.string != actor.label.string { text.string = actor.label }
        }
        CATransaction.commit()
        renderESP()
        setNeedsDisplay()
    }
    func hideESP() {
        guard espLines.path != nil || espOutline.path != nil || labelLayers.values.contains(where: { !$0.isHidden }) else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for shape in [espOutline, espLines, hpBackground, hpGood, hpLow] { shape.path = nil }
        for label in labelLayers.values { label.isHidden = true }
        CATransaction.commit()
    }
    func renderESP() {
        let prefs = MenuPreferences.shared
        guard prefs.flag("esp"), let camera, camera.count == 16 else { hideESP(); return }
        let showBox = prefs.flag("espBox", fallback: true), showHP = prefs.flag("espHP", fallback: true)
        let maxDistance = prefs.maxDistance
        let boxes = CGMutablePath(), backgrounds = CGMutablePath(), green = CGMutablePath(), red = CGMutablePath()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for label in labelLayers.values { label.isHidden = true }
        for actor in actors {
            if actor.distance >= 0 && actor.distance > maxDistance { continue }
            guard let box = screenBox(actor, camera: camera), box.width > 1, box.height > 2 else { continue }
            if showBox { boxes.addRect(box) }
            if showHP {
                let bar = CGRect(x: box.minX-6, y: box.minY, width: 3, height: box.height)
                backgrounds.addRect(bar)
                let ratio = CGFloat(min(1, max(0, actor.hp / 100)))
                let fill = CGRect(x: bar.minX, y: bar.maxY-bar.height*ratio, width: 3, height: bar.height*ratio)
                if actor.hp > 30 { green.addRect(fill) } else { red.addRect(fill) }
            }
            if actor.label.length > 0, let label = labelLayers[actor.id] {
                let width = actor.labelWidth, x = max(4, min(bounds.width-width-4, box.midX-width/2))
                label.frame = CGRect(x: x, y: max(4, box.minY-28), width: width, height: 26)
                label.isHidden = false
            }
        }
        espOutline.path = boxes; espLines.path = boxes
        hpBackground.path = backgrounds; hpGood.path = green; hpLow.path = red
        CATransaction.commit()
    }
    private func screenBox(_ actor: Actor, camera m: [Double]) -> CGRect? {
        var x0 = Double.infinity, y0 = Double.infinity, x1 = -Double.infinity, y1 = -Double.infinity
        var valid = 0
        for corner in 0..<8 {
            let x = (corner & 1) == 0 ? actor.lo.x : actor.hi.x
            let y = (corner & 2) == 0 ? actor.lo.y : actor.hi.y
            let z = (corner & 4) == 0 ? actor.lo.z : actor.hi.z
            let depth = m[2]*x + m[6]*y + m[10]*z + m[14]
            guard depth.isFinite, depth > 0.05 else { continue }
            let px = (m[0]*x + m[4]*y + m[8]*z + m[12]) / depth
            let py = (m[1]*x + m[5]*y + m[9]*z + m[13]) / depth
            guard px.isFinite, py.isFinite else { continue }
            x0 = min(x0,px); x1 = max(x1,px); y0 = min(y0,py); y1 = max(y1,py); valid += 1
        }
        guard valid == 8, x1 > x0, y1 > y0, x1 >= 0, x0 <= 1, y1 >= 0, y0 <= 1,
              x1-x0 < 2, y1-y0 < 2 else { return nil }
        let left = bounds.midX + (CGFloat(x0)*bounds.width - bounds.midX)*horizontalScale
        return CGRect(x: left, y: CGFloat(y0)*bounds.height,
                      width: CGFloat(x1-x0)*bounds.width*horizontalScale, height: CGFloat(y1-y0)*bounds.height)
    }
    private var safe = UIEdgeInsets.zero
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false; backgroundColor = .clear
        hud.numberOfLines = 2; hud.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        hud.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        hud.layer.cornerRadius = 10; hud.clipsToBounds = true
        for shape in [espOutline, espLines, hpBackground, hpGood, hpLow] { layer.addSublayer(shape) }
        espOutline.fillColor = nil; espOutline.strokeColor = UIColor.black.withAlphaComponent(0.8).cgColor; espOutline.lineWidth = 3
        espLines.fillColor = nil; espLines.strokeColor = MenuPreferences.shared.accent.cgColor; espLines.lineWidth = 1
        hpBackground.fillColor = UIColor.black.withAlphaComponent(0.8).cgColor
        hpGood.fillColor = UIColor.systemGreen.cgColor; hpLow.fillColor = UIColor.systemRed.cgColor
        for shape in [aimCircleOutline, aimCircle] { shape.fillColor = nil; layer.addSublayer(shape) }
        aimCircleOutline.strokeColor = UIColor.black.withAlphaComponent(0.8).cgColor; aimCircleOutline.lineWidth = 3
        aimCircle.strokeColor = UIColor.systemGreen.cgColor; aimCircle.lineWidth = 1
        shootLabel.alignmentMode = .center; shootLabel.contentsScale = max(1, contentScaleFactor); shootLabel.isHidden = true
        layer.addSublayer(shootLabel)
        hud.accessibilityIdentifier = "diagnostics.hud"
        addSubview(hud)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func update(text: String, insets: UIEdgeInsets) {
        safe = insets; hud.text = "  " + text.replacingOccurrences(of: "\n", with: "\n  ")
        hud.textColor = MenuPreferences.shared.accent
        hud.isHidden = !MenuPreferences.shared.flag("hud", fallback: true)
        setNeedsLayout(); setNeedsDisplay()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for shape in [espOutline, espLines, hpBackground, hpGood, hpLow] { shape.frame = bounds }
        CATransaction.commit()
        renderESP()
        hud.frame = CGRect(x: safe.left + 12, y: safe.top + 10, width: min(310, bounds.width - safe.left - safe.right - 24), height: 46)
    }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let prefs = MenuPreferences.shared
        context.setStrokeColor(prefs.accent.withAlphaComponent(0.28).cgColor)
        context.setLineWidth(0.5)
        if prefs.flag("grid") {
            for fraction in [CGFloat(1.0 / 3), CGFloat(2.0 / 3)] {
                context.move(to: CGPoint(x: bounds.width * fraction, y: 0)); context.addLine(to: CGPoint(x: bounds.width * fraction, y: bounds.height))
                context.move(to: CGPoint(x: 0, y: bounds.height * fraction)); context.addLine(to: CGPoint(x: bounds.width, y: bounds.height * fraction))
            }
            context.strokePath()
        }
        if prefs.flag("fovCircle") && !prefs.flag("silentAim") {
            let r = min(CGFloat(prefs.fovRadius), min(bounds.width, bounds.height) / 2 - 8)
            let circle = CGRect(x: bounds.midX-r, y: bounds.midY-r, width: r*2, height: r*2)
            context.setStrokeColor(UIColor.black.withAlphaComponent(0.7).cgColor)
            context.setLineWidth(3); context.strokeEllipse(in: circle)
            context.setStrokeColor(prefs.accent.withAlphaComponent(0.9).cgColor)
            context.setLineWidth(1); context.strokeEllipse(in: circle)
        }
        if prefs.flag("crosshair") {
            let center = CGPoint(x: bounds.midX, y: bounds.midY)
            context.setLineWidth(1.5); context.setStrokeColor(prefs.accent.cgColor)
            for direction in [CGPoint(x: -1, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 0, y: -1), CGPoint(x: 0, y: 1)] {
                context.move(to: CGPoint(x: center.x + direction.x * 5, y: center.y + direction.y * 5))
                context.addLine(to: CGPoint(x: center.x + direction.x * 13, y: center.y + direction.y * 13))
            }
            context.strokePath()
        }
    }
}

@MainActor
private final class MenuController: UIViewController {
    let metrics = UILabel(), coordinates = UILabel(), espStatus = UILabel(), flightStatus = UILabel(), actionStatus = UILabel(), selfStatus = UILabel(), weaponStatus = UILabel(), carStatus = UILabel(), log = UITextView()
    private let content = UIStackView(), bubble = UIButton(type: .system)
    private let categoryGrid = UIStackView(), navigation = UIStackView(), pageTitle = UILabel()
    private let scroll = UIScrollView()
    private var selectedPage: Int? = nil
    private let categoryTitles = ["Диагностика", "ESP и визуалы", "Движение", "Транспорт", "Персонаж", "Оружие", "Silent Aim", "Настройки"]
    private let pages = (0..<8).map { _ in UIStackView() }
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    var messages: [String] = []
    var collapsed = false, rightSide = true
    let aimStatus = UILabel()
    let extensionStatus = UILabel()
    private let stretchSlider = UISlider()
    private let stretchLabel = UILabel()
    let stretchStatus = UILabel()
    func setStretch(_ value: Double) { stretchSlider.value = Float(value); stretchLabel.text = String(format: "Масштаб 3D-проекции: ×%.2f", value) }
    func resetStretch() { stretchSlider.value = 1; stretchLabel.text = "Масштаб 3D-проекции: ×1.00"; stretchStatus.text = "Растяг выключен" }
    var showBubble = MenuPreferences.shared.flag("bubble", fallback: true)
    var onAction: ((String) -> Void)?, onMove: (() -> Void)?, onDrag: ((CGPoint) -> Void)?, onChange: (() -> Void)?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.06, alpha: 0.9)
        view.layer.cornerRadius = 22; view.clipsToBounds = true
        view.layer.borderWidth = 1; view.layer.borderColor = MenuPreferences.shared.accent.withAlphaComponent(0.35).cgColor
        view.overrideUserInterfaceStyle = .dark
        blur.isUserInteractionEnabled = false; view.addSubview(blur)
        let layout = UIStackView(); layout.axis = .vertical; layout.spacing = 12
        layout.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(layout)
        NSLayoutConstraint.activate([
            layout.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 14), layout.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -14),
            layout.topAnchor.constraint(equalTo: view.topAnchor, constant: 14), layout.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -14)
        ])
        let header = UIStackView(); header.spacing = 8
        let title = UILabel(); title.text = "React Modifications"; title.textColor = .white; title.font = .boldSystemFont(ofSize: 18); title.adjustsFontSizeToFitWidth = true; title.minimumScaleFactor = 0.7
        title.isUserInteractionEnabled = true
        title.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        header.addArrangedSubview(title)
        let collapse = button("−", "collapse"); collapse.widthAnchor.constraint(equalToConstant: 40).isActive = true
        header.addArrangedSubview(collapse); layout.addArrangedSubview(header)
        let home = button("‹ Разделы", "home")
        home.addAction(UIAction { [weak self] _ in self?.showPage(nil) }, for: .touchUpInside)
        navigation.axis = .horizontal; navigation.spacing = 10; navigation.alignment = .center
        pageTitle.font = .boldSystemFont(ofSize: 16); pageTitle.textColor = .white
        pageTitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        navigation.addArrangedSubview(home); navigation.addArrangedSubview(pageTitle)
        layout.addArrangedSubview(navigation)
        actionStatus.numberOfLines = 2; actionStatus.font = .systemFont(ofSize: 12)
        actionStatus.textColor = .systemOrange; actionStatus.text = ""
        actionStatus.accessibilityIdentifier = "diagnostics.actionStatus"
        layout.addArrangedSubview(actionStatus)
        scroll.alwaysBounceVertical = true
        layout.addArrangedSubview(scroll)
        content.axis = .vertical; content.spacing = 12; content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor), content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor), content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        categoryGrid.axis = .vertical; categoryGrid.spacing = 10
        let symbols = ["waveform.path.ecg", "eye", "figure.walk", "car.fill", "person.fill", "scope", "dot.scope", "slider.horizontal.3"]
        // A two-column home replaces eight small, hard-to-hit segments.
        for pair in [[4, 2], [3, 5], [1, 6], [7, 0]] {
            let row = UIStackView(); row.spacing = 10; row.distribution = .fillEqually
            for index in pair {
                let b = UIButton(type: .system)
                var config = UIButton.Configuration.tinted(); config.title = categoryTitles[index]
                config.image = UIImage(systemName: symbols[index]); config.imagePlacement = .top; config.imagePadding = 8
                config.baseForegroundColor = MenuPreferences.shared.accent; config.cornerStyle = .large
                config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                    var result = attributes; result.font = .systemFont(ofSize: 14, weight: .semibold); return result
                }
                b.configuration = config; b.heightAnchor.constraint(greaterThanOrEqualToConstant: 72).isActive = true
                b.accessibilityIdentifier = "diagnostics.category.\(index)"
                b.addAction(UIAction { [weak self] _ in self?.showPage(index) }, for: .touchUpInside)
                row.addArrangedSubview(b)
            }
            categoryGrid.addArrangedSubview(row)
        }
        content.addArrangedSubview(categoryGrid)
        for page in pages { page.axis = .vertical; page.spacing = 12; content.addArrangedSubview(page) }
        metrics.numberOfLines = 0; metrics.font = .monospacedSystemFont(ofSize: 12, weight: .medium); metrics.textColor = .white
        pages[0].addArrangedSubview(metrics)
        coordinates.numberOfLines = 0; coordinates.font = .monospacedSystemFont(ofSize: 11, weight: .regular); coordinates.textColor = MenuPreferences.shared.accent
        pages[0].addArrangedSubview(coordinates)
        espStatus.numberOfLines = 0; espStatus.font = .systemFont(ofSize: 11); espStatus.textColor = .systemOrange
        pages[0].addArrangedSubview(espStatus)
        let actions = UIStackView(); actions.spacing = 8; actions.distribution = .fillEqually
        actions.addArrangedSubview(button("Сторона", "side")); actions.addArrangedSubview(button("Копия", "copy")); pages[0].addArrangedSubview(actions)
        log.isEditable = false; log.font = .monospacedSystemFont(ofSize: 10, weight: .regular); log.textColor = .secondaryLabel
        log.backgroundColor = UIColor.white.withAlphaComponent(0.04); log.layer.cornerRadius = 10
        log.heightAnchor.constraint(equalToConstant: 75).isActive = true
        pages[0].addArrangedSubview(log); pages[0].addArrangedSubview(button("Очистить журнал", "clear"))
        pages[1].addArrangedSubview(toggle("ESP", key: "esp"))
        pages[1].addArrangedSubview(note("Данные игроков: 10–30 Гц. Проекция боксов — каждый кадр экрана."))
        let rate = UISlider(); rate.minimumValue = 10; rate.maximumValue = 30; rate.value = Float(MenuPreferences.shared.espRate)
        rate.accessibilityLabel = "Частота данных ESP"
        rate.addAction(UIAction { [weak rate] _ in MenuPreferences.shared.espRate = Double(rate?.value ?? 20) }, for: .valueChanged)
        pages[1].addArrangedSubview(rate)
        pages[1].addArrangedSubview(toggle("За стенами", key: "espWalls", fallback: true))
        pages[1].addArrangedSubview(toggle("Боксы", key: "espBox", fallback: true))
        pages[1].addArrangedSubview(toggle("Ник и ID", key: "espName", fallback: true))
        pages[1].addArrangedSubview(toggle("HP и полоса здоровья", key: "espHP", fallback: true))
        pages[1].addArrangedSubview(toggle("Броня", key: "espArmor"))
        pages[1].addArrangedSubview(toggle("Дистанция от камеры", key: "espDistance"))
        pages[1].addArrangedSubview(note("Дальность ESP: 25–500 м"))
        let range = UISlider(); range.minimumValue = 25; range.maximumValue = 500
        range.value = Float(MenuPreferences.shared.maxDistance); range.accessibilityLabel = "Дальность ESP"
        range.addAction(UIAction { [weak self, weak range] _ in
            MenuPreferences.shared.maxDistance = Double(range?.value ?? 150); self?.onChange?()
        }, for: .valueChanged); pages[1].addArrangedSubview(range)
        pages[1].addArrangedSubview(toggle("Компактный HUD", key: "hud", fallback: true))
        pages[1].addArrangedSubview(toggle("Прицел в центре экрана", key: "crosshair"))
        pages[1].addArrangedSubview(toggle("Направляющие 3 × 3", key: "grid"))
        pages[1].addArrangedSubview(toggle("Круг FOV", key: "fovCircle"))
        pages[1].addArrangedSubview(note("Радиус FOV · экранные точки"))
        let fov = UISlider(); fov.minimumValue = 30; fov.maximumValue = 300; fov.value = Float(MenuPreferences.shared.fovRadius)
        fov.accessibilityLabel = "Радиус FOV"
        fov.addAction(UIAction { [weak self, weak fov] _ in MenuPreferences.shared.fovRadius = Double(fov?.value ?? 100); self?.onChange?() }, for: .valueChanged)
        pages[1].addArrangedSubview(fov)
        pages[2].addArrangedSubview(toggle("Ускорение пешком", key: "runSpeed"))
        let runLabel = note(String(format: "Скорость бега: ×%.1f", MenuPreferences.shared.runMultiplier))
        let runSpeed = UISlider(); runSpeed.minimumValue = 1; runSpeed.maximumValue = 3; runSpeed.value = Float(MenuPreferences.shared.runMultiplier)
        runSpeed.addAction(UIAction { [weak self, weak runSpeed] _ in
            MenuPreferences.shared.runMultiplier = Double(runSpeed?.value ?? 1.5)
            runLabel.text = String(format: "Скорость бега: ×%.1f", MenuPreferences.shared.runMultiplier); self?.onChange?()
        }, for: .valueChanged)
        pages[2].addArrangedSubview(runLabel); pages[2].addArrangedSubview(runSpeed)
        flightStatus.text = "AirBrake выключен"; flightStatus.font = .systemFont(ofSize: 11); flightStatus.textColor = .systemOrange
        pages[2].addArrangedSubview(flightStatus)
        pages[2].addArrangedSubview(toggle("No Collision · без столкновений", key: "noCollision"))
        pages[2].addArrangedSubview(toggle("NoClip только в AirBrake", key: "noClip"))
        pages[2].addArrangedSubview(button("AirBrake · включить / выключить", "flightToggle"))
        let flightSpeed = UISlider(); flightSpeed.minimumValue = 1; flightSpeed.maximumValue = 30; flightSpeed.value = Float(MenuPreferences.shared.flightSpeed)
        flightSpeed.accessibilityLabel = "Скорость AirBrake"
        flightSpeed.addAction(UIAction { [weak flightSpeed] _ in MenuPreferences.shared.flightSpeed = Double(flightSpeed?.value ?? 5) }, for: .valueChanged)
        pages[2].addArrangedSubview(note("Скорость AirBrake · 1–30")); pages[2].addArrangedSubview(flightSpeed)
        for directions in [[("←", "flightLeft"), ("↑", "flightForward"), ("→", "flightRight")], [("Вверх", "flightUp"), ("↓", "flightBack"), ("Вниз", "flightDown")]] {
            let row = UIStackView(); row.axis = .horizontal; row.spacing = 6; row.distribution = .fillEqually
            for (title, action) in directions { row.addArrangedSubview(holdButton(title, action)) }
            pages[2].addArrangedSubview(row)
        }
        pages[2].addArrangedSubview(button("Телепорт по метке на карте", "waypoint"))
        pages[2].addArrangedSubview(button("Отменить телепорт по метке", "waypointCancel"))
        pages[2].addArrangedSubview(button("Телепорт по XYZ", "teleportXYZ"))
        pages[2].addArrangedSubview(button("К загруженному игроку по ID", "teleportPlayer"))
        pages[2].addArrangedSubview(button("К транспорту по ID", "teleportVehicle"))
        pages[2].addArrangedSubview(button("К ближайшему загруженному авто", "nearestVehicle"))
        pages[2].addArrangedSubview(button("Сохранить текущую точку", "savePoint"))
        pages[2].addArrangedSubview(button("Вернуться в сохранённую точку", "returnPoint"))
        pages[2].addArrangedSubview(note("Сила прыжка · 1–5"))
        let hop = UISlider(); hop.minimumValue = 1; hop.maximumValue = 5; hop.value = Float(MenuPreferences.shared.hopPower)
        hop.accessibilityLabel = "Сила прыжка"
        hop.addAction(UIAction { [weak hop] _ in MenuPreferences.shared.hopPower = Double(hop?.value ?? 1) }, for: .valueChanged)
        pages[2].addArrangedSubview(hop)
        pages[2].addArrangedSubview(button("Высокий прыжок", "hop"))
        pages[2].addArrangedSubview(button("Рывок вперёд · та же сила 1–5", "dash"))
        pages[2].addArrangedSubview(toggle("Мягкое падение", key: "slowFall"))
        pages[2].addArrangedSubview(note("Множитель массы · 0.1–5"))
        let mass = UISlider(); mass.minimumValue = 0.1; mass.maximumValue = 5; mass.value = Float(MenuPreferences.shared.massFactor)
        mass.accessibilityLabel = "Множитель массы"
        mass.addAction(UIAction { [weak mass] _ in MenuPreferences.shared.massFactor = Double(mass?.value ?? 1) }, for: .valueChanged)
        pages[2].addArrangedSubview(mass)
        pages[2].addArrangedSubview(button("Применить массу к персонажу", "massPed"))
        pages[2].addArrangedSubview(button("Восстановить исходную массу", "massReset"))
        pages[2].addArrangedSubview(note("Гравитация · множитель от −2 до 3"))
        let gravity = UISlider(); gravity.minimumValue = -2; gravity.maximumValue = 3; gravity.value = Float(MenuPreferences.shared.gravityFactor)
        gravity.accessibilityLabel = "Множитель гравитации"
        gravity.addAction(UIAction { [weak gravity] _ in MenuPreferences.shared.gravityFactor = Double(gravity?.value ?? 1) }, for: .valueChanged)
        pages[2].addArrangedSubview(gravity)
        pages[2].addArrangedSubview(button("Применить гравитацию к персонажу", "gravityPed"))
        pages[2].addArrangedSubview(button("Восстановить гравитацию", "gravityReset"))
        carStatus.font = .monospacedSystemFont(ofSize: 11, weight: .regular); carStatus.textColor = .systemCyan; carStatus.numberOfLines = 0
        pages[3].addArrangedSubview(carStatus)
        pages[3].addArrangedSubview(button("Bypass Lock · открыть ближайшую машину", "unlockVehicle"))
        pages[3].addArrangedSubview(button("Drive Without Key · запустить двигатель", "startEngine"))
        pages[3].addArrangedSubview(button("Подменить модель машины по ID", "carSet"))
        pages[3].addArrangedSubview(button("Вернуть исходную модель машины", "carRestore"))
        pages[3].addArrangedSubview(button("Остановить транспорт", "stopVehicle"))
        pages[3].addArrangedSubview(button("Восстановить HP авто", "healVehicle"))
        pages[3].addArrangedSubview(button("Ремонт кузова", "repairVehicle"))
        pages[3].addArrangedSubview(toggle("Защита транспорта", key: "vehicleProof"))
        pages[3].addArrangedSubview(toggle("Автовосстановление HP авто", key: "autoVehicleHealth"))
        pages[3].addArrangedSubview(button("Поставить на колёса", "flipVehicle"))
        pages[3].addArrangedSubview(note("Разовое ускорение · 1–3"))
        let boost = UISlider(); boost.minimumValue = 1; boost.maximumValue = 3; boost.value = Float(MenuPreferences.shared.boostPower)
        boost.accessibilityLabel = "Сила ускорения транспорта"
        boost.addAction(UIAction { [weak boost] _ in MenuPreferences.shared.boostPower = Double(boost?.value ?? 1.5) }, for: .valueChanged)
        pages[3].addArrangedSubview(boost)
        pages[3].addArrangedSubview(button("Ускорить транспорт", "boostVehicle"))
        pages[3].addArrangedSubview(button("Применить выбранную массу к авто", "massVehicle"))
        pages[3].addArrangedSubview(button("Восстановить исходную массу", "massReset"))
        pages[3].addArrangedSubview(button("Применить выбранную гравитацию к авто", "gravityVehicle"))
        pages[3].addArrangedSubview(button("Восстановить гравитацию", "gravityReset"))
        selfStatus.numberOfLines = 0; selfStatus.font = .monospacedSystemFont(ofSize: 11, weight: .regular); selfStatus.textColor = .systemCyan
        pages[4].addArrangedSubview(selfStatus)
        pages[4].addArrangedSubview(button("Suicide · завершить жизнь персонажа", "suicide"))
        pages[4].addArrangedSubview(button("Fast Respawn · появиться снова", "respawn"))
        pages[4].addArrangedSubview(toggle("Антифриз / Anti-Tazer", key: "antiFreeze"))
        pages[4].addArrangedSubview(toggle("NoAnim · отключение анимаций", key: "noAnim"))
        pages[4].addArrangedSubview(toggle("Fast Anim · ускоренные анимации", key: "fastAnim"))
        let animationLabel = note(String(format: "Скорость анимаций: ×%.1f", MenuPreferences.shared.animationRate))
        let animationRate = UISlider(); animationRate.minimumValue = 1; animationRate.maximumValue = 4
        animationRate.value = Float(MenuPreferences.shared.animationRate); animationRate.accessibilityIdentifier = "diagnostics.animationRate"
        animationRate.addAction(UIAction { [weak self, weak animationRate] _ in
            MenuPreferences.shared.animationRate = Double(animationRate?.value ?? 2)
            animationLabel.text = String(format: "Скорость анимаций: ×%.1f", MenuPreferences.shared.animationRate); self?.onChange?()
        }, for: .valueChanged)
        pages[4].addArrangedSubview(animationLabel); pages[4].addArrangedSubview(animationRate)
        pages[4].addArrangedSubview(button("Сменить скин по ID", "skinSet"))
        pages[4].addArrangedSubview(button("Вернуть исходный скин", "skinRestore"))
        pages[4].addArrangedSubview(button("Выключить игровые функции", "resetControls"))
        pages[4].addArrangedSubview(toggle("Защита от урона", key: "localProof"))
        pages[4].addArrangedSubview(toggle("Защита от падения", key: "noFall"))
        pages[4].addArrangedSubview(button("Восстановить HP", "heal"))
        pages[4].addArrangedSubview(button("Восстановить броню", "armor"))
        pages[4].addArrangedSubview(toggle("Автовосстановление HP", key: "autoHealth"))
        pages[4].addArrangedSubview(toggle("Автовосстановление брони", key: "autoArmor"))
        pages[4].addArrangedSubview(toggle("Выносливость", key: "stamina"))
        weaponStatus.numberOfLines = 0; weaponStatus.font = .monospacedSystemFont(ofSize: 11, weight: .regular); weaponStatus.textColor = .systemCyan
        pages[5].addArrangedSubview(weaponStatus)
        pages[5].addArrangedSubview(toggle("Доп. звук выстрела", key: "customShotSound"))
        pages[5].addArrangedSubview(note("Воспроизводится поверх звука игры"))
        pages[5].addArrangedSubview(button("Прослушать звук", "shotPreview"))
        pages[5].addArrangedSubview(button("Импортировать звук", "shotImport"))
        pages[5].addArrangedSubview(button("Мягкий щелчок", "shotReset"))
        pages[5].addArrangedSubview(toggle("No Spread · убрать разброс", key: "noSpread"))
        pages[5].addArrangedSubview(button("Выдать и выбрать оружие по ID", "weaponGive"))
        pages[5].addArrangedSubview(button("Пополнить запас патронов", "ammoRefill"))
        pages[5].addArrangedSubview(button("Заполнить магазин из запаса", "magazineFill"))
        pages[5].addArrangedSubview(toggle("Бесконечный запас патронов", key: "infiniteAmmo"))
        pages[5].addArrangedSubview(toggle("Без перезарядки", key: "noReload"))
        pages[5].addArrangedSubview(toggle("Rapid Fire · скорострельность", key: "rapidFire"))
        let rateLabel = note(String(format: "Скорострельность: ×%.1f", MenuPreferences.shared.fireRate)); pages[5].addArrangedSubview(rateLabel)
        let fireRate = UISlider(); fireRate.minimumValue = 1; fireRate.maximumValue = 5; fireRate.value = Float(MenuPreferences.shared.fireRate)
        fireRate.accessibilityLabel = "Множитель скорострельности"
        fireRate.addAction(UIAction { [weak self, weak fireRate] _ in MenuPreferences.shared.fireRate = Double(fireRate?.value ?? 2); rateLabel.text = String(format: "Скорострельность: ×%.1f", MenuPreferences.shared.fireRate); self?.onChange?() }, for: .valueChanged)
        pages[5].addArrangedSubview(fireRate)
        pages[6].addArrangedSubview(toggle("TriggerBot", key: "triggerBot"))
        pages[6].addArrangedSubview(toggle("TriggerBot только при прицеливании", key: "triggerAimOnly", fallback: true))
        let triggerRadiusLabel = note(String(format: "Зона TriggerBot: %.0f pt", MenuPreferences.shared.triggerRadius))
        let triggerRadius = UISlider(); triggerRadius.minimumValue = 2; triggerRadius.maximumValue = 30; triggerRadius.value = Float(MenuPreferences.shared.triggerRadius)
        triggerRadius.accessibilityLabel = "Зона TriggerBot"
        triggerRadius.addAction(UIAction { [weak self, weak triggerRadius] _ in
            MenuPreferences.shared.triggerRadius = Double(triggerRadius?.value ?? 10)
            triggerRadiusLabel.text = String(format: "Зона TriggerBot: %.0f pt", MenuPreferences.shared.triggerRadius); self?.onChange?()
        }, for: .valueChanged)
        pages[6].addArrangedSubview(triggerRadiusLabel); pages[6].addArrangedSubview(triggerRadius)
        let triggerDelayLabel = note(String(format: "Задержка TriggerBot: %.0f мс", MenuPreferences.shared.triggerDelay))
        let triggerDelay = UISlider(); triggerDelay.minimumValue = 0; triggerDelay.maximumValue = 500; triggerDelay.value = Float(MenuPreferences.shared.triggerDelay)
        triggerDelay.accessibilityLabel = "Задержка TriggerBot"
        triggerDelay.addAction(UIAction { [weak self, weak triggerDelay] _ in
            MenuPreferences.shared.triggerDelay = Double(triggerDelay?.value ?? 120)
            triggerDelayLabel.text = String(format: "Задержка TriggerBot: %.0f мс", MenuPreferences.shared.triggerDelay); self?.onChange?()
        }, for: .valueChanged)
        pages[6].addArrangedSubview(triggerDelayLabel); pages[6].addArrangedSubview(triggerDelay)
        pages[6].addArrangedSubview(toggle("Silent Aim", key: "silentAim"))
        aimStatus.numberOfLines = 0; aimStatus.font = .monospacedSystemFont(ofSize: 10, weight: .regular); aimStatus.textColor = .systemGreen
        pages[6].addArrangedSubview(aimStatus)
        pages[6].addArrangedSubview(toggle("Точка: голова (выкл. — корпус)", key: "aimHead"))
        pages[6].addArrangedSubview(note("Радиус FOV в экранных точках"))
        let aimFOV = UISlider(); aimFOV.minimumValue = 30; aimFOV.maximumValue = 300; aimFOV.value = Float(MenuPreferences.shared.fovRadius)
        aimFOV.accessibilityLabel = "FOV Silent Aim"
        aimFOV.addAction(UIAction { [weak self, weak aimFOV] _ in MenuPreferences.shared.fovRadius = Double(aimFOV?.value ?? 100); self?.onChange?() }, for: .valueChanged)
        pages[6].addArrangedSubview(aimFOV)
        pages[6].addArrangedSubview(toggle("Показывать круг FOV", key: "aimFOV", fallback: true))
        pages[6].addArrangedSubview(toggle("Круг только при наличии цели", key: "aimFOVOnlyTarget", fallback: false))
        pages[6].addArrangedSubview(toggle("Зелёная надпись Shoot", key: "aimShoot", fallback: true))
        let missLabel = note(String(format: "Шанс пропуска наведения: %.0f%%", MenuPreferences.shared.aimMiss)); pages[6].addArrangedSubview(missLabel)
        let miss = UISlider(); miss.minimumValue = 0; miss.maximumValue = 100; miss.value = Float(MenuPreferences.shared.aimMiss)
        miss.accessibilityLabel = "Шанс пропуска Silent Aim"
        miss.addAction(UIAction { [weak self, weak miss, weak missLabel] _ in
            MenuPreferences.shared.aimMiss = Double(miss?.value ?? 0)
            missLabel?.text = String(format: "Шанс пропуска наведения: %.0f%%", MenuPreferences.shared.aimMiss); self?.onChange?()
        }, for: .valueChanged); pages[6].addArrangedSubview(miss)
        pages[6].addArrangedSubview(button("Исключения: ID и ники", "aimWhitelist"))
        pages[6].addArrangedSubview(button("Добавить текущую цель в исключения", "aimExcludeTarget"))
        pages[6].addArrangedSubview(button("Очистить исключения", "aimClearWhitelist"))
        stretchLabel.font = .systemFont(ofSize: 11); stretchLabel.textColor = .secondaryLabel
        stretchLabel.text = String(format: "Масштаб 3D-проекции: ×%.2f", MenuPreferences.shared.stretch)
        stretchSlider.minimumValue = 1; stretchSlider.maximumValue = 1.6
        stretchSlider.value = Float(MenuPreferences.shared.stretch); stretchSlider.accessibilityLabel = "Горизонтальный растяг"
        stretchSlider.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            MenuPreferences.shared.stretch = Double(self.stretchSlider.value)
            self.stretchLabel.text = String(format: "Масштаб 3D-проекции: ×%.2f", MenuPreferences.shared.stretch)
            self.onChange?()
        }, for: .valueChanged)
        extensionStatus.numberOfLines = 0; extensionStatus.font = .systemFont(ofSize: 11); extensionStatus.textColor = .systemCyan
        pages[7].addArrangedSubview(extensionStatus)
        pages[7].addArrangedSubview(toggle("Fake Lag · синхронизация пешком", key: "fakeLag"))
        let lagLabel = note(String(format: "Интервал синхронизации: %.0f мс", MenuPreferences.shared.lagInterval))
        let lag = UISlider(); lag.minimumValue = 50; lag.maximumValue = 500; lag.value = Float(MenuPreferences.shared.lagInterval)
        lag.accessibilityLabel = "Интервал Fake Lag"
        lag.addAction(UIAction { [weak self, weak lag] _ in
            MenuPreferences.shared.lagInterval = Double(lag?.value ?? 200)
            lagLabel.text = String(format: "Интервал синхронизации: %.0f мс", MenuPreferences.shared.lagInterval); self?.onChange?()
        }, for: .valueChanged)
        pages[7].addArrangedSubview(lagLabel); pages[7].addArrangedSubview(lag)
        pages[7].addArrangedSubview(toggle("Свой FOV камеры", key: "cameraFOVOverride"))
        let cameraFOVLabel = note(String(format: "FOV камеры: %.0f°", MenuPreferences.shared.cameraFOV))
        let cameraFOV = UISlider(); cameraFOV.minimumValue = 50; cameraFOV.maximumValue = 120; cameraFOV.value = Float(MenuPreferences.shared.cameraFOV)
        cameraFOV.addAction(UIAction { [weak self, weak cameraFOV] _ in
            MenuPreferences.shared.cameraFOV = Double(cameraFOV?.value ?? 70)
            cameraFOVLabel.text = String(format: "FOV камеры: %.0f°", MenuPreferences.shared.cameraFOV); self?.onChange?()
        }, for: .valueChanged)
        pages[7].addArrangedSubview(cameraFOVLabel); pages[7].addArrangedSubview(cameraFOV)
        pages[7].addArrangedSubview(toggle("Своё время суток", key: "worldTimeOverride"))
        let hourLabel = note(String(format: "Часы: %.0f", MenuPreferences.shared.worldHour))
        let hour = UISlider(); hour.minimumValue = 0; hour.maximumValue = 23; hour.value = Float(MenuPreferences.shared.worldHour)
        hour.addAction(UIAction { [weak self, weak hour] _ in MenuPreferences.shared.worldHour = Double(hour?.value ?? 0); hourLabel.text = String(format: "Часы: %.0f", MenuPreferences.shared.worldHour); self?.onChange?() }, for: .valueChanged)
        pages[7].addArrangedSubview(hourLabel); pages[7].addArrangedSubview(hour)
        let minuteLabel = note(String(format: "Минуты: %.0f", MenuPreferences.shared.worldMinute))
        let minute = UISlider(); minute.minimumValue = 0; minute.maximumValue = 59; minute.value = Float(MenuPreferences.shared.worldMinute)
        minute.addAction(UIAction { [weak self, weak minute] _ in MenuPreferences.shared.worldMinute = Double(minute?.value ?? 0); minuteLabel.text = String(format: "Минуты: %.0f", MenuPreferences.shared.worldMinute); self?.onChange?() }, for: .valueChanged)
        pages[7].addArrangedSubview(minuteLabel); pages[7].addArrangedSubview(minute)
        pages[7].addArrangedSubview(toggle("Своя погода", key: "worldWeatherOverride"))
        let weatherLabel = note(String(format: "Погода: ID %.0f", MenuPreferences.shared.worldWeather))
        let weather = UISlider(); weather.minimumValue = 0; weather.maximumValue = 21; weather.value = Float(MenuPreferences.shared.worldWeather)
        weather.addAction(UIAction { [weak self, weak weather] _ in MenuPreferences.shared.worldWeather = Double(weather?.value ?? 0); weatherLabel.text = String(format: "Погода: ID %.0f", MenuPreferences.shared.worldWeather); self?.onChange?() }, for: .valueChanged)
        pages[7].addArrangedSubview(weatherLabel); pages[7].addArrangedSubview(weather)
        let aspectPresets = UIStackView(); aspectPresets.spacing = 6; aspectPresets.distribution = .fillEqually
        aspectPresets.addArrangedSubview(button("Обычный", "aspectOriginal"))
        aspectPresets.addArrangedSubview(button("Планшет", "aspectTablet"))
        aspectPresets.addArrangedSubview(button("Широкий", "aspectWide"))
        pages[7].addArrangedSubview(aspectPresets)
        pages[7].addArrangedSubview(stretchLabel); pages[7].addArrangedSubview(stretchSlider)
        stretchStatus.font = .systemFont(ofSize: 10); stretchStatus.textColor = .systemOrange; stretchStatus.numberOfLines = 0
        pages[7].addArrangedSubview(stretchStatus)
        pages[7].addArrangedSubview(button("Вернуть обычное изображение", "stretchReset"))
        pages[7].addArrangedSubview(toggle("Сокращения в чате", key: "aliasesAuto"))
        pages[7].addArrangedSubview(button("Быстрая команда", "commandCompose"))
        pages[7].addArrangedSubview(button("Сокращения команд", "commandAliases"))
        pages[7].addArrangedSubview(button("Отменить ожидающую подмену", "modelCancel"))
        pages[7].addArrangedSubview(button("Выключить игровые функции", "resetControls"))
        pages[7].addArrangedSubview(toggle("Плавающая кнопка", key: "bubble", fallback: true))
        pages[7].addArrangedSubview(toggle("Анимации", key: "animations", fallback: true))
        pages[7].addArrangedSubview(toggle("Увеличенное меню", key: "large"))
        pages[7].addArrangedSubview(note("Прозрачность"))
        let opacity = UISlider(); opacity.minimumValue = 0.45; opacity.maximumValue = 1; opacity.value = Float(MenuPreferences.shared.opacity)
        opacity.accessibilityLabel = "Прозрачность меню"
        opacity.addAction(UIAction { [weak self, weak opacity] _ in
            MenuPreferences.shared.opacity = CGFloat(opacity?.value ?? 1); self?.onChange?()
        }, for: .valueChanged); pages[7].addArrangedSubview(opacity)
        let colors = UISegmentedControl(items: ["Лёд", "Огонь"]); colors.selectedSegmentIndex = MenuPreferences.shared.accentIndex
        colors.addAction(UIAction { [weak self, weak colors] _ in
            MenuPreferences.shared.accentIndex = colors?.selectedSegmentIndex ?? 0
            self?.coordinates.textColor = MenuPreferences.shared.accent
            self?.view.layer.borderColor = MenuPreferences.shared.accent.withAlphaComponent(0.35).cgColor
            self?.onChange?()
        }, for: .valueChanged); pages[7].addArrangedSubview(colors)
        bubble.setTitle("RM", for: .normal); bubble.titleLabel?.font = .boldSystemFont(ofSize: 19); bubble.tintColor = .systemCyan
        bubble.accessibilityIdentifier = "diagnostics.expand"; bubble.accessibilityLabel = "Открыть React Modifications"
        bubble.addAction(UIAction { [weak self] _ in self?.onAction?("collapse") }, for: .touchUpInside)
        bubble.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(drag(_:))))
        bubble.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(bubble)
        NSLayoutConstraint.activate([bubble.leadingAnchor.constraint(equalTo: view.leadingAnchor), bubble.trailingAnchor.constraint(equalTo: view.trailingAnchor), bubble.topAnchor.constraint(equalTo: view.topAnchor), bubble.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        showPage(nil); applyCollapse()
    }
    private func note(_ text: String) -> UILabel {
        let label = UILabel(); label.text = text; label.numberOfLines = 0; label.textColor = .secondaryLabel; label.font = .systemFont(ofSize: 12); return label
    }
    private func toggle(_ title: String, key: String, fallback: Bool = false) -> UIView {
        let row = UIStackView(); row.spacing = 12; row.alignment = .center
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        let label = note(title); label.font = .systemFont(ofSize: 15, weight: .medium); label.textColor = .white; label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let control = UISwitch(); control.isOn = MenuPreferences.shared.flag(key, fallback: fallback)
        control.accessibilityIdentifier = "diagnostics.\(key)"; control.accessibilityLabel = title
        control.onTintColor = MenuPreferences.shared.accent
        control.addAction(UIAction { [weak self, weak control] _ in
            MenuPreferences.shared.set(key, control?.isOn ?? false)
            if key == "bubble" { self?.showBubble = control?.isOn ?? true }
            self?.onChange?()
        }, for: .valueChanged)
        row.addArrangedSubview(label); row.addArrangedSubview(control); return row
    }
    func syncControlToggles() {
        func visit(_ view: UIView) {
            if let control = view as? UISwitch, let identifier = control.accessibilityIdentifier {
                let key = identifier.replacingOccurrences(of: "diagnostics.", with: "")
                if MenuPreferences.controlKeys.contains(key) || key == "silentAim" { control.setOn(MenuPreferences.shared.flag(key), animated: false) }
            }
            for child in view.subviews { visit(child) }
        }
        visit(view)
    }
    private func showPage(_ selected: Int?) {
        onAction?("flightRelease"); selectedPage = selected
        navigation.isHidden = selected == nil; categoryGrid.isHidden = selected != nil
        pageTitle.text = selected.map { categoryTitles[$0] }
        for (index, page) in pages.enumerated() { page.isHidden = index != selected }
        scroll.setContentOffset(.zero, animated: false)
        if MenuPreferences.shared.animations && !UIAccessibility.isReduceMotionEnabled {
            content.alpha = 0; UIView.animate(withDuration: 0.18) { self.content.alpha = 1 }
        }
    }
    @objc private func drag(_ recognizer: UIPanGestureRecognizer) {
        onDrag?(recognizer.translation(in: view.superview)); recognizer.setTranslation(.zero, in: view.superview)
    }
    private func holdButton(_ title: String, _ action: String) -> UIButton {
        let b = UIButton(type: .system); b.accessibilityIdentifier = "diagnostics.\(action)"
        var config = UIButton.Configuration.tinted(); config.title = title; config.baseForegroundColor = MenuPreferences.shared.accent; b.configuration = config
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        b.isExclusiveTouch = true
        b.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchDown)
        b.addAction(UIAction { [weak self] _ in self?.onAction?("flightRelease") }, for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit])
        return b
    }
    private func button(_ title: String, _ action: String) -> UIButton {
        let b = UIButton(type: .system); b.accessibilityIdentifier = "diagnostics.\(action)"
        var configuration = UIButton.Configuration.tinted(); configuration.title = title; configuration.cornerStyle = .medium
        configuration.baseForegroundColor = MenuPreferences.shared.accent; b.configuration = configuration
        b.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        b.addAction(UIAction { [weak self] _ in self?.onAction?(action) }, for: .touchUpInside); return b
    }
    func applyCollapse() {
        for subview in view.subviews where subview !== blur && subview !== bubble { subview.isHidden = collapsed }
        bubble.isHidden = !collapsed
    }
    func refreshLog() {
        log.text = messages.joined(separator: "\n")
        if !log.text.isEmpty { log.scrollRangeToVisible(NSRange(location: (log.text as NSString).length - 1, length: 1)) }
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); blur.frame = view.bounds }
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in self?.onMove?() }
    }
}

// A full-screen window keeps UIKit hit testing in screen coordinates.
// Only the visible panel receives touches; its transparent surroundings pass through.
@MainActor
private final class PassthroughWindow: UIWindow {
    weak var panel: UIView?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let panel, !panel.isHidden, panel.alpha > 0.01,
              panel.bounds.contains(panel.convert(point, from: self)) else { return nil }
        return super.hitTest(point, with: event)
    }
}



/// Additional local feedback. Does not replace or mute the game's audio session.
@MainActor
private final class ReactShotAudio {
    private var players: [AVAudioPlayer] = []
    private var cached: Data?
    private var root: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory).appendingPathComponent("ReactModifications", isDirectory: true)
    }
    private var file: URL { root.appendingPathComponent("shot.audio") }
    private enum ImportError: Error { case invalid }
    func importFile(_ url: URL) throws {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 1_048_576 else { throw ImportError.invalid }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576 else { throw ImportError.invalid }
        let check = try AVAudioPlayer(data: data)
        guard check.duration.isFinite, check.duration > 0, check.duration <= 2, check.numberOfChannels <= 2 else { throw ImportError.invalid }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        stop(); cached = data
    }
    func reset() { stop(); try? FileManager.default.removeItem(at: file); cached = Self.click() }
    func stop() { players.forEach { $0.stop() }; players.removeAll() }
    func play() {
        if cached == nil { cached = (try? Data(contentsOf: file)) ?? Self.click() }
        guard let data = cached, let player = try? AVAudioPlayer(data: data) else { return }
        players.removeAll { !$0.isPlaying }
        if players.count >= 4 { players.removeFirst().stop() }
        player.volume = 0.35
        players.append(player); player.play()
    }
    private static func click() -> Data {
        let sampleRate = 22_050, count = 1_323
        var data = Data()
        func ascii(_ text: String) { data.append(contentsOf: text.utf8) }
        func put<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        ascii("RIFF"); put(UInt32(36 + count * 2)); ascii("WAVEfmt ")
        put(UInt32(16)); put(UInt16(1)); put(UInt16(1)); put(UInt32(sampleRate))
        put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16)); ascii("data"); put(UInt32(count * 2))
        for index in 0..<count {
            let t = Double(index) / Double(sampleRate)
            let fade = exp(-100 * t) * min(1, t / 0.001)
            let value = (sin(2 * .pi * 1700 * t) * 0.55 + sin(2 * .pi * 3100 * t) * 0.2) * fade
            put(Int16(max(-32767, min(32767, value * 32767))))
        }
        return data
    }
}

