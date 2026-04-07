import Foundation

enum URLInputNormalizer {
    static func url(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let direct = URL(string: trimmed), let scheme = direct.scheme?.lowercased() {
            guard ["http", "https"].contains(scheme), direct.host != nil else { return nil }
            return direct
        }

        if trimmed.contains(" ") || (!trimmed.contains(".") && !trimmed.contains(":")) {
            let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            return URL(string: "https://www.google.com/search?q=\(query)")
        }

        guard let withScheme = URL(string: "https://\(trimmed)") else { return nil }
        guard let scheme = withScheme.scheme?.lowercased(), ["http", "https"].contains(scheme), withScheme.host != nil else {
            return nil
        }
        return withScheme
    }

    static func isWebURLAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return ["http", "https"].contains(scheme) && url.host != nil
    }
}
