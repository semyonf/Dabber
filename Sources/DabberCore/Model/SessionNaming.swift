import Foundation

public enum SessionNaming {
    public static let titleLimit = 80

    public static func sessionName(_ date: Date, title: String, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH-mm"
        let clean = sanitize(title)
        return clean.isEmpty ? f.string(from: date) : f.string(from: date) + " " + clean
    }

    public static func sanitize(_ title: String) -> String {
        let scalars = title.unicodeScalars.filter { $0.properties.generalCategory != .control }
        let flat = String(String.UnicodeScalarView(scalars))
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let head = flat.drop { $0 == "." || $0.isWhitespace }
        return String(head.prefix(titleLimit)).trimmingCharacters(in: .whitespaces)
    }

    public static func trackBase(kind: SourceKind, name: String, taken: [String]) -> String {
        let base: String
        switch kind {
        case .computer: base = "computer audio"
        case .mic: base = "mic - " + String(name.map { "/:\\".contains($0) ? Character("-") : $0 })
        }
        var candidate = base
        var n = 2
        while taken.contains(candidate) {
            candidate = "\(base) \(n)"
            n += 1
        }
        return candidate
    }

    public static func segmentFile(base: String, index: Int) -> String {
        base + ".seg" + String(format: "%03d", index) + ".caf"
    }
}
