import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ReportView: View {
    @ObservedObject var store: TelemetryStore
    @AppStorage("telemetryTimeScope") private var timeScope = "today"
    @State private var exportMessage = ""
    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var rangePoints: [MiniDay] {
        if timeScope == "today" {
            return store.hours
        }
        return store.days
    }

    var body: some View {
        ZStack {
            reportBackground.ignoresSafeArea()
            VStack(spacing: 16) {
                ReportHeader(store: store, scope: $timeScope, exportMessage: exportMessage) { exportCSV() }
                HStack(spacing: 14) {
                    ReportRangeSummary(snapshot: store.snapshot, scope: timeScope)
                    ReportModeSummary(modes: store.modes)
                }
                ReportPanel(title: "Speed over time", subtitle: scopeSubtitle(timeScope)) {
                    ReportLegend()
                    ReportChart(points: rangePoints, scope: timeScope)
                        .frame(height: 230)
                }
                HStack(spacing: 14) {
                    ReportPanel(title: "Reasoning", subtitle: "effort levels") {
                        ReportReasoningRows(reasoning: store.reasoning)
                    }
                    ReportPanel(title: "Models", subtitle: scopeSubtitle(timeScope)) {
                        ReportModelRows(models: store.models)
                    }
                    ReportPanel(title: "Recent", subtitle: scopeSubtitle(timeScope)) {
                        ReportRecentRows(recent: store.recent)
                    }
                }
                .frame(height: 230)
            }
            .padding(22)
        }
        .frame(minWidth: 1000, minHeight: 700)
        .onAppear { store.setScope(timeScope) }
        .onChange(of: timeScope) { store.setScope(timeScope) }
        .onReceive(timer) { _ in store.refresh(scope: timeScope) }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.title = "Export telemetry"
        panel.nameFieldStringValue = "codex-trusted-responses-\(timeScope).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try store.exportTrustedCSV(to: url, scope: timeScope)
                exportMessage = "Exported"
            } catch {
                exportMessage = "Export failed"
            }
        }
    }
}

let reportBackground = LinearGradient(
    colors: [Color(red: 0.020, green: 0.022, blue: 0.026), Color(red: 0.050, green: 0.049, blue: 0.058)],
    startPoint: .topLeading,
    endPoint: .bottomTrailing
)

struct ReportHeader: View {
    @ObservedObject var store: TelemetryStore
    @Binding var scope: String
    let exportMessage: String
    let export: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Token Speed Report")
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.94))
                Text("trusted responses · \(store.snapshot.trustedTurns) · \(scopeSubtitle(scope))")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }
            Spacer(minLength: 18)
            ScopeControl(scope: $scope)
                .frame(width: 220)
            if !exportMessage.isEmpty {
                Text(exportMessage)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.52))
                    .lineLimit(1)
            }
            ReportHeaderButton(title: "Refresh", symbol: "arrow.clockwise") { store.refresh(scope: scope) }
            ReportHeaderButton(title: "Export", symbol: "square.and.arrow.down", prominent: true, action: export)
        }
    }
}

struct ReportHeaderButton: View {
    let title: String
    let symbol: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .padding(.vertical, 7)
                .padding(.horizontal, 10)
                .foregroundStyle(prominent ? .black.opacity(0.88) : .white.opacity(0.78))
                .background(prominent ? .white.opacity(0.88) : .white.opacity(0.09), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct ReportRangeSummary: View {
    let snapshot: Snapshot
    let scope: String

    var body: some View {
        HStack(alignment: .bottom, spacing: 22) {
            VStack(alignment: .leading, spacing: 7) {
                Text(scopeTitle(scope).uppercased())
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.34))
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(compact(snapshot.todayTokens))
                        .font(.system(size: 42, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Text("tokens")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.36))
                        .padding(.bottom, 7)
                }
            }
            Spacer()
            ReportSmallStat(label: "responses", value: "\(snapshot.todayTurns)")
            ReportSmallStat(label: "avg speed", value: String(format: "%.1f t/s", snapshot.todayTPS))
            ReportSmallStat(label: "capture", value: snapshot.live ? "Live" : "Stale", tone: snapshot.live ? fastTone : mutedTone)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.075)))
    }
}

struct ReportSmallStat: View {
    let label: String
    let value: String
    var tone: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.30))
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(tone.opacity(0.88))
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(width: 88, alignment: .leading)
    }
}

struct ReportModeSummary: View {
    let modes: [ModeRow]
    var fastRows: [ModeRow] { modes.filter { $0.name.lowercased().contains("fast") } }
    var standardRows: [ModeRow] { modes.filter { $0.name.lowercased().contains("standard") || $0.name.lowercased().contains("default") } }
    var maxTPS: Double { max(weightedAverage(rows: fastRows), weightedAverage(rows: standardRows), 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("MODE SPEED")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.34))
                Spacer()
                Text(modeDelta(fast: weightedAverage(rows: fastRows), standard: weightedAverage(rows: standardRows)))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.38))
                    .lineLimit(1)
            }
            ModeSpeedRow(title: "Fast", rows: fastRows, accent: fastTone, maxTPS: maxTPS)
            ModeSpeedRow(title: "Standard", rows: standardRows, accent: standardTone, maxTPS: maxTPS)
        }
        .padding(16)
        .frame(width: 355, alignment: .topLeading)
        .frame(minHeight: 118, alignment: .topLeading)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.075)))
    }
}

struct ReportPanel<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.90))
                Spacer()
                Text(subtitle.uppercased())
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.30))
                    .lineLimit(1)
            }
            content
        }
        .padding(16)
        .background(.white.opacity(0.046), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.065)))
    }
}

struct ReportLegend: View {
    var body: some View {
        HStack(spacing: 14) {
            Legend(label: "Fast", tone: fastTone, dash: false)
            Legend(label: "Standard", tone: standardTone, dash: true)
            Spacer()
        }
    }
}

struct ReportChart: View {
    let points: [MiniDay]
    let scope: String
    var grouped: [(String, [MiniDay])] {
        Dictionary(grouping: points, by: { $0.lane })
            .map { ($0.key, $0.value.sorted { $0.date < $1.date }) }
            .sorted { laneRank($0.0) < laneRank($1.0) }
    }

    var body: some View {
        Canvas { context, size in
            guard !points.isEmpty else {
                context.draw(Text("waiting for data").font(.caption).foregroundStyle(.white.opacity(0.35)), at: CGPoint(x: size.width / 2, y: size.height / 2))
                return
            }
            let dates = points.map(\.date).sorted()
            let rawMinDate = dates.first ?? Date()
            let rawMaxDate = dates.last ?? rawMinDate
            let span = rawMaxDate.timeIntervalSince(rawMinDate)
            let minWindow = scope == "today" ? 3600.0 : 86400.0
            let pad = scope == "today" ? 300.0 : 43200.0
            let minDate = scope == "today" && span < minWindow ? rawMaxDate.addingTimeInterval(-minWindow) : rawMinDate.addingTimeInterval(-pad)
            let maxDate = scope == "today" && span < minWindow ? rawMaxDate.addingTimeInterval(pad) : rawMaxDate.addingTimeInterval(pad)
            let maxY = niceCeiling(max(points.map(\.tps).max() ?? 1, 1) * 1.08)
            let plot = CGRect(x: 12, y: 12, width: size.width - 24, height: size.height - 36)
            var grid = Path()
            for i in 0...3 {
                let y = plot.maxY - plot.height * CGFloat(i) / 3
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
            }
            context.stroke(grid, with: .color(.white.opacity(0.075)), lineWidth: 1)
            func x(_ date: Date) -> CGFloat {
                let xSpan = max(maxDate.timeIntervalSince(minDate), minWindow)
                return plot.minX + plot.width * CGFloat(date.timeIntervalSince(minDate) / xSpan)
            }
            func y(_ value: Double) -> CGFloat { plot.maxY - plot.height * CGFloat(value / maxY) }
            for (lane, rows) in grouped {
                if rows.count >= 2 {
                    var path = Path()
                    for (index, row) in rows.enumerated() {
                        let point = CGPoint(x: x(row.date), y: y(row.tps))
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                    let isFast = lane.lowercased().contains("fast")
                    context.stroke(path, with: .color(tone(for: lane)), style: StrokeStyle(lineWidth: isFast ? 3.0 : 2.0, lineCap: .round, lineJoin: .round, dash: isFast ? [] : [5, 5]))
                }
                let dots = rows.count <= 5 ? rows : Array(rows.suffix(3))
                for row in dots {
                    let point = CGPoint(x: x(row.date), y: y(row.tps))
                    context.fill(Path(ellipseIn: CGRect(x: point.x - 2.8, y: point.y - 2.8, width: 5.6, height: 5.6)), with: .color(tone(for: lane)))
                }
            }
            context.draw(Text(String(format: "%.0f t/s", maxY)).font(.caption2).foregroundStyle(.white.opacity(0.30)), at: CGPoint(x: plot.maxX, y: plot.minY), anchor: .trailing)
            let leftLabel = scope == "today" ? shortTime(minDate) : shortAxis(minDate)
            let rightLabel = scope == "today" ? shortTime(maxDate) : shortAxis(maxDate)
            context.draw(Text(leftLabel).font(.caption2).foregroundStyle(.white.opacity(0.32)), at: CGPoint(x: plot.minX, y: size.height - 8), anchor: .leading)
            context.draw(Text(rightLabel).font(.caption2).foregroundStyle(.white.opacity(0.32)), at: CGPoint(x: plot.maxX, y: size.height - 8), anchor: .trailing)
        }
    }
}

struct ReportReasoningRows: View {
    let reasoning: [ReasoningRow]
    var body: some View {
        VStack(spacing: 10) {
            ForEach(reasoning) { row in
                ReportRow(left: cleanReasoning(row.level), mid: "\(row.turns) resp · \(compact(row.tokens))", right: String(format: "%.1f t/s", row.tps), tone: reasoningTone(row.level))
            }
            Spacer(minLength: 0)
        }
    }
}

struct ReportModelRows: View {
    let models: [ModelRow]
    var body: some View {
        VStack(spacing: 10) {
            ForEach(models.prefix(7)) { model in
                ReportRow(left: cleanModel(model.model), mid: "\(cleanMode(model.mode)) · \(cleanReasoning(model.reasoning))", right: compact(model.tokens), tone: tone(for: model.mode))
            }
            Spacer(minLength: 0)
        }
    }
}

struct ReportRecentRows: View {
    let recent: [RecentTurn]
    var body: some View {
        VStack(spacing: 10) {
            ForEach(recent.prefix(7)) { turn in
                ReportRow(left: compactDate(turn.completedAt), mid: "\(cleanMode(turn.mode)) · \(cleanReasoning(turn.reasoning))", right: String(format: "%.1f t/s", turn.tps), tone: tone(for: turn.mode))
            }
            Spacer(minLength: 0)
        }
    }
}

struct ReportRow: View {
    let left: String
    let mid: String
    let right: String
    let tone: Color

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(tone.opacity(0.86))
                .frame(width: 6, height: 6)
            Text(left)
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(mid)
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(1)
            Text(right)
                .foregroundStyle(.white.opacity(0.68))
                .monospacedDigit()
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
    }
}

func compactDate(_ raw: String) -> String {
    guard let date = parseISO(raw) else { return raw }
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "MM-dd HH:mm"
    return f.string(from: date)
}

func cleanMode(_ raw: String) -> String {
    let lower = raw.lowercased()
    if lower.contains("fast") { return "Fast" }
    if lower.contains("standard") { return "Standard" }
    return raw.capitalized
}

func cleanReasoning(_ raw: String) -> String {
    let lower = raw.lowercased()
    if lower.isEmpty || lower == "unspecified" || lower == "unknown" { return "unspecified" }
    if lower == "xhigh" { return "xhigh" }
    return lower
}

func reasoningTone(_ raw: String) -> Color {
    switch raw.lowercased() {
    case "xhigh": return fastTone
    case "high": return Color(red: 0.86, green: 0.80, blue: 1.00)
    case "medium": return standardTone
    case "low": return mutedTone
    default: return Color.white.opacity(0.34)
    }
}

func cleanModel(_ raw: String) -> String {
    raw.replacingOccurrences(of: "-2026-03-17", with: "")
}

func modeDelta(fast: Double, standard: Double) -> String {
    guard fast > 0, standard > 0 else { return "waiting" }
    if fast >= standard { return String(format: "Fast +%.1f t/s", fast - standard) }
    return String(format: "Standard +%.1f t/s", standard - fast)
}
