import SwiftUI

/// Plain text used by card descriptions.
enum TaskCardExcerpt {

    static func text(_ body: String?) -> String {
        guard let body else { return "" }
        var text = String(body.prefix(8_000))
        text = text.replacingOccurrences(of: "(?s)<!--.*?(?:-->|$)", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"!\[[^\]]*\]\([^)]*\)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?m)^\s*(?:#{1,6}\s+|>\s*|[-*+]\s+(?:\[[ xX]\]\s*)?|```[^\n]*$)"#,
                                        with: "", options: .regularExpression)
        for marker in ["**", "__", "`"] { text = text.replacingOccurrences(of: marker, with: "") }
        return String(text.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(900))
    }

}
