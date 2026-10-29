#if BRMENU_LICENSED
import UIKit
import Security

/// Only compiled into the separately configured licensed build.
/// Bot token, pepper and encryption keys never enter the client.
@MainActor
final class LicenseGate {
    var onAccessChange: ((Bool) -> Void)?
    private var window: UIWindow?
    private weak var previousWindow: UIWindow?
    private weak var scene: UIWindowScene?
    private let status = UILabel(), keyField = UITextField(), activateButton = UIButton(type: .system)
    private var token: String?
    private var requestTask: Task<Void, Never>?, heartbeat: Task<Void, Never>?
    private var allowed = false
    private var generation: UInt64 = 0
    private func deviceID() throws -> String {
        if let saved = secret("device") { return saved }
        let value = UUID().uuidString
        guard save("device", value) else { throw Failure(message: "Не удалось сохранить привязку в Keychain. Повтори после разблокировки iPhone.") }
        return value
    }
    private let keychainService = "local.brmenu.license.v1"

    func present(in scene: UIWindowScene) {
        self.scene = scene
        guard !allowed, window == nil else { return }
        previousWindow = scene.windows.first { $0.isKeyWindow }
        let controller = UIViewController(); controller.view.backgroundColor = UIColor(white: 0.035, alpha: 0.97)
        controller.overrideUserInterfaceStyle = .dark
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(stack)
        let title = UILabel(); title.text = "React Modifications"; title.font = .boldSystemFont(ofSize: 23); title.adjustsFontSizeToFitWidth = true; title.minimumScaleFactor = 0.75; title.textColor = .white
        keyField.placeholder = "Ключ BR-…"; keyField.borderStyle = .roundedRect
        keyField.autocorrectionType = .no; keyField.spellCheckingType = .no; keyField.autocapitalizationType = .allCharacters
        keyField.isSecureTextEntry = true; keyField.text = secret("key")
        keyField.accessibilityIdentifier = "license.key"
        status.numberOfLines = 0; status.font = .systemFont(ofSize: 14); status.textColor = .secondaryLabel
        status.text = "Введи ключ из Telegram-бота. Для проверки нужен интернет. Первый запуск сервера может занять около минуты."
        var config = UIButton.Configuration.filled(); config.title = "Активировать"; activateButton.configuration = config
        activateButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48).isActive = true
        activateButton.addAction(UIAction { [weak self] _ in self?.activate() }, for: .touchUpInside)
        let shop = UIButton(type: .system); shop.setTitle("Купить / продлить в Telegram", for: .normal)
        shop.addAction(UIAction { _ in
            guard let url = URL(string: BRLicenseConfiguration.botURL) else { return }
            UIApplication.shared.open(url)
        }, for: .touchUpInside)
        for view in [title, keyField, activateButton, shop, status] { stack.addArrangedSubview(view) }
        let guide = controller.view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: guide.centerXAnchor), stack.centerYAnchor.constraint(equalTo: guide.centerYAnchor),
            stack.widthAnchor.constraint(equalToConstant: 340).withPriority(.defaultHigh),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: guide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: guide.trailingAnchor, constant: -20)
        ])
        let w = UIWindow(windowScene: scene); w.frame = scene.coordinateSpace.bounds
        w.windowLevel = .alert + 2; w.rootViewController = controller; window = w; w.makeKeyAndVisible()
        if secret("key") != nil { activate() }
    }

    func suspend() {
        generation &+= 1
        requestTask?.cancel(); requestTask = nil; heartbeat?.cancel(); heartbeat = nil
        token = nil; allowed = false; onAccessChange?(false)
        window?.isHidden = true; window = nil
    }

    private func setAccess(_ value: Bool, message: String) {
        allowed = value; onAccessChange?(value)
        if value {
            window?.isHidden = true; window = nil; previousWindow?.makeKey()
        } else {
            heartbeat?.cancel(); heartbeat = nil
            if let scene, scene.activationState == .foregroundActive { present(in: scene) }
            status.text = message; activateButton.isEnabled = true
        }
    }

    private struct Reply: Decodable {
        let token: String?
        let valid: Bool?
        let expires_at: Int?
    }
    private struct ServerError: Decodable { let message: String? }
    private struct Failure: Error { let message: String }

    private func post(_ path: String, fields: [String: String], bearer: String? = nil) async throws -> Reply {
        guard let url = URL(string: BRLicenseConfiguration.apiURL + path), url.scheme == "https" else {
            throw Failure(message: "Не настроен адрес сервера лицензий")
        }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer { request.setValue("Bearer " + bearer, forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        let (data, response) = try await URLSession.shared.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let error = try? JSONDecoder().decode(ServerError.self, from: data)
            throw Failure(message: error?.message ?? "Сервер не подтвердил доступ. Проверь ключ или обратись в поддержку.")
        }
        return try JSONDecoder().decode(Reply.self, from: data)
    }

    private func activate() {
        guard requestTask == nil else { return }
        let key = (keyField.text ?? secret("key") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { status.text = "Введи ключ"; return }
        status.text = "Проверяем ключ…"; activateButton.isEnabled = false
        generation &+= 1
        let epoch = generation
        requestTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == epoch { self.requestTask = nil; self.activateButton.isEnabled = true } }
            do {
                let reply = try await post("/v1/licenses/activate", fields: ["key": key, "device_id": try deviceID()])
                guard generation == epoch, !Task.isCancelled else { return }
                guard let newToken = reply.token, !newToken.isEmpty, let end = reply.expires_at,
                      end > Int(Date().timeIntervalSince1970) else { throw Failure(message: "Сервер вернул недействительную лицензию") }
                _ = save("key", key); token = newToken; setAccess(true, message: "")
                heartbeat?.cancel()
                heartbeat = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 60_000_000_000) } catch { return }
                        guard let self, let token = self.token else { return }
                        do {
                            let result = try await self.post("/v1/licenses/check", fields: ["device_id": try self.deviceID()], bearer: token)
                            guard result.valid == true else { throw Failure(message: "Доступ не подтверждён") }
                        } catch is CancellationError { return }
                        catch { self.setAccess(false, message: (error as? Failure)?.message ?? "Нет связи с сервером. Для продолжения повтори активацию."); return }
                    }
                }
            } catch is CancellationError { return }
            catch { guard generation == epoch, !Task.isCancelled else { return }; setAccess(false, message: (error as? Failure)?.message ?? "Нет связи с сервером. Попробуй ещё раз.") }
        }
    }

    private func secret(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func save(_ account: String, _ value: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var item = query; item.merge(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return result == errSecSuccess
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint { self.priority = priority; return self }
}
#endif

