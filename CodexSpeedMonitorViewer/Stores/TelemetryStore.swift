import Foundation
import SQLite3

let dbPath: String = {
    if let override = ProcessInfo.processInfo.environment["CODEX_TELEMETRY_DB"], !override.isEmpty {
        return override
    }
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    let defaultDir = support?.appendingPathComponent("CodexSpeedMonitor", isDirectory: true)
        ?? URL(fileURLWithPath: "\(NSHomeDirectory())/Library/Application Support/CodexSpeedMonitor", isDirectory: true)
    let configURL = defaultDir.appendingPathComponent("config.json")
    if let data = try? Data(contentsOf: configURL),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let configured = obj["db_path"] as? String,
       !configured.isEmpty {
        return configured
    }
    return defaultDir.appendingPathComponent("codex_telemetry.sqlite").path
}()

private struct TelemetryPayload {
    let snapshot: Snapshot
    let days: [MiniDay]
    let hours: [MiniDay]
    let modes: [ModeRow]
    let models: [ModelRow]
    let reasoning: [ReasoningRow]
    let recent: [RecentTurn]
}

private struct QuerySource {
    let usageTable: String
    let speedTable: String
    let cached: Bool
}

final class TelemetryStore: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var days: [MiniDay] = []
    @Published var hours: [MiniDay] = []
    @Published var modes: [ModeRow] = []
    @Published var models: [ModelRow] = []
    @Published var reasoning: [ReasoningRow] = []
    @Published var recent: [RecentTurn] = []
    @Published var refreshing = false

    private let queue = DispatchQueue(label: "codex.telemetry.viewer.store", qos: .utility)
    private var loading = false
    private var activeScope = "today"
    private var pendingScope: String?
    private var cache: [String: TelemetryPayload] = [:]
    private var lastLoadedAt: [String: Date] = [:]
    private let minimumRefreshInterval: TimeInterval = 45

    private let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()

    private let hourFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.timeZone = TimeZone.current
        return f
    }()

    init() {
        refresh(scope: "today", force: true)
    }

    func setScope(_ rawScope: String) {
        let scope = normalizedScope(rawScope)
        activeScope = scope
        if let payload = cache[scope] {
            apply(payload)
        }
        refresh(scope: scope)
    }

    func refresh(scope rawScope: String = "today", force: Bool = false) {
        let scope = normalizedScope(rawScope)
        activeScope = scope
        queue.async {
            if self.loading && !force {
                self.pendingScope = scope
                return
            }
            if !force, let last = self.lastLoadedAt[scope], Date().timeIntervalSince(last) < self.minimumRefreshInterval {
                return
            }
            self.loading = true
            DispatchQueue.main.async { self.refreshing = true }
            defer {
                self.loading = false
                DispatchQueue.main.async { self.refreshing = false }
            }

            var db: OpaquePointer?
            guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return }
            defer { sqlite3_close(db) }

            let payload = self.loadPayload(db, scope: scope)
            self.lastLoadedAt[scope] = Date()

            DispatchQueue.main.async {
                self.cache[scope] = payload
                if let active = self.cache[self.activeScope] {
                    self.apply(active)
                }
            }

            if let pending = self.pendingScope, pending != scope {
                self.pendingScope = nil
                self.refresh(scope: pending, force: true)
            } else {
                self.pendingScope = nil
            }
        }
    }

    private func loadPayload(_ db: OpaquePointer?, scope: String) -> TelemetryPayload {
        let source = querySource(db)
        let nextSnapshot = loadSnapshot(db, source: source, scope: scope)
        let cutoff = nextSnapshot.cutover
        return TelemetryPayload(
            snapshot: nextSnapshot,
            days: loadDays(db, source: source, cutoff: cutoff, scope: scope),
            hours: loadHours(db, source: source, cutoff: cutoff, scope: scope),
            modes: loadModes(db, source: source, cutoff: cutoff, scope: scope),
            models: loadModels(db, source: source, cutoff: cutoff, scope: scope),
            reasoning: loadReasoning(db, source: source, cutoff: cutoff, scope: scope),
            recent: loadRecent(db, source: source, cutoff: cutoff, scope: scope)
        )
    }

    private func apply(_ payload: TelemetryPayload) {
        snapshot = payload.snapshot
        days = payload.days
        hours = payload.hours
        modes = payload.modes
        models = payload.models
        reasoning = payload.reasoning
        recent = payload.recent
    }

    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: c)
    }

    private func querySource(_ db: OpaquePointer?) -> QuerySource {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "select 1 from sqlite_master where type='table' and name='trusted_turn_cache' limit 1", -1, &stmt, nil) == SQLITE_OK {
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) == SQLITE_ROW {
                return QuerySource(usageTable: "trusted_turn_cache", speedTable: "trusted_turn_cache", cached: true)
            }
        } else {
            sqlite3_finalize(stmt)
        }
        return QuerySource(usageTable: "trusted_codex_turns", speedTable: "trusted_codex_speed_turns", cached: false)
    }

    private func cutoff(_ db: OpaquePointer?) -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select value from capture_state where key='trusted_cutover_at' limit 1", -1, &stmt, nil) == SQLITE_OK else { return "1970-01-01T00:00:00Z" }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? text(stmt, 0) : "1970-01-01T00:00:00Z"
    }

    private func normalizedScope(_ scope: String) -> String {
        if scope == "7d" || scope == "14d" { return scope }
        return "today"
    }

    private func rangePredicate(_ scope: String) -> String {
        switch normalizedScope(scope) {
        case "7d":
            return "julianday(completed_at) >= julianday('now', '-7 days')"
        case "14d":
            return "julianday(completed_at) >= julianday('now', '-14 days')"
        default:
            return "date(completed_at, 'localtime') = date('now', 'localtime')"
        }
    }

    private func trustedPredicate(cutover: String, scope: String) -> String {
        "completed_at is not null and \(rangePredicate(scope))"
    }

    private func speedPredicate(source: QuerySource, scope: String) -> String {
        if source.cached {
            return "speed_eligible = 1 and completed_at is not null and \(rangePredicate(scope))"
        }
        return "completed_at is not null and \(rangePredicate(scope))"
    }

    private func modeSQL() -> String {
        """
        case
          when lower(coalesce(service_tier_served,'')) in ('fast','priority') then 'fast'
          when lower(coalesce(service_tier_requested,'')) in ('fast','priority') then 'fast'
          when lower(coalesce(service_tier_served, service_tier_requested, mode, '')) = 'auto' then 'auto'
          when lower(coalesce(mode,'')) = 'default' then 'standard'
          when coalesce(mode,'') = '' then 'unknown'
          else lower(mode)
        end
        """
    }

    private func laneSQL(source: QuerySource) -> String {
        if source.cached { return "lane" }
        return """
        case
          when lower(\(modeSQL())) like '%fast%' then 'Fast'
          when lower(\(modeSQL())) = 'standard' then 'Standard'
          else 'Other'
        end
        """
    }

    private func speedBucketSQL(scope: String) -> String {
        if normalizedScope(scope) == "today" {
            return """
            strftime('%Y-%m-%d %H:', completed_at, 'localtime') ||
            printf('%02d', (cast(strftime('%M', completed_at, 'localtime') as integer) / 5) * 5)
            """
        }
        return "strftime('%Y-%m-%d %H:00', completed_at, 'localtime')"
    }

    private func loadSnapshot(_ db: OpaquePointer?, source: QuerySource, scope: String) -> Snapshot {
        var s = Snapshot()
        s.cutover = cutoff(db)
        var stmt: OpaquePointer?
        let trusted = trustedPredicate(cutover: s.cutover, scope: scope)
        let speedTrusted = speedPredicate(source: source, scope: scope)

        let summarySQL = """
        select
          (select count(*) from \(source.usageTable) where \(trusted)),
          (select coalesce(sum(total_tokens),0) from \(source.usageTable) where \(trusted)),
          (select coalesce(avg(output_tokens_per_second),0) from \(source.speedTable) where \(speedTrusted))
        """
        if sqlite3_prepare_v2(db, summarySQL, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            s.todayTurns = Int(sqlite3_column_int(stmt, 0))
            s.todayTokens = sqlite3_column_int64(stmt, 1)
            s.todayTPS = sqlite3_column_double(stmt, 2)
            s.trustedTurns = s.todayTurns
        }
        sqlite3_finalize(stmt)

        let latestSQL = """
        select coalesce(model,'-'), \(modeSQL()), coalesce(output_tokens_per_second,0)
        from \(source.speedTable)
        where \(speedTrusted)
        order by completed_at desc
        limit 1
        """
        if sqlite3_prepare_v2(db, latestSQL, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            s.latestModel = text(stmt, 0)
            s.latestMode = text(stmt, 1)
            s.latestTPS = sqlite3_column_double(stmt, 2)
        }
        sqlite3_finalize(stmt)

        let hbSQL = "select ts from daemon_heartbeats order by id desc limit 1"
        if sqlite3_prepare_v2(db, hbSQL, -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW {
            if let date = parseISO(text(stmt, 0)) {
                s.heartbeatAge = Date().timeIntervalSince(date)
                s.live = s.heartbeatAge < 90
            }
        }
        sqlite3_finalize(stmt)
        return s
    }

    private func loadHours(_ db: OpaquePointer?, source: QuerySource, cutoff: String, scope: String) -> [MiniDay] {
        let trusted = speedPredicate(source: source, scope: scope)
        let bucket = source.cached ? (normalizedScope(scope) == "today" ? "five_min_bucket" : "hour_bucket") : speedBucketSQL(scope: scope)
        let sql = """
        with turns as (
          select \(bucket) as bucket,
                 \(laneSQL(source: source)) as lane,
                 output_tokens_per_second,
                 total_tokens
          from \(source.speedTable)
          where \(trusted)
        )
        select bucket, lane, coalesce(avg(output_tokens_per_second),0), coalesce(sum(total_tokens),0)
        from turns
        where lane in ('Fast', 'Standard')
        group by 1, 2
        order by 1, 2
        """
        return loadSeries(db, sql: sql, formatter: hourFormatter)
    }

    private func loadDays(_ db: OpaquePointer?, source: QuerySource, cutoff: String, scope: String) -> [MiniDay] {
        let trusted = speedPredicate(source: source, scope: scope)
        let bucket = source.cached ? "day_bucket" : "date(completed_at, 'localtime')"
        let sql = """
        with turns as (
          select \(bucket) as bucket,
                 \(laneSQL(source: source)) as lane,
                 output_tokens_per_second,
                 total_tokens
          from \(source.speedTable)
          where \(trusted)
        )
        select bucket, lane, coalesce(avg(output_tokens_per_second),0), coalesce(sum(total_tokens),0)
        from turns
        where lane in ('Fast', 'Standard')
        group by 1, 2
        order by 1, 2
        """
        return loadSeries(db, sql: sql, formatter: dayFormatter)
    }

    private func loadSeries(_ db: OpaquePointer?, sql: String, formatter: DateFormatter) -> [MiniDay] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [MiniDay] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let date = formatter.date(from: text(stmt, 0)) else { continue }
            rows.append(MiniDay(date: date, lane: text(stmt, 1), tps: sqlite3_column_double(stmt, 2), tokens: sqlite3_column_double(stmt, 3)))
        }
        return rows
    }

    private func loadModes(_ db: OpaquePointer?, source: QuerySource, cutoff: String, scope: String) -> [ModeRow] {
        let trusted = trustedPredicate(cutover: cutoff, scope: scope)
        let speedTrusted = speedPredicate(source: source, scope: scope)
        let sql = """
        with usage as (
          select \(modeSQL()) as mode, coalesce(sum(total_tokens),0) as tokens, count(*) as turns
          from \(source.usageTable)
          where \(trusted)
          group by 1
        ),
        speed as (
          select \(modeSQL()) as mode, coalesce(avg(output_tokens_per_second),0) as tps
          from \(source.speedTable)
          where \(speedTrusted)
          group by 1
        )
        select usage.mode, usage.tokens, usage.turns, coalesce(speed.tps,0)
        from usage left join speed using(mode)
        order by usage.tokens desc
        limit 4
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [ModeRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(ModeRow(name: text(stmt, 0), tokens: sqlite3_column_int64(stmt, 1), turns: Int(sqlite3_column_int(stmt, 2)), tps: sqlite3_column_double(stmt, 3)))
        }
        return rows
    }

    private func loadModels(_ db: OpaquePointer?, source: QuerySource, cutoff: String, scope: String) -> [ModelRow] {
        let trusted = trustedPredicate(cutover: cutoff, scope: scope)
        let sql = """
        with usage as (
          select coalesce(model,'unknown') as model, \(modeSQL()) as mode, coalesce(reasoning_effort,'unspecified') as reasoning, coalesce(sum(total_tokens),0) as tokens, count(*) as turns
          from \(source.usageTable)
          where \(trusted)
          group by 1, 2, 3
        ),
        speed as (
          select coalesce(model,'unknown') as model, \(modeSQL()) as mode, coalesce(reasoning_effort,'unspecified') as reasoning, coalesce(avg(output_tokens_per_second),0) as tps
          from \(source.speedTable)
          where \(speedPredicate(source: source, scope: scope))
          group by 1, 2, 3
        )
        select usage.model, usage.mode, usage.reasoning, usage.tokens, usage.turns, coalesce(speed.tps,0)
        from usage left join speed using(model, mode, reasoning)
        order by usage.tokens desc
        limit 10
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [ModelRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(ModelRow(model: text(stmt, 0), mode: text(stmt, 1), reasoning: text(stmt, 2), tokens: sqlite3_column_int64(stmt, 3), turns: Int(sqlite3_column_int(stmt, 4)), tps: sqlite3_column_double(stmt, 5)))
        }
        return rows
    }

    private func loadReasoning(_ db: OpaquePointer?, source: QuerySource, cutoff: String, scope: String) -> [ReasoningRow] {
        let trusted = trustedPredicate(cutover: cutoff, scope: scope)
        let sql = """
        with usage as (
          select coalesce(reasoning_effort,'unspecified') as level, coalesce(sum(total_tokens),0) as tokens, count(*) as turns
          from \(source.usageTable)
          where \(trusted)
          group by 1
        ),
        speed as (
          select coalesce(reasoning_effort,'unspecified') as level, coalesce(avg(output_tokens_per_second),0) as tps
          from \(source.speedTable)
          where \(speedPredicate(source: source, scope: scope))
          group by 1
        )
        select usage.level, usage.tokens, usage.turns, coalesce(speed.tps,0)
        from usage left join speed using(level)
        order by usage.tokens desc
        limit 6
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [ReasoningRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(ReasoningRow(level: text(stmt, 0), tokens: sqlite3_column_int64(stmt, 1), turns: Int(sqlite3_column_int(stmt, 2)), tps: sqlite3_column_double(stmt, 3)))
        }
        return rows
    }

    private func loadRecent(_ db: OpaquePointer?, source: QuerySource, cutoff: String, scope: String) -> [RecentTurn] {
        let trusted = speedPredicate(source: source, scope: scope)
        let sql = """
        select coalesce(completed_at,''), coalesce(model,'unknown'), \(modeSQL()), coalesce(reasoning_effort,'unspecified'), coalesce(total_tokens,0), coalesce(output_tokens_per_second,0)
        from \(source.speedTable)
        where \(trusted)
        order by completed_at desc
        limit 60
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [RecentTurn] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(RecentTurn(completedAt: text(stmt, 0), model: text(stmt, 1), mode: text(stmt, 2), reasoning: text(stmt, 3), tokens: sqlite3_column_int64(stmt, 4), tps: sqlite3_column_double(stmt, 5)))
        }
        return rows
    }

    func exportTrustedCSV(to url: URL, scope rawScope: String = "today") throws {
        let scope = normalizedScope(rawScope)
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        let cutoffValue = cutoff(db)
        let trusted = trustedPredicate(cutover: cutoffValue, scope: scope)
        let sql = """
        select completed_at,
               surface,
               coalesce(model,''),
               \(modeSQL()),
               coalesce(service_tier_requested,''),
               coalesce(service_tier_served,''),
               coalesce(reasoning_effort,'unspecified'),
               coalesce(input_tokens,0),
               coalesce(cached_input_tokens,0),
               coalesce(output_tokens,0),
               coalesce(reasoning_tokens,0),
               coalesce(total_tokens,0),
               output_tokens_per_second,
               non_reasoning_tokens_per_second,
               duration_ms,
               case when source='app_response' then 'api_created_completed_seconds'
                    when source='otel_trace' then 'otel_span_nanos'
                    else source end,
               case when output_tokens_per_second is not null
                      and output_tokens_per_second >= 0
                      and source = 'app_response'
                      and duration_ms is not null
                      and duration_ms >= 5000
                      and output_tokens is not null
                      and output_tokens >= 100
                      and not exists (
                        select 1
                        from json_each(case when json_valid(raw_json) then raw_json else '{"response":{"tool_usage":{}}}' end, '$.response.tool_usage') tool
                        where coalesce(json_extract(tool.value, '$.total_tokens'), 0) > 0
                           or coalesce(json_extract(tool.value, '$.input_tokens'), 0) > 0
                           or coalesce(json_extract(tool.value, '$.output_tokens'), 0) > 0
                           or coalesce(json_extract(tool.value, '$.input_tokens_details.image_tokens'), 0) > 0
                           or coalesce(json_extract(tool.value, '$.input_tokens_details.text_tokens'), 0) > 0
                           or coalesce(json_extract(tool.value, '$.output_tokens_details.image_tokens'), 0) > 0
                           or coalesce(json_extract(tool.value, '$.output_tokens_details.text_tokens'), 0) > 0
                           or coalesce(json_extract(tool.value, '$.num_requests'), 0) > 0
                      )
                    then 1 else 0 end,
               coalesce(thread_id,'')
        from trusted_codex_turns
        where \(trusted)
        order by completed_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        var lines = ["completed_at,surface,model,mode,service_tier_requested,service_tier_served,reasoning_effort,input_tokens,cached_input_tokens,output_tokens,reasoning_tokens,total_tokens,output_tokens_per_second,non_reasoning_tokens_per_second,duration_ms,timing_source,speed_eligible,thread_id"]
        while sqlite3_step(stmt) == SQLITE_ROW {
            var cols: [String] = []
            for i in 0..<18 { cols.append(csv(text(stmt, Int32(i)))) }
            lines.append(cols.joined(separator: ","))
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func csv(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
