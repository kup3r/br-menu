import UIKit

@MainActor
final class ReactHostUI {
    private final class Balance {
        weak var label: UILabel?
        var text: String?, attributed: NSAttributedString?, written: String?
        init(_ label: UILabel) { self.label = label; text = label.text; attributed = label.attributedText }
        func restore() {
            guard let label, label.text == written else { return }
            if let attributed { label.attributedText = attributed } else { label.text = text }
        }
    }
    private var balances: [ObjectIdentifier: Balance] = [:]
    private var lastUpdate: CFTimeInterval = 0
    private func controllers(in scene: UIWindowScene) -> [UIViewController] {
        var queue = scene.windows.filter { $0.windowLevel == .normal && !$0.isHidden }.compactMap(\.rootViewController)
        var result: [UIViewController] = [], seen = Set<ObjectIdentifier>(), views = Set<ObjectIdentifier>()
        var cursor = 0
        func inspect(_ root: UIView) {
            var pending = [root], index = 0
            while index < pending.count && index < 5000 {
                let view = pending[index]; index += 1
                guard views.insert(ObjectIdentifier(view)).inserted else { continue }
                if let owner = view.next as? UIViewController { queue.append(owner) }
                pending.append(contentsOf: view.subviews)
            }
        }
        while cursor < queue.count && cursor < 500 {
            let controller = queue[cursor]; cursor += 1
            guard seen.insert(ObjectIdentifier(controller)).inserted else { continue }
            result.append(controller); queue.append(contentsOf: controller.children)
            if let presented = controller.presentedViewController { queue.append(presented) }
            if controller.isViewLoaded { inspect(controller.view) }
        }
        return result
    }
    func clearChat(in scene: UIWindowScene, clear: ((NSObject) -> Bool)?) -> Int {
        var count = 0
        for controller in controllers(in: scene) {
            let name = NSStringFromClass(type(of: controller))
            guard name == "BrBase.ChatViewController" || name == "BrBase.EventChatViewController",
                  clear?(controller) == true else { continue }
            if controller.responds(to: NSSelectorFromString("tableView")),
               let table = controller.value(forKey: "tableView") as? UITableView {
                table.reloadData(); table.setContentOffset(.zero, animated: false)
            }
            count += 1
        }
        return count
    }
    func update(in scene: UIWindowScene, balance: Double?) {
        let now = CACurrentMediaTime()
        guard now - lastUpdate >= 0.25 else { return }; lastUpdate = now
        guard let balance else { restore(); return }
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal; formatter.groupingSeparator = " "
        formatter.maximumFractionDigits = 0
        let text = (formatter.string(from: NSNumber(value: balance)) ?? "0") + " ₽"
        for controller in controllers(in: scene) {
            let name = NSStringFromClass(type(of: controller))
            guard controller.isViewLoaded,
                  name == "BrBase.MainScreenViewController" || name == "BrBase.MainScreenFamilyViewController",
                  controller.responds(to: NSSelectorFromString("moneyLabel")),
                  let label = controller.value(forKey: "moneyLabel") as? UILabel else { continue }
            let key = ObjectIdentifier(label), record = balances[key] ?? Balance(label)
            if record.written != nil && label.text != record.written { record.text = label.text; record.attributed = label.attributedText }
            label.text = text; record.written = text; balances[key] = record
        }
        balances = balances.filter { $0.value.label != nil }
    }
    func restore() { balances.values.forEach { $0.restore() }; balances.removeAll() }
}
