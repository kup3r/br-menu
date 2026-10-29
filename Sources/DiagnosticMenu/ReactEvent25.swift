import Foundation

/// Only receives server-client messages, never player-chat RPCs or outgoing text.
struct ReactEvent25 {
    private var lastSent = -Double.infinity
    private var seen: [String: Double] = [:]
    mutating func reset() { lastSent = -Double.infinity; seen.removeAll() }
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\\{[0-9a-fA-F]{6}(?:[0-9a-fA-F]{2})?\\}", with: "", options: .regularExpression)
            .lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    static func announcement(_ text: String) -> Bool {
        guard text.utf8.count <= 4096 else { return false }
        let s = normalize(text)
        guard s.range(of: "(?<![a-z0-9_])/gevent(?![a-z0-9_])", options: .regularExpression) != nil else { return false }
        let blocked = ["закрыт", "заверш", "оконч", "отмен", "недоступ", "не можете", "нельзя", "не проводится"]
        guard !blocked.contains(where: { s.contains($0) }) else { return false }
        let prefixes = ["администратор", "админ ", "[админ", "[мп]", "[мероприятие]", "мероприятие", "[admin", "administrator", "[event]"]
        guard prefixes.contains(where: { s.hasPrefix($0) }) else { return false }
        return ["набор", "нач", "провод", "созда", "участ", "вход", "присоедин", "join", "started"].contains(where: { s.contains($0) })
    }
    mutating func consume(_ text: String, now: Double, received: Double, enabled: Bool, foreground: Bool, connected: Bool) -> Bool {
        guard enabled, foreground, connected, now.isFinite, received.isFinite, now >= received, now-received <= 2,
              Self.announcement(text), now-lastSent >= 10 else { return false }
        seen = seen.filter { now-$0.value < 300 }
        let key = Self.normalize(text)
        guard seen[key] == nil else { return false }
        if seen.count >= 32 { seen.removeAll() }
        seen[key] = now; lastSent = now; return true
    }
}
