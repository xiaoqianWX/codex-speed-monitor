import Foundation

struct MiniDay: Identifiable {
    let id = UUID()
    let date: Date
    let lane: String
    let tps: Double
    let tokens: Double
}

struct ModeRow: Identifiable {
    let id = UUID()
    let name: String
    let tokens: Int64
    let turns: Int
    let tps: Double
}

struct ModelRow: Identifiable {
    let id = UUID()
    let model: String
    let mode: String
    let reasoning: String
    let tokens: Int64
    let turns: Int
    let tps: Double
}

struct ReasoningRow: Identifiable {
    let id = UUID()
    let level: String
    let tokens: Int64
    let turns: Int
    let tps: Double
}

struct RecentTurn: Identifiable {
    let id = UUID()
    let completedAt: String
    let model: String
    let mode: String
    let reasoning: String
    let tokens: Int64
    let tps: Double
}

struct Snapshot {
    var live = false
    var heartbeatAge: Double = 999999
    var todayTokens: Int64 = 0
    var todayTurns = 0
    var todayTPS: Double = 0
    var latestModel = "-"
    var latestMode = "-"
    var latestTPS: Double = 0
    var trustedTurns = 0
    var cutover = ""
}
