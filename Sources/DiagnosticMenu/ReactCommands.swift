import Foundation

enum ReactCommandAliases {
    static func expand(_ input: String, rules: String) -> String {
        let text = String(input.prefix(1024)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/") else { return text }
        let boundary = text.firstIndex(where: { $0.isWhitespace }) ?? text.endIndex
        let command = String(text[..<boundary]).lowercased()
        let suffix = String(text[boundary...])
        let mapping = mapping(rules)
        return (mapping[command] ?? String(text[..<boundary])) + suffix
    }
    static func mapping(_ rules: String) -> [String: String] {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        func valid(_ value: String) -> Bool {
            value.hasPrefix("/") && value.count >= 2 && value.count <= 49 &&
                value.dropFirst().unicodeScalars.allSatisfy { allowed.contains($0) }
        }
        var mapping: [String: String] = [:]
        for rule in rules.prefix(2048).components(separatedBy: CharacterSet(charactersIn: ";,\n")) {
            let pair = rule.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, valid(pair[0]), valid(pair[1]) { mapping[pair[0].lowercased()] = pair[1] }
        }
        return mapping
    }

}

