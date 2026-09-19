import SwiftUI
import Foundation

/// 展示层只读快照；历史归并、定价和日历归桶均由后台完成。
public struct StatsTabView: View {
    public let snapshot: UsageHistory.Snapshot
    public init(snapshot: UsageHistory.Snapshot) { self.snapshot = snapshot }

    private var hasRecords: Bool { snapshot.aggregate.turns > 0 }
    private var sources: [String] { ["Claude", "Codex"] + snapshot.totals.keys.filter { $0 != "Claude" && $0 != "Codex" }.sorted() }
    private var days: [Date] {
        let cal = Calendar.current, today = Calendar.current.startOfDay(for: Date())
        return (0..<42).map { cal.date(byAdding: .day, value: $0 - 41, to: today)! }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if snapshot.isScanning || snapshot.capturedAt == 0 {
                Text("正在汇总历史（已处理 \(snapshot.processedFiles)/\(snapshot.totalFiles) 个文件）…")
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
            if !snapshot.error.isEmpty {
                Text(snapshot.error).font(.system(size: 9)).foregroundColor(.orange).fixedSize(horizontal: false, vertical: true)
            }
            metrics
            heatmap
            distribution
            providers
            Text("总数与热力图只算 CLI 日志；经记账代理的 API 调用多半已在 CLI 日志里，单列不重复计入。会话数按不同日志文件计，思考包含在输出中。")
                .font(.system(size: 8)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if snapshot.cumulativeTurns > 0 {
                Text("\(snapshot.cumulativeTurns) 次旧格式 Codex 记录按累计差归桶（首条以 0 为基线），跨日精度受事件时间限制。")
                    .font(.system(size: 8)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if snapshot.skippedRecords > 0 {
                Text("\(snapshot.skippedRecords) 条记录缺少有效时间或用量，未计入。")
                    .font(.system(size: 8)).foregroundColor(.orange)
            }
        }
        .frame(width: 331, alignment: .leading)
    }

    private var metrics: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                metric("累计 token", hasRecords ? Fmt.tokens(snapshot.tokenTotal) : "未检测到", "输入（含缓存）+ 输出")
                metric("API 等价成本", costText(snapshot.cost), snapshot.hasPriceTable && snapshot.unpricedModels > 0 ? "部分模型未定价" : "仅按本地价目表计算")
                metric("活跃天数", hasRecords ? "\(snapshot.activeDays)" : "未检测到", "有 token 用量的日历日")
                metric("缓存命中率", snapshot.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) } ?? "查不到", "缓存读取 / 全部输入")
            }
            Text(snapshot.earliestDate.map { "自 \($0) 起统计" } ?? "尚无带有效时间与用量的本地记录")
                .font(.system(size: 8)).foregroundColor(.secondary)
        }
    }

    private func metric(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 9)).foregroundColor(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            Text(detail).font(.system(size: 8)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
        .background(Color.secondary.opacity(0.06)).cornerRadius(8)
    }

    private func costText(_ value: Double?) -> String {
        guard snapshot.hasPriceTable else { return "未配置价目表" }
        guard let value else { return "未定价" }
        return String(format: "%.2f %@", value, snapshot.priceCurrency)
    }

    private var heatmap: some View {
        let dates = days
        let keys = dates.map { UsageHistory.dayKey(timestamp: $0.timeIntervalSince1970) }
        let values = keys.map { snapshot.dailyTokens[$0] ?? 0 }
        let grades = UsageHistory.levels(values)
        return section("每日强度 · 近 42 天") {
            HStack(alignment: .top, spacing: 5) {
                VStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(weekday(dates[row])).font(.system(size: 8)).foregroundColor(.secondary).frame(width: 14, height: 14)
                    }
                }
                ForEach(0..<6, id: \.self) { column in
                    VStack(spacing: 4) {
                        ForEach(0..<7, id: \.self) { row in
                            let i = column * 7 + row
                            RoundedRectangle(cornerRadius: 3)
                                .fill(grades[i] == 0 ? Color.secondary.opacity(0.10) : Color.green.opacity(0.15 + Double(grades[i]) * 0.15))
                                .frame(maxWidth: .infinity).frame(height: 14)
                                .help("\(keys[i]) · \(values[i]) token")
                        }
                    }
                }
            }
            HStack {
                Text(maxDayText)
                Spacer()
                Text("少")
                ForEach(1...5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 1).fill(Color.green.opacity(0.15 + Double(level) * 0.15)).frame(width: 7, height: 7)
                }
                Text("多")
            }.font(.system(size: 8)).foregroundColor(.secondary)
        }
    }

    private var maxDayText: String {
        let visible = Set(days.map { UsageHistory.dayKey(timestamp: $0.timeIntervalSince1970) })
        guard let day = snapshot.dailyTokens.filter({ $0.value > 0 && visible.contains($0.key) }).sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).first else { return "最多的一天：未检测到" }
        let parts = day.key.split(separator: "-").compactMap { Int($0) }
        return parts.count == 3 ? "最多的一天：\(parts[1])月\(parts[2])日" : "最多的一天：\(day.key)"
    }
    private func weekday(_ date: Date) -> String {
        ["日", "一", "二", "三", "四", "五", "六"][Calendar.current.component(.weekday, from: date) - 1]
    }

    private var distribution: some View {
        let all = snapshot.aggregate
        let parts: [(String, Int64, Color)] = [("新输入", all.newInput, .blue), ("输出", all.out, .orange), ("缓存", all.cacheTotal, .green)]
        let total = max(1, all.newInput + all.out + all.cacheTotal)
        return section("token 分布") {
            GeometryReader { geo in
                HStack(spacing: 0) {
                    ForEach(parts, id: \.0) { part in
                        Rectangle().fill(part.2.opacity(0.8)).frame(width: geo.size.width * CGFloat(Double(part.1) / Double(total)))
                    }
                }.cornerRadius(3)
            }.frame(height: 7)
            ForEach(parts, id: \.0) { part in
                HStack(spacing: 4) {
                    Circle().fill(part.2).frame(width: 5, height: 5)
                    Text(part.0)
                    Spacer()
                    Text(hasRecords ? Fmt.tokens(part.1) : "未检测到")
                    if part.0 == "输出", all.think > 0 { Text("含思考 \(Fmt.tokens(all.think))") }
                }.font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
    }

    private var providers: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(sources, id: \.self) { source in
                if let totals = snapshot.totals[source] {
                    providerCard(source, totals)
                } else {
                    section(source) {
                        Text(snapshot.sourceNotes[source] ?? (snapshot.isScanning ? "正在汇总…" : "查不到：未检测到有效用量记录"))
                            .font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
            }
            section("Grok / Gemini") {
                Text("本地无 token 统计").font(.system(size: 9)).foregroundColor(.secondary)
            }
        }
    }

    private func providerCard(_ source: String, _ totals: UsageHistory.Totals) -> some View {
        let ratio = snapshot.tokenTotal > 0 ? Double(totals.tokenTotal) / Double(snapshot.tokenTotal) : 0
        return section(source) {
            HStack {
                Text("\(Fmt.tokens(totals.tokenTotal)) token").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(UsageHistory.isProxySource(source) ? "不计入总数" : String(format: "%.1f%%", ratio * 100))
                    .font(.system(size: 9)).foregroundColor(.secondary)
            }
            HStack {
                Text("\(totals.sessions) 会话 · \(totals.turns) 请求")
                Spacer()
                Text(costText(snapshot.costBySource[source]))
            }.font(.system(size: 9)).foregroundColor(.secondary)
            if snapshot.hasPriceTable, snapshot.unpricedBySource[source, default: 0] > 0 {
                Text("部分模型未定价").font(.system(size: 8)).foregroundColor(.orange)
            }
            if let note = snapshot.sourceNotes[source] { Text(note).font(.system(size: 8)).foregroundColor(.secondary) }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.12))
                    RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.65)).frame(width: geo.size.width * ratio)
                }
            }.frame(height: 4)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .bold)).foregroundColor(.secondary)
            content()
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06)).cornerRadius(8)
    }
}
