import Cocoa
import SwiftUI
import os

struct MiniProgressBar: View {
    var value: Double
    var color: Color = .green
    var width: CGFloat = 16
    var height: CGFloat = 3.5

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: height / 2)
                .fill(Color.secondary.opacity(0.22))
                .frame(width: width, height: height)

            let safeRatio = max(0.02, min(1.0, value))
            RoundedRectangle(cornerRadius: height / 2)
                .fill(color)
                .frame(width: max(1.5, width * CGFloat(safeRatio)), height: height)
        }
    }
}

/// 承接滚动的容器。**必须放在这一层**：macOS 只把滚动事件派给光标下最深的可滚动视图，
/// SwiftUI 的 ScrollView 会吞掉它，挂在外层 NSHostingView 上收不到。
/// 横向为主 → 切 Tab 并吞事件；其余交给正常纵向滚动。
final class SwipeScrollView: NSScrollView {
    var onSwipe: ((Int) -> Void)?
    private let log = Logger(subsystem: "com.haifeng.vibegauge", category: "swipe")
    private var accum: CGFloat = 0
    private var lastAt: TimeInterval = 0
    private var armed = true          // 一次物理手势只允许触发一次（否则一次滑动会连跳两步）

    override func scrollWheel(with e: NSEvent) {
        let dx = e.scrollingDeltaX      // AppKit 已按用户的「自然滚动」设置给过方向，别再取反
        let dy = e.scrollingDeltaY
        let hasPhase = e.phase != [] || e.momentumPhase != []
        if e.phase == .began { accum = 0; armed = true }

        guard abs(dx) > abs(dy) * 1.5 else {
            accum = 0
            super.scrollWheel(with: e)
            return
        }
        guard e.momentumPhase == [] else { return }          // 惯性阶段只吞掉
        if hasPhase && !armed { return }                     // 本次手势已触发过，剩下的事件全吞掉

        accum += dx
        let threshold: CGFloat = e.hasPreciseScrollingDeltas ? 45 : 3
        let now = Date().timeIntervalSince1970
        if abs(accum) >= threshold, now - lastAt > 0.25 {
            let step = accum < 0 ? 1 : -1                    // 向左滑 = 下一步；向右滑 = 上一步/返回
            log.debug("swipe accum=\(self.accum) step=\(step) phase=\(e.phase.rawValue)")
            accum = 0
            lastAt = now
            if hasPhase { armed = false }
            onSwipe?(step)
        }
    }
}

struct SwipeScroll<Content: View>: NSViewRepresentable {
    let content: Content
    let onSwipe: (Int) -> Void
    let onHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> SwipeScrollView {
        let sv = SwipeScrollView()
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.onSwipe = onSwipe
        let host = NSHostingView(rootView: content)
        host.translatesAutoresizingMaskIntoConstraints = false
        sv.documentView = host
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: sv.contentView.topAnchor),
            host.leadingAnchor.constraint(equalTo: sv.contentView.leadingAnchor),
            host.widthAnchor.constraint(equalTo: sv.contentView.widthAnchor)
        ])
        return sv
    }

    func updateNSView(_ sv: SwipeScrollView, context: Context) {
        sv.onSwipe = onSwipe
        if let host = sv.documentView as? NSHostingView<Content> {
            host.rootView = content
            let h = host.fittingSize.height
            DispatchQueue.main.async { onHeight(h) }          // 内容高度回传，外层据此定高
        }
    }
}

/// 面板能触发的动作（由 AppDelegate 注入；SwiftUI 视图自己关不了菜单，需要关的由闭包里 cancelTracking）
public struct PanelActions {
    public var cleanOrphans: () -> Void = {}
    public var cleanNPX: () -> Void = {}
    public var rescan: () -> Void = {}
    public var setAutoClean: (Bool) -> Void = { _ in }
    public var setLaunchAtLogin: (Bool) -> Void = { _ in }
    public var setThresholdNotify: (Bool) -> Void = { _ in }
    public var installProxy: () -> Void = {}
    public var uninstallProxy: () -> Void = {}
    public var copyProxyPrefix: () -> Void = {}
    public var purgeLogs: () -> Void = {}
    /// Tab 切换后内容高度变了 → 让宿主按新 fittingSize 重排
    public var relayout: () -> Void = {}
    public init() {}
}

public struct PanelSettings {
    public var autoClean: Bool = false
    public var launchAtLogin: Bool = false
    public var thresholdNotify: Bool = true
    public init(autoClean: Bool = false, launchAtLogin: Bool = false, thresholdNotify: Bool = true) {
        self.autoClean = autoClean
        self.launchAtLogin = launchAtLogin
        self.thresholdNotify = thresholdNotify
    }
}

/// 菜单里的面板：顶部 Tab 切换（订阅 / API / 系统），高度随当前 Tab 内容自适应（实测 macOS 14 NSMenu 会跟着
/// 自定义视图的 frame 实时重排），只有超过屏幕可用高度才在内部滚动。
public struct DashboardView: View {
    public var report: ScanReport
    public var actions: PanelActions

    static let panelWidth: CGFloat = 355
    /// 内容区上限：屏幕可用高度减去菜单外壳/Tab 栏/退出项；不到上限就按内容高度，超过才滚动
    static var maxContentHeight: CGFloat { max(300, (NSScreen.main?.visibleFrame.height ?? 900) - 170) }

    @AppStorage("vg.tab") private var tab: Int = 0
    @State private var expandedCards: Set<String> = []
    @State private var measuredHeight: CGFloat = 400
    @State private var drillDown: String? = nil      // 非空 = 正在看某个平台的详情页
    @State private var autoCleanOn: Bool
    @State private var launchAtLoginOn: Bool
    @State private var notifyOn: Bool

    @State private var liveNow: Date = Date()
    @State private var pulseAnim: Bool = false
    @State private var dynamicTokens: TokenStats? = nil
    @State private var dynamicLLMs: [DetectedLLMRuntime]? = nil
    @State private var dynamicAPI: ProxyStatus? = nil
    @State private var dynamicCLI: [CLIUsage]? = nil
    @State private var refreshing: Bool = false

    private let liveTicker = Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()

    public init(report: ScanReport, settings: PanelSettings, actions: PanelActions) {
        self.report = report
        self.actions = actions
        _autoCleanOn = State(initialValue: settings.autoClean)
        _launchAtLoginOn = State(initialValue: settings.launchAtLogin)
        _notifyOn = State(initialValue: settings.thresholdNotify)
    }

    private var nowTS: TimeInterval { liveNow.timeIntervalSince1970 }
    private var currentTokens: TokenStats { dynamicTokens ?? report.tokens }
    private var currentLLMs: [DetectedLLMRuntime] { dynamicLLMs ?? report.detectedLLMs }
    private var currentAPI: ProxyStatus { dynamicAPI ?? report.api }
    private var currentCLI: [CLIUsage] { dynamicCLI ?? report.cliUsage }
    private var currentInteractions: [InteractionRecord] { Array(currentTokens.recentInteractions.prefix(3)) }

    /// API 上游 → 复用平台卡片：档位 = 套餐名或 "API Key"，额度条 / 余额 / 今日 token 叠加
    private var apiCards: [DetectedLLMRuntime] {
        currentAPI.providers.map { p in
            var tokens = ""
            if p.calls > 0 {
                let models = p.models.prefix(2).joined(separator: " / ") + (p.models.count > 2 ? " …" : "")
                tokens = "\(models) · 上下文 \(formatTokens(p.ctx)) · 输出 \(formatTokens(p.out))" + (p.ctx > 0 ? String(format: " · 命中 %.0f%%", p.cacheHitRate) : "")
            }
            let sub: String
            if !p.balanceText.isEmpty { sub = p.balanceText }
            else if !p.quotaError.isEmpty { sub = "额度: " + String(p.quotaError.prefix(24)) }   // 如"当前用户不存在coding plan"
            else { sub = p.calls > 0 ? "无额度接口 · 只记调用" : "今日无调用" }

            // 第四行：延迟 + 错误 + 花费，都从记账文件里已有的字段算，没有就不写
            var obs: [String] = []
            if p.p95ms > 0 { obs.append("p50 \(Fmt.ms(p.p50ms)) · p95 \(Fmt.ms(p.p95ms))") }
            if p.errors > 0 { obs.append(String(format: "%d 错(%.0f%%)", p.errors, p.errorRate) + (p.count429 > 0 ? " 含 \(p.count429) 限流" : "")) }
            if let c = p.cost { obs.append(money(c, p.costCurrency)) }
            return DetectedLLMRuntime(
                name: p.provider, isRunning: nowTS - p.lastTS < 120, tier: p.plan.isEmpty ? "API Key" : p.plan, detail: "\(p.calls) 次",
                fiveHour: p.fiveHour, sevenDay: p.sevenDay, quotaSubtitle: sub,
                extraLine: tokens, extraLine2: obs.joined(separator: " · "),
                quotaNote: p.quotaIsEstimate ? "估算 · " + p.estimateNote : "",
                platformDetail: apiDetail(p)
            )
        }
    }

    private func money(_ v: Double, _ currency: String) -> String {
        let sym = currency == "CNY" ? "¥" : (currency == "USD" ? "$" : currency + " ")
        return v < 0.01 && v > 0 ? "\(sym)<0.01" : String(format: "%@%.2f", sym, v)
    }

    /// API 上游的详情页：把记账文件能证明的都列出来（延迟分位 / 错误 / 按 key 分账 / 模型）
    private func apiDetail(_ p: APIProviderStatus) -> PlatformDetail {
        var d = PlatformDetail()
        d.rows.append(("上游主机", p.host))
        if !p.plan.isEmpty { d.rows.append(("套餐", p.plan)) }
        d.rows.append(("今日调用", "\(p.calls) 次"))
        if p.p95ms > 0 {
            d.rows.append(("延迟 p50 / p95", "\(Fmt.ms(p.p50ms)) / \(Fmt.ms(p.p95ms))"))
            d.rows.append(("最慢一次", Fmt.ms(p.maxms)))
        }
        d.rows.append(("错误率", p.calls > 0 ? String(format: "%.1f%%（%d / %d）", p.errorRate, p.errors, p.calls) : "—"))
        if p.count429 > 0 { d.rows.append(("429 限流", "\(p.count429) 次")) }
        if p.ctx > 0 {
            d.rows.append(("输入 / 输出", "\(formatTokens(p.ctx)) / \(formatTokens(p.out))"))
            d.rows.append(("缓存命中", String(format: "%.0f%%（读 %@）", p.cacheHitRate, formatTokens(p.cacheRead))))
        }
        if p.quotaIsEstimate {
            d.rows.append(("额度口径", "估算：本机记账请求数 ÷ 套餐上限"))
            d.rows.append(("套餐上限", p.planLimitText))
            d.rows.append(("估算底数", p.estimateNote))
            d.rows.append(("注意", "走代理之外的调用算不进来，会偏低"))
        }
        if let m = p.monthly {
            d.rows.append(("月窗口", "\(m.effectivePct(now: nowTS))%" + (Fmt.countdown(to: m.resetsAt, now: nowTS).map { " · 重置 \($0)" } ?? "")))
        }
        if let c = p.cost {
            d.rows.append(("今日花费（估）", money(c, p.costCurrency) + (currentAPI.priceAsOf.isEmpty ? "" : " · 价目表 \(currentAPI.priceAsOf)")))
        } else if p.calls > 0 {
            d.rows.append(("今日花费", currentAPI.hasPriceTable ? "该模型不在价目表里" : "未配置价目表"))
        }
        if !p.models.isEmpty { d.rows.append(("模型", p.models.joined(separator: ", "))) }
        if !p.balanceText.isEmpty { d.rows.append(("余额", p.balanceText)) }
        if !p.quotaError.isEmpty { d.rows.append(("额度接口", p.quotaError)) }
        for k in p.keys {
            var v = "\(k.calls) 次"
            if k.errors > 0 { v += " · \(k.errors) 错" }
            if k.ctx > 0 { v += " · \(formatTokens(k.ctx))→\(formatTokens(k.out))" }
            if let c = k.cost { v += " · " + money(c, p.costCurrency) }
            d.rows.append(("key \(k.fingerprint)", v))
        }
        d.sourceFiles = ["~/.config/vibegauge/api-calls.jsonl", "~/.config/vibegauge/api-quota.json"]
        if currentAPI.hasPriceTable { d.sourceFiles.append("~/.config/vibegauge/prices.json") }
        if p.quotaIsEstimate { d.sourceFiles.append("~/.config/vibegauge/plans.json") }
        return d
    }

    private func secondsAgo(_ timestamp: TimeInterval) -> Int {
        max(0, Int(nowTS - timestamp))
    }

    private func isRecentInteraction(timestamp: TimeInterval) -> Bool {
        secondsAgo(timestamp) < 120
    }

    private func tierColor(_ tier: String) -> Color {
        if tier.contains("API") { return .blue }
        if tier.contains("本地") { return .purple }
        if tier.isEmpty || tier.contains("未登录") { return .secondary }
        return .green
    }

    /// 0% 绿 → 100% 红 连续渐变。平方让曲线后段变色更快：
    /// 50% 已是黄绿、70% 黄、85% 橙、95%+ 红 —— 旧版"除了 100% 全是绿"没有识别度。
    /// 饱和度/亮度固定，深浅色模式下都能看清。
    private func quotaColor(_ pct: Int) -> Color {
        let p = Double(max(0, min(100, pct))) / 100.0
        return Color(hue: 0.33 * (1.0 - p * p), saturation: 0.82, brightness: 0.82)
    }

    private struct ModelDisplayGroup: Identifiable {
        let id: String
        let isFullWidth: Bool
        let models: [DetectedLLMRuntime]
    }

    private var modelDisplayGroups: [ModelDisplayGroup] {
        var groups: [ModelDisplayGroup] = []
        var currentRegular: [DetectedLLMRuntime] = []

        for llm in currentLLMs {
            if llm.isFullWidth {
                if !currentRegular.isEmpty {
                    groups.append(ModelDisplayGroup(id: "reg-\(groups.count)", isFullWidth: false, models: currentRegular))
                    currentRegular = []
                }
                groups.append(ModelDisplayGroup(id: "full-\(llm.id)", isFullWidth: true, models: [llm]))
            } else {
                currentRegular.append(llm)
            }
        }
        if !currentRegular.isEmpty {
            groups.append(ModelDisplayGroup(id: "reg-\(groups.count)", isFullWidth: false, models: currentRegular))
        }
        return groups
    }

    private func formatTokens(_ count: Int64) -> String {
        if count >= 100_000_000 {
            return String(format: "%.2f 亿", Double(count) / 100_000_000.0)
        } else if count >= 10_000 {
            return String(format: "%.1f 万", Double(count) / 10_000.0)
        } else {
            return "\(count)"
        }
    }

    private func formatTokensInt(_ count: Int) -> String {
        formatTokens(Int64(count))
    }

    private func refreshLive() {
        guard !refreshing else { return }   // 上一次还没回来就跳过这一拍，不堆积
        refreshing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let latestTokens = ProcessScanner.shared.scanTokens()
            let latestLLMs = ProcessScanner.shared.scanActiveLLMs()
            let latestAPI = ProcessScanner.shared.scanAPI()
            let latestCLI = ProcessScanner.shared.scanCLIUsage(claude: latestTokens)
            DispatchQueue.main.async {
                self.dynamicTokens = latestTokens
                self.dynamicLLMs = latestLLMs
                self.dynamicAPI = latestAPI
                self.dynamicCLI = latestCLI
                self.refreshing = false
                self.actions.relayout()      // 数据到了卡片会增减 → 高度跟着变
            }
        }
    }

    private let gridCols = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    // MARK: - 外壳

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Tab 栏 + 右侧一行状态
            HStack(spacing: 8) {
                if let name = drillDown {
                    Button(action: { withAnimation(.easeInOut(duration: 0.15)) { drillDown = nil } }) {
                        HStack(spacing: 3) {
                            Image(systemName: "chevron.left").font(.system(size: 9, weight: .bold))
                            Text("返回").font(.system(size: 10, weight: .medium))
                        }
                        .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    Text(name)
                        .font(.system(size: 11, weight: .bold))
                    Spacer()
                } else {
                    Picker("", selection: $tab) {
                        Text("订阅").tag(0)
                        Text("API").tag(1)
                        Text("系统").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(width: 150)
                    .help("也可以在面板上用触控板左右滑动切换")

                    Spacer()

                    tabStatusLine
                }

                Button(action: actions.rescan) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("重新扫描")
            }

            SwipeScroll(
                content: VStack(alignment: .leading, spacing: 10) {
                    if let name = drillDown, let llm = (currentLLMs + apiCards).first(where: { $0.name == name }) {
                        detailPage(for: llm)
                    } else {
                        switch tab {
                        case 1: apiSection
                        case 2:
                            actionSection
                            hardwareSection
                            diskSection
                            settingsSection
                        default: aiSection
                        }
                    }
                }
                .frame(width: Self.panelWidth - 24, alignment: .leading),
                onSwipe: { step in
                    guard drillDown == nil else { return }   // 详情页里不响应滑动，只用「返回」按钮
                    let next = max(0, min(2, tab + step))
                    if next != tab { tab = next }
                },
                onHeight: { h in if abs(h - measuredHeight) > 1 { measuredHeight = h } }
            )
            .frame(width: Self.panelWidth - 24, height: min(max(measuredHeight, 360), Self.maxContentHeight))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: Self.panelWidth)
        .onChange(of: tab) { _, _ in actions.relayout() }
        .onChange(of: measuredHeight) { _, _ in actions.relayout() }
        .onReceive(liveTicker) { date in
            liveNow = date
            pulseAnim.toggle()
            refreshLive()
        }
        .onAppear { refreshLive() }
    }

    /// Tab 栏右侧：其他两个 Tab 的一句话摘要，切过去之前也能看到大概
    private var tabStatusText: String {
        let active = currentLLMs.filter { $0.isRunning }.count
        let calls = currentAPI.providers.reduce(0) { $0 + $1.calls }
        switch tab {
        case 1: return "\(active) 平台活跃 · 内存 \(report.freePercentage)%"
        case 2: return "\(active) 平台活跃 · API 今日 \(calls) 次"
        default: return "内存 \(report.freePercentage)% 可用 · API 今日 \(calls) 次"
        }
    }

    private var tabStatusLine: some View {
        Text(tabStatusText)
            .font(.system(size: 8.5))
            .foregroundColor(.secondary)
            .lineLimit(1)
    }

    // MARK: - Tab 系统：物理硬件 + MCP/NPX

    private var hardwareSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("系统物理硬件")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("发热: \(report.thermalStateString)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(report.thermalStateString == "正常" ? .secondary : .orange)
            }

            // 内存
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("内存")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(String(format: "已用 %.1f / %.1f GB", report.usedMemoryGB, report.totalMemoryGB))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                    Text("\(report.freePercentage)% 可用")
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(report.freePercentage >= 60 ? Color.green.opacity(0.18) : Color.orange.opacity(0.18))
                        .foregroundColor(report.freePercentage >= 60 ? .green : .orange)
                        .cornerRadius(3)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 5)
                        let usedRatio = max(0.02, min(1.0, 1.0 - Double(report.freePercentage) / 100.0))
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(report.freePercentage >= 60 ? Color.green : Color.orange)
                            .frame(width: geo.size.width * CGFloat(usedRatio), height: 5)
                    }
                }
                .frame(height: 5)

                HStack(spacing: 4) {
                    let compStr = report.compressorGB > 1.0
                        ? String(format: "%.2f GB", report.compressorGB)
                        : "\(Int(report.compressorGB * 1024)) MB"
                    let swapStr = report.swapUsedGB > 1.0
                        ? String(format: "%.2f GB", report.swapUsedGB)
                        : "\(Int(report.swapUsedGB * 1024)) MB"
                    Text("压缩池 \(compStr)")
                    Text("·")
                    Text("Swap \(swapStr)")
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            }

            // 磁盘
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("磁盘")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(String(format: "剩余 %.1f GB / %.1f GB (%.0f%%)", report.diskFreeGB, report.diskTotalGB, report.diskFreePct))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 5)
                        let usedRatio = report.diskTotalGB > 0 ? max(0.02, min(1.0, (report.diskTotalGB - report.diskFreeGB) / report.diskTotalGB)) : 0.5
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(Color.blue.opacity(0.85))
                            .frame(width: geo.size.width * CGFloat(usedRatio), height: 5)
                    }
                }
                .frame(height: 5)

                HStack {
                    Text(String(format: "CPU 负载: %.2f (1m) · %.2f (5m)", report.loadAvg1m, report.loadAvg5m))
                    Spacer()
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            }

            Divider().opacity(0.35)

            // MCP 与开发缓存
            HStack {
                let mcpMemStr = report.activeMCPTotalMemMB > 1024
                    ? String(format: "%.1f GB", report.activeMCPTotalMemMB / 1024.0)
                    : "\(Int(report.activeMCPTotalMemMB)) MB"
                HStack(spacing: 3) {
                    Text("活跃 MCP:")
                        .foregroundColor(.secondary)
                    Text("\(report.activeMCPProcessCount) 进程 (\(mcpMemStr))")
                        .foregroundColor(.primary)
                }
                Spacer()
                let npxStr = report.npxCacheMB > 1024
                    ? String(format: "%.1f GB", report.npxCacheMB / 1024.0)
                    : "\(Int(report.npxCacheMB)) MB"
                HStack(spacing: 3) {
                    Text("NPX 缓存:")
                        .foregroundColor(.secondary)
                    Text(npxStr)
                        .foregroundColor(.primary)
                }
            }
            .font(.system(size: 9))

            if report.totalOrphanCount > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    Text("断链孤儿 \(report.totalOrphanCount) 个 · \(Int(report.totalOrphanMemMB)) MB")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.orange)
                    ForEach(report.orphanedGroups) { g in
                        HStack {
                            Text(g.serviceName)
                            Spacer()
                            Text("\(g.processCount) 个 · \(Int(g.totalMemMB)) MB")
                        }
                        .font(.system(size: 8.5))
                        .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    // MARK: - Tab 订阅：平台矩阵 + 今日 Token + 最近交互

    private var aiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AI 运行与大模型")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                let activeCount = currentLLMs.filter { $0.isRunning }.count
                HStack(spacing: 4) {
                    Circle()
                        .fill(activeCount > 0 ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 5, height: 5)
                    Text("\(activeCount) 个平台活跃")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }

            // 平台矩阵（普通卡片双列，双池独占整行）
            VStack(spacing: 5) {
                ForEach(modelDisplayGroups) { group in
                    if group.isFullWidth {
                        if let model = group.models.first {
                            fullWidthModelCard(for: model)
                        }
                    } else {
                        LazyVGrid(columns: gridCols, spacing: 5) {
                            ForEach(group.models) { llm in
                                modelCard(for: llm)
                            }
                        }
                    }
                }
            }

            Divider().opacity(0.35)

            // 今日 Token 与 Prompt Cache
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("今日上下文 · Claude Code")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                    Text(formatTokens(currentTokens.todayContext))
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(.primary)
                    Spacer()
                    Text(String(format: "缓存率 %.1f%%", currentTokens.todayCacheHitRate))
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundColor(currentTokens.todayCacheHitRate >= 80 ? .green : .secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(currentTokens.todayCacheHitRate >= 80 ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12))
                        .cornerRadius(3)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.secondary.opacity(0.18))
                            .frame(height: 4)
                        let hitRatio = max(0.01, min(1.0, currentTokens.todayCacheHitRate / 100.0))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.green.opacity(0.85))
                            .frame(width: geo.size.width * CGFloat(hitRatio), height: 4)
                    }
                }
                .frame(height: 4)

                HStack {
                    Text("总生成 \(formatTokens(currentTokens.todayOutput)) (思考 \(formatTokens(currentTokens.todayThinking)))")
                        .font(.system(size: 8.5))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("今日 \(currentTokens.todayTurns) 次调用")
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundColor(.secondary)
                }

                // 各 CLI 今日用量（各家日志能给多少给多少）
                if !currentCLI.isEmpty {
                    Divider().opacity(0.25)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(currentCLI) { u in
                            HStack(spacing: 4) {
                                Text(u.name)
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundColor(.secondary)
                                    .frame(width: 66, alignment: .leading)
                                if u.hasTokens {
                                    Text("上下文 \(formatTokens(u.ctx))")
                                    Text("·")
                                    Text("输出 \(formatTokens(u.out))")
                                    if u.think > 0 {
                                        Text("·")
                                        Text("思考 \(formatTokens(u.think))")
                                    }
                                    Spacer(minLength: 2)
                                    if u.ctx > 0 {
                                        Text(String(format: "命中 %.0f%%", u.cacheHitRate))
                                            .foregroundColor(u.cacheHitRate >= 80 ? .green : .secondary)
                                            .fixedSize()
                                    }
                                    Text("\(u.requests) 次")
                                        .fixedSize()
                                } else {
                                    Text(u.turns > 0 ? "\(u.turns) 轮 · \(u.note)" : u.note)
                                        .foregroundColor(.secondary.opacity(0.8))
                                        .lineLimit(1)
                                    Spacer(minLength: 2)
                                }
                            }
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                        }
                    }
                }
            }

            // 最近交互（最多 3 轮）
            if !currentInteractions.isEmpty {
                let hasLive = currentInteractions.contains { isRecentInteraction(timestamp: $0.timestamp) }

                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(hasLive ? Color.green : Color.secondary.opacity(0.4))
                                .frame(width: 5, height: 5)
                                .scaleEffect(hasLive && pulseAnim ? 1.25 : 0.85)
                                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulseAnim)

                            Text(hasLive ? "实时捕获" : "最近交互")
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundColor(hasLive ? .primary : .secondary)
                        }

                        Spacer()

                        Text("最新 \(currentInteractions.count) 轮")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }

                    VStack(spacing: 4) {
                        ForEach(currentInteractions) { item in
                            interactionRow(for: item)
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.06))
                .cornerRadius(7)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    // MARK: - Tab API：API Key 调用（经记账代理）

    private var apiSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("API Key 调用")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                let api = currentAPI
                HStack(spacing: 4) {
                    Circle()
                        .fill(api.running ? Color.green : (api.installed ? Color.orange : Color.secondary.opacity(0.4)))
                        .frame(width: 5, height: 5)
                    Text(api.running ? "代理运行中 · :\(api.port)" : (api.installed ? "代理已安装，未在跑" : "代理未安装"))
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(api.installed && !api.running ? .orange : .secondary)
                }
            }

            if apiCards.isEmpty {
                Text(currentAPI.installed
                     ? "还没有调用经过代理。把别名里的 BASE_URL 前面加上 http://127.0.0.1:\(currentAPI.port)/ 即可记账。"
                     : "菜单里「安装 API 记账代理」，再把别名里的 BASE_URL 前面加上 http://127.0.0.1:\(currentAPI.port)/ 即可记账。")
                    .font(.system(size: 8.5))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LazyVGrid(columns: gridCols, spacing: 5) {
                    ForEach(apiCards) { card in
                        modelCard(for: card)
                    }
                }
            }

            Divider().opacity(0.35)

            // 记账覆盖体检：有 BASE_URL 没走代理 = 面板上看不到那些调用
            let cov = currentAPI.coverage
            if !cov.entries.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: cov.directCount > 0 ? "exclamationmark.triangle" : "checkmark.seal")
                        .font(.system(size: 8))
                        .foregroundColor(cov.directCount > 0 ? .orange : .green)
                    Text("记账覆盖 \(cov.proxiedCount)/\(cov.entries.count) 处")
                        .font(.system(size: 9, weight: .medium))
                    if cov.directCount > 0 {
                        Text("· 未接：" + cov.entries.filter { !$0.proxied }.prefix(3).map { $0.host }.joined(separator: " "))
                            .font(.system(size: 8))
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    }
                    Spacer()
                }
                .help(cov.entries.map { "\($0.proxied ? "✓" : "✗") \($0.name) → \($0.host)  (\($0.file):\($0.line))" }.joined(separator: "\n"))
            }

            // 代理控制
            HStack(spacing: 8) {
                if currentAPI.installed {
                    Text("代理前缀 http://127.0.0.1:\(currentAPI.port)/")
                        .font(.system(size: 8.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(action: actions.copyProxyPrefix) { Text("复制").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundColor(.blue)
                    Button(action: actions.uninstallProxy) { Text("停止并卸载").font(.system(size: 9)) }
                        .buttonStyle(.plain).foregroundColor(.secondary)
                } else {
                    Text("代理未安装（LaunchAgent，登录自启，不依赖本 App）")
                        .font(.system(size: 8.5))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Button(action: actions.installProxy) { Text("安装并启动").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundColor(.blue)
                }
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    // MARK: - Tab 系统：磁盘占用（会话日志治理）

    private var diskSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("磁盘占用")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "AI 工具目录合计 %.1f GB", report.diskTotalAIGB))
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
            }

            ForEach(report.disk.prefix(6)) { d in
                HStack(spacing: 5) {
                    Image(systemName: d.purgeable ? "clock.arrow.circlepath" : "lock")
                        .font(.system(size: 7.5))
                        .foregroundColor(d.purgeable ? .blue.opacity(0.8) : .secondary.opacity(0.6))
                    Text(d.label)
                        .font(.system(size: 9.5, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                    if d.purgeable, d.oldMB >= 1 {
                        Text(String(format: "旧 %.0f MB", d.oldMB))
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundColor(.orange)
                    }
                    Text(sizeText(d.totalMB))
                        .font(.system(size: 9.5))
                        .foregroundColor(.secondary)
                        .frame(width: 52, alignment: .trailing)
                }
                .help(d.note)
            }

            if report.purgeableMB >= 100 {
                Button(action: actions.purgeLogs) {
                    HStack {
                        Image(systemName: "trash").font(.system(size: 9))
                        Text(String(format: "清理 %d 天前的会话记录 · %@", ProcessScanner.shared.logRetentionDays, sizeText(report.purgeableMB)))
                            .font(.system(size: 10, weight: .semibold))
                        Spacer()
                        Text("移入废纸篓").font(.system(size: 8)).foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.orange.opacity(0.14))
                    .foregroundColor(.orange)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }

            Text("🔒 = 只统计不清理（运行库 / 插件 / 你的产物）")
                .font(.system(size: 8))
                .foregroundColor(.secondary)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private func sizeText(_ mb: Double) -> String {
        mb >= 1024 ? String(format: "%.2f GB", mb / 1024) : String(format: "%.0f MB", mb)
    }

    // MARK: - Tab 系统：设置

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("设置")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
            settingRow("定时自动清理", detail: "每 30 分钟静默巡检孤儿 MCP",
                       isOn: Binding(get: { autoCleanOn }, set: { autoCleanOn = $0; actions.setAutoClean($0) }))
            settingRow("登录时自动启动", detail: "随 macOS 登录常驻菜单栏",
                       isOn: Binding(get: { launchAtLoginOn }, set: { launchAtLoginOn = $0; actions.setLaunchAtLogin($0) }))
            settingRow("阈值通知", detail: "额度 80/95%、内存 85/93%、磁盘 90/96% 越线时提醒一次",
                       isOn: Binding(get: { notifyOn }, set: { notifyOn = $0; actions.setThresholdNotify($0) }))
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private func settingRow(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 9.5, weight: .medium))
                Text(detail).font(.system(size: 8)).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Tab 系统：清理动作

    @ViewBuilder
    private var actionSection: some View {
        if report.totalOrphanCount > 0 || report.npxCacheMB > 100 {
            VStack(spacing: 5) {
                if report.totalOrphanCount > 0 {
                    Button(action: actions.cleanOrphans) {
                        HStack {
                            Text("清理断链 AI 残留进程")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                            let memStr = report.totalOrphanMemMB > 1024
                                ? String(format: "%.2f GB", report.totalOrphanMemMB / 1024.0)
                                : "\(Int(report.totalOrphanMemMB)) MB"
                            Text(memStr)
                                .font(.system(size: 9.5, weight: .bold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.red.opacity(0.8))
                                .cornerRadius(4)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.12))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }

                if report.npxCacheMB > 100 {
                    Button(action: actions.cleanNPX) {
                        HStack {
                            Text("清理 NPX 临时工具缓存")
                                .font(.system(size: 10.5, weight: .medium))
                                .foregroundColor(.primary)
                            Spacer()
                            let npxStr = report.npxCacheMB > 1024
                                ? String(format: "%.2f GB", report.npxCacheMB / 1024.0)
                                : "\(Int(report.npxCacheMB)) MB"
                            Text(npxStr)
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.08))
                        .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            HStack {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
                Text("AI 与系统运行环境健康，暂无残留垃圾")
                    .font(.system(size: 9.5))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
        }
    }

    // MARK: - 最近交互单行

    @ViewBuilder
    private func interactionRow(for item: InteractionRecord) -> some View {
        let isLive = isRecentInteraction(timestamp: item.timestamp)
        let secs = secondsAgo(item.timestamp)
        let timeAgo = secs < 8 ? "刚刚 · 实时" : Fmt.ago(secs)

        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Circle()
                    .fill(isLive ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 4.5, height: 4.5)

                Text(Fmt.modelDisplayName(item.model))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                Text("(\(timeAgo))")
                    .font(.system(size: 7.5))
                    .foregroundColor(isLive ? .green : .secondary)
                    .lineLimit(1)
                    .fixedSize()

                Spacer(minLength: 4)

                HStack(spacing: 3) {
                    MiniProgressBar(
                        value: item.cacheHitRate / 100.0,
                        color: item.cacheHitRate >= 80 ? .green : (item.cacheHitRate > 50 ? .blue : .secondary),
                        width: 20,
                        height: 3
                    )
                    Text(String(format: "%.1f%%", item.cacheHitRate))
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundColor(item.cacheHitRate >= 80 ? .green : .primary)
                        .lineLimit(1)
                        .fixedSize()
                    Text("命中")
                        .font(.system(size: 7))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }

            HStack(spacing: 3.5) {
                Text("上下文 \(formatTokensInt(item.contextTokens))")
                Text("·")
                Text("输出 \(formatTokensInt(item.outputTokens))")
                if item.thinkingTokens > 0 {
                    Text("·")
                    Text("思考 \(formatTokensInt(item.thinkingTokens))")
                }
            }
            .font(.system(size: 8))
            .foregroundColor(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4.5)
        .background(Color.secondary.opacity(0.04))
        .cornerRadius(5)
    }

    // MARK: - 额度子组件

    /// "5H ▮▮ 12%" 一组
    @ViewBuilder
    private func quotaBar(label: String, win: QuotaWindow) -> some View {
        let pct = win.effectivePct(now: nowTS)
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 7.5, weight: .medium))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
            MiniProgressBar(value: Double(pct) / 100.0, color: quotaColor(pct), width: 16, height: 3.5)
            Text("\(pct)%")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundColor(pct >= 60 ? quotaColor(pct) : .primary)
                .lineLimit(1)
                .fixedSize()
            if pct >= 100 {
                Text("耗尽")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(.red.opacity(0.85))
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }

    @ViewBuilder
    private func dot() -> some View {
        Text("·")
            .font(.system(size: 7))
            .foregroundColor(.secondary)
            .fixedSize()
    }

    /// 脚注内容：各窗口重置倒计时 + 按池分别标数据新鲜度（>5 分钟才标）
    private func footerParts(for llm: DetectedLLMRuntime) -> (resets: String, stale: String) {
        let sp = llm.secondaryPoolName
        let windows: [(String, QuotaWindow?)] = [
            ("5H", llm.fiveHour), ("W", llm.sevenDay), ("\(sp)5H", llm.secondaryFiveHour), ("\(sp)W", llm.secondarySevenDay)
        ]
        let resets = windows.compactMap { label, w -> String? in
            guard let w = w, let c = Fmt.countdown(to: w.resetsAt, now: nowTS) else { return nil }
            return "\(label) \(c)"
        }
        var stale: [String] = []
        if let a = [llm.fiveHour, llm.sevenDay].compactMap({ $0?.ageSeconds(now: nowTS) }).max(), a > 300 {
            stale.append("记录于 \(Fmt.agoShort(a))")
        }
        if let a = [llm.secondaryFiveHour, llm.secondarySevenDay].compactMap({ $0?.ageSeconds(now: nowTS) }).max(), a > 300 {
            stale.append("\(sp) 记录于 \(Fmt.agoShort(a))")
        }
        return (resets.isEmpty ? "" : "重置 " + resets.joined(separator: " · "), stale.joined(separator: " · "))
    }

    /// 第三行脚注：可换两行，不截断
    @ViewBuilder
    /// 「按当前节奏会不会超额」——挑最吃紧的那个窗口，一直显示，不只是超额时才提示。
    /// 超额的窗口优先；都不超额就显示离满最近的那个。
    private func burnLine(for llm: DetectedLLMRuntime) -> (text: String, over: Bool)? {
        let wins: [(String, QuotaWindow?)] = [("5h", llm.fiveHour), ("周", llm.sevenDay),
                                              ("\(llm.secondaryPoolName)5h", llm.secondaryFiveHour),
                                              ("\(llm.secondaryPoolName)周", llm.secondarySevenDay)]
        var best: (label: String, burn: Burn)? = nil
        for (label, w) in wins {
            guard let w = w, let b = w.burn(now: nowTS) else { continue }
            if best == nil || b.projectedAtReset > best!.burn.projectedAtReset { best = (label, b) }
        }
        guard let (label, b) = best else { return nil }
        if let at = b.exhaustAt, let eta = Fmt.countdown(to: at, now: nowTS) {
            return ("\(label) 按当前节奏 \(eta) 后打满（重置时 \(b.projectedAtReset)%）", true)
        }
        return ("\(label) 按当前节奏，到重置 \(b.projectedAtReset)%", false)
    }

    @ViewBuilder
    private func quotaFooter(for llm: DetectedLLMRuntime) -> some View {
        let parts = footerParts(for: llm)
        if let b = burnLine(for: llm) {
            Text((b.over ? "⚡ " : "→ ") + b.text)
                .font(.system(size: 7))
                .foregroundColor(b.over ? .orange : .secondary)
                .lineLimit(1)
        }
        if !parts.resets.isEmpty || !parts.stale.isEmpty {
            (Text(parts.resets)
                + Text(parts.resets.isEmpty || parts.stale.isEmpty ? "" : " · ")
                + Text(parts.stale).foregroundColor(.orange))
                .font(.system(size: 7))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 一个套餐多模型额度：按已用 % 降序，只显示 3 个，其余"另 N 个"展开
    @ViewBuilder
    private func subQuotaRows(for llm: DetectedLLMRuntime) -> some View {
        if !llm.subQuotas.isEmpty {
            let sorted = llm.subQuotas.sorted { $0.window.effectivePct(now: nowTS) > $1.window.effectivePct(now: nowTS) }
            let expanded = expandedCards.contains(llm.id)
            let shown = expanded ? sorted : Array(sorted.prefix(3))
            VStack(alignment: .leading, spacing: 2) {
                ForEach(shown) { q in
                    let pct = q.window.effectivePct(now: nowTS)
                    HStack(spacing: 3) {
                        Text(q.name)
                            .font(.system(size: 7.5))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        MiniProgressBar(value: Double(pct) / 100.0, color: quotaColor(pct), width: 22, height: 3)
                        Text("\(pct)%")
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundColor(pct >= 60 ? quotaColor(pct) : .primary)
                            .fixedSize()
                    }
                }
                if sorted.count > 3 {
                    Button(action: {
                        if expanded { expandedCards.remove(llm.id) } else { expandedCards.insert(llm.id) }
                    }) {
                        Text(expanded ? "收起 ▴" : "另 \(sorted.count - 3) 个 ▾")
                            .font(.system(size: 7.5))
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 1)
        }
    }

    @ViewBuilder
    private func cardHeader(for llm: DetectedLLMRuntime) -> some View {
        HStack(spacing: 3.5) {
            Circle()
                .fill(llm.isRunning ? Color.green : Color.secondary.opacity(0.3))
                .frame(width: 5, height: 5)

            Text(llm.name)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(llm.isRunning ? .primary : .secondary)
                .lineLimit(1)

            if !llm.tier.isEmpty {
                Text(llm.tier)
                    .font(.system(size: 7.5, weight: .bold))
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(tierColor(llm.tier).opacity(0.18))
                    .foregroundColor(tierColor(llm.tier))
                    .cornerRadius(2.5)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }

            Spacer(minLength: 2)

            Text(llm.detail)
                .font(.system(size: 8.5, weight: llm.isRunning ? .medium : .regular))
                .foregroundColor(llm.isRunning ? .secondary : .secondary.opacity(0.75))
                .lineLimit(1)
                .fixedSize()
        }
    }

    // 普通卡片（双列）
    @ViewBuilder
    private func modelCard(for llm: DetectedLLMRuntime) -> some View {
        VStack(alignment: .leading, spacing: 3.5) {
            cardHeader(for: llm)

            if llm.hasQuota {
                HStack(spacing: 3) {
                    if let fh = llm.fiveHour { quotaBar(label: "5H", win: fh) }
                    if let sd = llm.sevenDay {
                        if llm.fiveHour != nil { dot() }
                        quotaBar(label: "W", win: sd)
                    }
                }
                quotaFooter(for: llm)
                if !llm.quotaNote.isEmpty {
                    Text(llm.quotaNote)
                        .font(.system(size: 7.5))
                        .foregroundColor(.orange.opacity(0.85))      // 橙色 = 这数是估的，不是厂商给的
                        .lineLimit(1)
                }
            } else {
                Text(llm.quotaSubtitle.isEmpty ? (llm.isRunning ? "服务就绪" : "未启动") : llm.quotaSubtitle)
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            if !llm.extraLine.isEmpty {
                Text(llm.extraLine)
                    .font(.system(size: 7.5))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            if !llm.extraLine2.isEmpty {
                Text(llm.extraLine2)
                    .font(.system(size: 7.5))
                    .foregroundColor(llm.extraLine2.contains("错") ? .orange : .secondary)
                    .lineLimit(1)
            }
            subQuotaRows(for: llm)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(llm.isRunning ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.03))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture { openDetail(llm) }
    }

    // 整行卡片（双池：原生池 + 三方池）
    @ViewBuilder
    private func fullWidthModelCard(for llm: DetectedLLMRuntime) -> some View {
        VStack(alignment: .leading, spacing: 4.5) {
            cardHeader(for: llm)

            HStack(spacing: 6) {
                if llm.fiveHour != nil || llm.sevenDay != nil {
                    HStack(spacing: 3.5) {
                        if let fh = llm.fiveHour { quotaBar(label: "5H", win: fh) }
                        if let sd = llm.sevenDay {
                            if llm.fiveHour != nil { dot() }
                            quotaBar(label: "W", win: sd)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(4)
                    .fixedSize(horizontal: true, vertical: false)
                }

                Spacer(minLength: 4)

                if llm.secondaryFiveHour != nil || llm.secondarySevenDay != nil {
                    HStack(spacing: 3) {
                        Text(llm.secondaryPoolName)
                            .font(.system(size: 7.5, weight: .bold))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                        if let fh = llm.secondaryFiveHour { quotaBar(label: "5H", win: fh) }
                        if let sd = llm.secondarySevenDay {
                            if llm.secondaryFiveHour != nil { dot() }
                            quotaBar(label: "W", win: sd)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3.5)
                    .background(Color.secondary.opacity(0.06))
                    .cornerRadius(4)
                    .fixedSize(horizontal: true, vertical: false)
                }
            }

            quotaFooter(for: llm)
            subQuotaRows(for: llm)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(llm.isRunning ? Color.secondary.opacity(0.08) : Color.secondary.opacity(0.03))
        .cornerRadius(6)
        .contentShape(Rectangle())
        .onTapGesture { openDetail(llm) }
    }

    // MARK: - 详情页

    /// 大号额度环：外圈已用比例，中间百分比，下面窗口名 + 重置倒计时
    @ViewBuilder
    private func quotaRing(label: String, win: QuotaWindow, size: CGFloat = 78) -> some View {
        let pct = win.effectivePct(now: nowTS)
        let color = quotaColor(pct)
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.18), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: max(0.004, Double(pct) / 100.0))
                    .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 0) {
                    Text("\(pct)")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundColor(pct > 80 ? color : .primary)
                    Text("% 已用")
                        .font(.system(size: 7))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: size, height: size)

            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
            if let c = Fmt.countdown(to: win.resetsAt, now: nowTS) {
                Text("重置 \(c)")
                    .font(.system(size: 8))
                    .foregroundColor(.secondary)
            }
            if let a = win.ageSeconds(now: nowTS) {
                Text("记录于 \(Fmt.agoShort(a))")
                    .font(.system(size: 7.5))
                    .foregroundColor(a > 300 ? .orange : .secondary.opacity(0.75))
            }
        }
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundColor(.secondary)
    }

    private func card<T: View>(@ViewBuilder _ content: () -> T) -> some View {
        VStack(alignment: .leading, spacing: 6) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
    }

    @ViewBuilder
    private func detailPage(for llm: DetectedLLMRuntime) -> some View {
        let d = llm.platformDetail

        // 1. 额度环
        if llm.hasQuota {
            card {
                HStack(alignment: .top, spacing: 0) {
                    if let fh = llm.fiveHour {
                        quotaRing(label: "5 小时窗口", win: fh).frame(maxWidth: .infinity)
                    }
                    if let sd = llm.sevenDay {
                        quotaRing(label: llm.name == "Grok" ? "周窗口" : "7 天窗口", win: sd).frame(maxWidth: .infinity)
                    }
                    if let sf = llm.secondaryFiveHour {
                        quotaRing(label: "\(llm.secondaryPoolName) 5H", win: sf).frame(maxWidth: .infinity)
                    }
                    if let sw = llm.secondarySevenDay {
                        quotaRing(label: "\(llm.secondaryPoolName)池 周", win: sw).frame(maxWidth: .infinity)
                    }
                }
            }
        }

        // 1.5 燃烧速率（窗口长度已知才算：本窗口迄今的平均速度）
        let burns: [(String, Burn)] = [("5 小时", llm.fiveHour), ("周", llm.sevenDay),
                                       ("\(llm.secondaryPoolName) 5 小时", llm.secondaryFiveHour),
                                       ("\(llm.secondaryPoolName) 周", llm.secondarySevenDay)]
            .compactMap { label, w in w?.burn(now: nowTS).map { (label, $0) } }
        if !burns.isEmpty {
            card {
                sectionTitle("燃烧速率（优先按近期节奏）")
                ForEach(Array(burns.enumerated()), id: \.offset) { _, item in
                    let b = item.1
                    HStack(spacing: 4) {
                        Text(item.0).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(String(format: "%.1f%%/小时", b.pctPerHour))
                            .font(.system(size: 9, weight: .semibold))
                        Text(b.basis)
                            .font(.system(size: 7.5))
                            .foregroundColor(b.isRecent ? .blue.opacity(0.85) : .secondary)
                        Text("→ 重置时 \(b.projectedAtReset)%")
                            .font(.system(size: 8.5))
                            .foregroundColor(b.projectedAtReset >= 100 ? .orange : .secondary)
                        if let at = b.exhaustAt, let eta = Fmt.countdown(to: at, now: nowTS) {
                            Text("· \(eta) 后打满")
                                .font(.system(size: 8.5, weight: .semibold))
                                .foregroundColor(.orange)
                                .fixedSize()
                        }
                    }
                }
            }
        }

        // 2. 其他额度桶（Codex 的 Spark 等）
        if !d.extraPools.isEmpty {
            card {
                sectionTitle("其他额度桶（主卡未显示）")
                ForEach(Array(d.extraPools.enumerated()), id: \.offset) { _, item in
                    HStack(spacing: 4) {
                        Text(item.0).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(1)
                        Spacer(minLength: 4)
                        let pct = item.1.effectivePct(now: nowTS)
                        MiniProgressBar(value: Double(pct) / 100.0, color: quotaColor(pct), width: 40, height: 4)
                        Text("\(pct)%").font(.system(size: 9, weight: .bold)).fixedSize()
                        if let c = Fmt.countdown(to: item.1.resetsAt, now: nowTS) {
                            Text(c).font(.system(size: 7.5)).foregroundColor(.secondary).fixedSize()
                        }
                    }
                }
            }
        }

        // 3. 订阅 / 账号信息
        if !d.rows.isEmpty {
            card {
                HStack {
                    sectionTitle("订阅与账号")
                    Spacer()
                    if !llm.tier.isEmpty {
                        Text(llm.tier)
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(tierColor(llm.tier).opacity(0.18))
                            .foregroundColor(tierColor(llm.tier))
                            .cornerRadius(3)
                    }
                }
                ForEach(Array(d.rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 6) {
                        Text(row.0)
                            .font(.system(size: 8.5))
                            .foregroundColor(.secondary)
                            .frame(width: 96, alignment: .leading)
                        Text(row.1)
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                }
            }
        }

        // 4. 活跃会话
        if !d.sessions.isEmpty {
            card {
                HStack {
                    sectionTitle("活跃会话")
                    Spacer()
                    Text("\(d.sessions.count) 个").font(.system(size: 8)).foregroundColor(.secondary)
                }
                ForEach(d.sessions) { se in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 4, height: 4)
                            Text(shortPath(se.cwd))
                                .font(.system(size: 8.5, weight: .medium))
                                .lineLimit(1)
                                .truncationMode(.head)
                            Spacer(minLength: 4)
                            Text(Fmt.agoShort(se.startedAgo).replacingOccurrences(of: "前", with: ""))
                                .font(.system(size: 8)).foregroundColor(.secondary).fixedSize()
                            Text(String(format: "%.0f MB", se.memMB))
                                .font(.system(size: 8)).foregroundColor(.secondary).fixedSize()
                        }
                        Text("pid \(se.pid)")
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundColor(.secondary.opacity(0.7))
                    }
                    .padding(.vertical, 1)
                }
            }
        }

        // 5. 今日用量（该平台自己的）
        if let u = currentCLI.first(where: { $0.name.hasPrefix(llm.name) || llm.name.hasPrefix($0.name.replacingOccurrences(of: " Code", with: "")) }) {
            card {
                sectionTitle("今日用量")
                if u.hasTokens {
                    HStack(spacing: 0) {
                        detailMetric("上下文", formatTokens(u.ctx))
                        detailMetric("输出", formatTokens(u.out))
                        detailMetric("思考", formatTokens(u.think))
                        detailMetric("调用", "\(u.requests)")
                    }
                    HStack(spacing: 4) {
                        Text("缓存命中").font(.system(size: 8)).foregroundColor(.secondary)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.18)).frame(height: 5)
                                RoundedRectangle(cornerRadius: 2).fill(Color.green.opacity(0.85))
                                    .frame(width: geo.size.width * CGFloat(max(0.01, min(1, u.cacheHitRate / 100))), height: 5)
                            }
                        }
                        .frame(height: 5)
                        Text(String(format: "%.1f%%", u.cacheHitRate))
                            .font(.system(size: 8, weight: .bold)).fixedSize()
                    }
                } else {
                    Text(u.turns > 0 ? "\(u.turns) 轮 · \(u.note)" : u.note)
                        .font(.system(size: 8.5)).foregroundColor(.secondary)
                }
            }
        }

        // 6. 数据来源
        if !d.sourceFiles.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                sectionTitle("数据来源（只读本机文件）")
                ForEach(d.sourceFiles, id: \.self) { f in
                    Text(f).font(.system(size: 7.5, design: .monospaced)).foregroundColor(.secondary.opacity(0.8)).lineLimit(1)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private func detailMetric(_ label: String, _ value: String) -> some View {
        VStack(spacing: 1) {
            Text(value).font(.system(size: 12, weight: .bold, design: .rounded))
            Text(label).font(.system(size: 7.5)).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// /Users/x/Desktop/code/foo → ~/…/code/foo
    private func shortPath(_ p: String) -> String {
        var s = p.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        let parts = s.split(separator: "/")
        if parts.count > 3 { s = "~/…/" + parts.suffix(2).joined(separator: "/") }
        return s
    }

    private func openDetail(_ llm: DetectedLLMRuntime) {
        // 只有真有东西可看才进详情，避免点进去一片空白
        guard llm.hasQuota || !llm.platformDetail.rows.isEmpty || !llm.platformDetail.sessions.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.15)) { drillDown = llm.name }
    }
}
