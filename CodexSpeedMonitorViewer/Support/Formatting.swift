import SwiftUI

let widgetBackground = Color(red: 0.018, green: 0.019, blue: 0.022)
let subtleStroke = Color.white.opacity(0.10)
let fastTone = Color(red: 0.48, green: 0.78, blue: 1.00)
let standardTone = Color(red: 0.86, green: 0.68, blue: 0.50)
let mutedTone = Color.white.opacity(0.38)

func tone(for lane: String) -> Color {
    let l = lane.lowercased()
    if l.contains("fast") { return fastTone }
    if l.contains("standard") { return standardTone }
    return mutedTone
}

func compact(_ value: Int64) -> String {
    let n = Double(value)
    if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fk", n / 1_000) }
    return "\(value)"
}

func parseISO(_ raw: String) -> Date? {
    ISO8601DateFormatter.fractional.date(from: raw) ?? ISO8601DateFormatter.basic.date(from: raw)
}

extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let basic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

func scopeTitle(_ scope: String) -> String {
    switch scope {
    case "7d": return "7 Days"
    case "14d": return "14 Days"
    default: return "Today"
    }
}

func scopeSubtitle(_ scope: String) -> String {
    switch scope {
    case "7d": return "last 7 days"
    case "14d": return "last 14 days"
    default: return "today"
    }
}
