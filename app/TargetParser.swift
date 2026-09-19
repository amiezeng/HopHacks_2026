import Foundation

enum TargetParser {
    private static let prefixes = [
        "can you help me find", "i am trying to find", "i'm trying to find", "i am looking for", "i'm looking for",
        "i want to find", "i need to find", "can you find", "help me find", "search for", "looking for",
        "where is", "where's", "find me", "locate", "find", "i need", "i want"
    ].map { $0.split(separator: " ").map(String.init) }

    private static let articles: Set<String> = ["a", "an", "the", "my", "some", "this", "that"]

    static func extract(from text: String) -> String {
        let allowed = CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'"))
        var words = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: allowed.inverted)
            .filter { !$0.isEmpty }

        var stripped = true
        while stripped {
            stripped = false
            if let prefix = prefixes.first(where: { words.starts(with: $0) }) {
                words.removeFirst(prefix.count)
                stripped = true
            }
        }
        while let first = words.first, articles.contains(first) {
            words.removeFirst()
        }
        if words.suffix(2) == ["for", "me"] { words.removeLast(2) }
        if words.last == "please" { words.removeLast() }

        return words.joined(separator: " ")
    }
}
