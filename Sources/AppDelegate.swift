import Cocoa
import SwiftUI
import ServiceManagement
import UserNotifications
import os

/// 菜单项里的宿主视图：NSMenu 会把鼠标事件转发给菜单项的自定义视图，滚动事件也走这条路。
/// 与 AppDelegate 里的本地监听器双路并行，谁先收到谁处理。
final class SwipeHostingView<Content: View>: NSHostingView<Content> {
    weak var delegateRef: AppDelegate?
    private let vlog = Logger(subsystem: "com.haifeng.vibegauge", category: "menu")

    override func scrollWheel(with event: NSEvent) {
        vlog.debug("view scroll dx=\(event.scrollingDeltaX) dy=\(event.scrollingDeltaY)")
        if delegateRef?.handleScroll(event) == true { return }
        super.scrollWheel(with: event)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var menu: NSMenu!
    private var timer: Timer?
    private var autoCleanTimer: Timer?

    private var currentReport = ScanReport()
    private weak var hostingView: SwipeHostingView<DashboardView>?
    private let log = Logger(subsystem: "com.haifeng.vibegauge", category: "menu")

    // UserDefaults Keys
    private let autoCleanKey = "autoCleanEnabled"

    var isAutoCleanEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoCleanKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: autoCleanKey)
            setupAutoCleanTimer()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        loadNotifyState()
        DashboardView.migrateTabSelection()
        NetworkScanner.shared.start()
        UsageHistory.shared.start()
        DispatchQueue.global(qos: .utility).async { ProxyManager.shared.syncIfInstalled() }   // 包里脚本更新了就热替换
        updateStatus()

        timer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }

        setupAutoCleanTimer()
        setupWakeObserver()
    }

    /// 睡醒后 MCP 的父进程常常已经没了，这时候是收割的最好时机。
    /// 延迟 60 秒再跑：让系统先把网络/磁盘缓过来，也给 CLI 自己重连的机会。
    private func setupWakeObserver() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self = self, self.isAutoCleanEnabled else { return }
            self.log.notice("检测到系统唤醒，60 秒后巡检")
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                self?.performSilentAutoClean(reason: "唤醒")
            }
        }
    }

    private func setupAutoCleanTimer() {
        autoCleanTimer?.invalidate()
        autoCleanTimer = nil

        if isAutoCleanEnabled {
            autoCleanTimer = Timer.scheduledTimer(withTimeInterval: 1800.0, repeats: true) { [weak self] _ in
                self?.performSilentAutoClean(reason: "定时")
            }
        }
    }

    /// 触发静默清理的三个时机：定时 30 分钟、睡醒、内存吃紧。
    /// 三者共用同一条保守路径（只动连续两次扫描都是孤儿、且已孤儿 ≥120s 的），并加 5 分钟总闸防风暴。
    private var lastAutoCleanAt: TimeInterval = 0

    /// 内存吃紧该不该立刻收割（纯判断，可自测）
    public static func shouldReapForMemory(usedPct: Int, lastCleanAt: TimeInterval, now: TimeInterval) -> Bool {
        usedPct >= 85 && now - lastCleanAt >= 300
    }

    private func performSilentAutoClean(reason: String = "定时") {
        let now = Date().timeIntervalSince1970
        guard now - lastAutoCleanAt >= 300 else {
            log.debug("自动清理跳过（\(reason)）：距上次不足 5 分钟")
            return
        }
        lastAutoCleanAt = now
        log.notice("自动清理触发：\(reason)")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = ProcessScanner.shared.scan()
            // 静默清理更保守：只动「连续两次扫描都是孤儿」的，避开 CLI 正在重启 MCP 的瞬态
            let stable = ProcessScanner.shared.stableOrphans(report.orphans, minSeconds: 120)
            if !stable.isEmpty {
                let r = ProcessScanner.shared.killProcesses(stable)
                DispatchQueue.main.async {
                    if r.killed > 0 {
                        self?.sendNotification(
                            title: "VibeGauge 内存优化",
                            body: "已静默清理 \(r.killed) 个断链 AI 进程，回收 \(String(format: "%.0f", r.freedMB)) MB 内存。" + (r.skipped > 0 ? "（\(r.skipped) 个已自行退出，跳过）" : "")
                        )
                    }
                    self?.updateStatus()
                }
            }
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - 触控板左右滑动切 Tab
    // NSMenu 打开后跑自己的事件循环（NSEventTrackingRunLoopMode），滚动事件不一定会派到菜单项里的视图，
    // 所以用 app 级本地监听器：菜单开时装、关时卸，横向位移累计过阈值就切 Tab 并吞掉该事件。
    private var scrollMonitor: Any?
    private var swipeAccum: CGFloat = 0
    private var lastSwipeAt: TimeInterval = 0
    private static let tabCount = 5

    private func installSwipeMonitor() {
        guard scrollMonitor == nil else { return }
        swipeAccum = 0
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            guard let self = self else { return event }
            self.log.debug("monitor scroll dx=\(event.scrollingDeltaX) dy=\(event.scrollingDeltaY) precise=\(event.hasPreciseScrollingDeltas) phase=\(event.phase.rawValue)")
            return self.handleScroll(event) ? nil : event
        }
    }

    private func removeSwipeMonitor() {
        if let m = scrollMonitor { NSEvent.removeMonitor(m) }
        scrollMonitor = nil
        swipeAccum = 0
    }

    /// 返回 true = 已处理（吞掉事件）
    fileprivate func handleScroll(_ event: NSEvent) -> Bool {
        var dx = event.scrollingDeltaX
        let dy = event.scrollingDeltaY
        if event.isDirectionInvertedFromDevice { dx = -dx }   // 用户关了「自然滚动」时方向要翻回来

        if event.phase == .began || event.phase == .cancelled { swipeAccum = 0 }
        guard abs(dx) > abs(dy) * 1.5 else { return false }   // 竖向为主 → 留给内容滚动
        guard event.momentumPhase == [] else { return true }  // 惯性阶段只吞掉，不再切

        swipeAccum += dx
        let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 45 : 3
        let now = Date().timeIntervalSince1970
        guard abs(swipeAccum) >= threshold, now - lastSwipeAt > 0.3 else { return true }

        let step = swipeAccum < 0 ? 1 : -1                   // 向左滑 = 下一个 Tab（像翻页）
        swipeAccum = 0
        lastSwipeAt = now
        let cur = UserDefaults.standard.integer(forKey: "vg.tab")
        let next = max(0, min(Self.tabCount - 1, cur + step))
        if next != cur {
            UserDefaults.standard.set(next, forKey: "vg.tab")   // @AppStorage 会跟着刷新
            log.debug("swipe tab \(cur) → \(next)")
        }
        return true
    }

    func menuWillOpen(_ menu: NSMenu) { installSwipeMonitor() }
    func menuDidClose(_ menu: NSMenu) { removeSwipeMonitor() }

    private var isScanning = false

    @objc func updateStatus() {
        guard !isScanning else { return }   // 首扫可能 4s+，别让 8s 定时器堆积
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let report = ProcessScanner.shared.scan()
            DispatchQueue.main.async {
                self?.isScanning = false
                self?.currentReport = report
                self?.renderStatusButton(report: report)
                self?.reapIfMemoryTight(report)
            }
        }
    }

    /// 内存已用 ≥85% 且开了自动清理 → 不等 30 分钟，立刻走一次保守巡检
    private func reapIfMemoryTight(_ report: ScanReport) {
        guard isAutoCleanEnabled, report.totalMemoryGB > 0 else { return }
        let usedPct = max(0, 100 - report.freePercentage)
        guard Self.shouldReapForMemory(usedPct: usedPct, lastCleanAt: lastAutoCleanAt,
                                       now: Date().timeIntervalSince1970) else { return }
        performSilentAutoClean(reason: "内存 \(usedPct)%")
    }

    // MARK: - 芯片框架图标 (内嵌居中数字)
    private func renderChipFrameImage(percentage: Int) -> NSImage {
        let width: CGFloat = 25.0
        let height: CGFloat = 22.0

        let img = NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            let bodyWidth: CGFloat = 19.5
            let bodyHeight: CGFloat = 13.0
            let bodyX: CGFloat = (width - bodyWidth) / 2.0
            let bodyY: CGFloat = (height - bodyHeight) / 2.0

            // 1. 芯片主体轮廓
            let bodyRect = NSRect(x: bodyX, y: bodyY, width: bodyWidth, height: bodyHeight)
            let bodyPath = NSBezierPath(roundedRect: bodyRect, xRadius: 2.8, yRadius: 2.8)
            bodyPath.lineWidth = 1.2
            NSColor.black.setStroke()
            bodyPath.stroke()

            // 2. 芯片四周引脚 (上下各 3 个金属引脚)
            let pinW: CGFloat = 1.5
            let pinH: CGFloat = 1.8
            let pinSpacing: CGFloat = 4.3
            let startX: CGFloat = bodyX + 3.4
            for i in 0..<3 {
                let px = startX + CGFloat(i) * pinSpacing
                NSBezierPath(roundedRect: NSRect(x: px, y: bodyY + bodyHeight, width: pinW, height: pinH), xRadius: 0.5, yRadius: 0.5).fill()
                NSBezierPath(roundedRect: NSRect(x: px, y: bodyY - pinH, width: pinW, height: pinH), xRadius: 0.5, yRadius: 0.5).fill()
            }

            // 3. 内部进度轻量填充
            let pad: CGFloat = 1.6
            let maxW = bodyWidth - (pad * 2)
            let fillW = maxW * CGFloat(percentage) / 100.0
            if fillW > 1.0 {
                let fillRect = NSRect(x: bodyX + pad, y: bodyY + pad, width: fillW, height: bodyHeight - (pad * 2))
                let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 1.6, yRadius: 1.6)
                NSColor.black.withAlphaComponent(0.22).setFill()
                fillPath.fill()
            }

            // 4. 居中数字
            let text = "\(percentage)"
            let fontSize: CGFloat = (percentage >= 100) ? 7.2 : 8.5
            let font = NSFont.monospacedDigitSystemFont(ofSize: fontSize, weight: .bold)
            let pStyle = NSMutableParagraphStyle()
            pStyle.alignment = .center
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.black,
                .paragraphStyle: pStyle
            ]
            let textSize = (text as NSString).size(withAttributes: attrs)
            let textY = bodyY + (bodyHeight - textSize.height) / 2.0
            let textRect = NSRect(x: bodyX, y: textY, width: bodyWidth, height: textSize.height)
            text.draw(in: textRect, withAttributes: attrs)
            return true
        }

        img.isTemplate = true
        return img
    }

    /// 图标仍然只画内存可用 %（不掺额度，免得菜单栏变成花的）。
    /// 压力信号只走两条出口：越线弹通知 + 悬停 tooltip 里列全部。
    private func renderStatusButton(report: ScanReport) {
        evaluateExitChanges()
        guard let button = statusItem.button else { return }
        button.image = renderChipFrameImage(percentage: report.freePercentage)
        button.imagePosition = .imageOnly
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")

        let signals = report.pressures
        button.toolTip = (["VibeGauge · 内存可用 \(report.freePercentage)%", "—— 以下为已用 %（越高越紧）——"]
                          + signals.prefix(8).map { "\($0.short)  \($0.pct)%" + ($0.level > 0 ? "  ⚠︎" : "") }).joined(separator: "\n")
        evaluateThresholds(signals)
    }

    // MARK: - 阈值通知
    // 每次扫描（8s）都评一遍，靠"同键同级只报一次"去重；掉回警告线下 5 点才解除，避免在阈值上来回抖。
    // 状态落 UserDefaults：不然每次重启 App 都把"本来就满"的池子重报一遍（实测很吵）
    private var notifiedLevel: [String: Int] = [:]
    private var notifiedAt: [String: TimeInterval] = [:]
    private var didSeedNotifyState = false
    private let notifyKey = "thresholdNotifyEnabled"

    var isThresholdNotifyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: notifyKey) == nil ? true : UserDefaults.standard.bool(forKey: notifyKey) }
        set { UserDefaults.standard.set(newValue, forKey: notifyKey) }
    }

    var isExitChangeNotifyEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "exitChangeNotifyEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "exitChangeNotifyEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "exitChangeNotifyEnabled") }
    }

    static func shouldNotifyExit(lastAt: TimeInterval?, now: TimeInterval) -> Bool {
        lastAt.map { now - $0 >= 600 } ?? true
    }

    private func evaluateExitChanges() {
        let events = NetworkScanner.shared.drainExitEvents()
        guard isExitChangeNotifyEnabled else { return }  // 关闭期间的变化不在重新打开时补报
        let defaults = UserDefaults.standard
        for event in events {
            let key = "vg.exitNotifiedAt.\(event.aiName)"
            let now = Date().timeIntervalSince1970
            let last = defaults.object(forKey: key) as? Double
            guard Self.shouldNotifyExit(lastAt: last, now: now) else { continue }
            defaults.set(now, forKey: key)
            sendNotification(title: (event.isCountryChange ? "⛔️ " : "⚠️ ") + "\(event.aiName) 出口变化",
                             body: "\(event.oldIP)（\(event.oldLoc)）→ \(event.newIP)（\(event.newLoc)）")
        }
    }

    private func evaluateThresholds(_ signals: [PressureSignal]) {
        let live = Set(signals.map { $0.key })
        notifiedLevel = notifiedLevel.filter { live.contains($0.key) }   // 额度换窗口 → 键变了 → 旧状态丢掉
        notifiedAt = notifiedAt.filter { live.contains($0.key) }

        // 启动后第一轮只建基线，不报：本来就满的池子（如 Gemini 三方）不该在每次开机/重启时再吼一遍。
        // 之后只有"运行期间真的越线"才提醒。
        if !didSeedNotifyState {
            didSeedNotifyState = true
            let seeded = signals.filter { notifiedLevel[$0.key] == nil }
            for s in seeded { notifiedLevel[s.key] = s.level }
            persistNotifyState()
            log.notice("阈值通知：启动基线 \(signals.count) 条信号，新建 \(seeded.count) 条，本轮不报")
            return
        }

        guard isThresholdNotifyEnabled else { return }
        let now = Date().timeIntervalSince1970
        var dirty = false

        for s in signals {
            let last = notifiedLevel[s.key] ?? 0
            if s.level > last {
                // 同一条信号 4 小时内最多吼一次，避免在阈值上抖来抖去刷屏
                if now - (notifiedAt[s.key] ?? 0) < Self.notifyCooldown { continue }
                notifiedLevel[s.key] = s.level
                notifiedAt[s.key] = now
                dirty = true
                sendNotification(
                    title: (s.level >= 2 ? "⛔️ " : "⚠️ ") + "\(s.short) \(s.pct)%",
                    body: s.detail
                )
            } else if s.level == 0, last > 0, s.pct < s.warn - 5 {
                notifiedLevel[s.key] = 0
                dirty = true
            }
        }
        if dirty { persistNotifyState() }
    }

    private static let notifyCooldown: TimeInterval = 4 * 3600
    private let notifyStateKey = "vg.notifyState"       // [key: "level|lastAt"]

    private func loadNotifyState() {
        guard let raw = UserDefaults.standard.dictionary(forKey: notifyStateKey) as? [String: String] else { return }
        for (k, v) in raw {
            let parts = v.split(separator: "|")
            guard parts.count == 2, let lv = Int(parts[0]), let at = Double(parts[1]) else { continue }
            notifiedLevel[k] = lv
            notifiedAt[k] = at
        }
    }

    private func persistNotifyState() {
        var raw: [String: String] = [:]
        for (k, lv) in notifiedLevel { raw[k] = "\(lv)|\(notifiedAt[k] ?? 0)" }
        UserDefaults.standard.set(raw, forKey: notifyStateKey)
    }

    // MARK: - NSMenuDelegate (嵌入 SwiftUI 面板)
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // 菜单弹出直接用 ≤8s 前的缓存快照，主线程不做任何扫描；DashboardView.onAppear 会立刻在后台刷一次
        let report = currentReport

        // 面板（Tab 切换，高度随当前 Tab 内容自适应，超过屏幕才滚动）。所有动作都在面板里，菜单只留退出。
        var actions = PanelActions()
        actions.cleanOrphans = { [weak self] in
            self?.menu.cancelTracking()
            self?.cleanOrphansAction()
        }
        actions.cleanNPX = { [weak self] in
            self?.menu.cancelTracking()
            self?.cleanNPXAction()
        }
        actions.rescan = { [weak self] in self?.updateStatus() }
        actions.setAutoClean = { [weak self] on in self?.isAutoCleanEnabled = on }
        actions.setLaunchAtLogin = { [weak self] on in self?.setLaunchAtLogin(on) }
        actions.setThresholdNotify = { [weak self] on in self?.isThresholdNotifyEnabled = on }
        actions.setExitChangeNotify = { [weak self] on in self?.isExitChangeNotifyEnabled = on }
        actions.installProxy = { [weak self] in
            self?.menu.cancelTracking()
            self?.installProxy()
        }
        actions.uninstallProxy = { [weak self] in
            self?.menu.cancelTracking()
            self?.uninstallProxy()
        }
        actions.copyProxyPrefix = { [weak self] in self?.copyProxyPrefix() }
        actions.purgeLogs = { [weak self] in
            self?.menu.cancelTracking()
            self?.purgeLogsAction()
        }
        actions.relayout = { [weak self] in self?.relayoutMenuPanel() }

        let dashboard = DashboardView(
            report: report,
            settings: PanelSettings(autoClean: isAutoCleanEnabled,
                                    launchAtLogin: isLaunchAtLoginEnabled(),
                                    thresholdNotify: isThresholdNotifyEnabled,
                                    exitChangeNotify: isExitChangeNotifyEnabled),
            actions: actions
        )

        let hosting = SwipeHostingView(rootView: dashboard)
        hosting.delegateRef = self
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)
        hostingView = hosting

        let cardItem = NSMenuItem()
        cardItem.view = hosting
        menu.addItem(cardItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "退出 VibeGauge", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// 内容高度变了（切 Tab / 数据到达 / 卡片增减）→ 按新 fittingSize 改 frame。
    /// 实测 macOS 14：NSMenu 打开后会跟着自定义视图的 frame 实时重排（菜单窗口高度随之变），不需要关掉重开。
    private func relayoutMenuPanel() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self, let h = self.hostingView else { return }
            let size = h.fittingSize
            guard abs(size.height - h.frame.height) > 1 else { return }
            let before = h.window?.frame.height ?? -1
            h.frame.size = size
            self.log.debug("relayout fitting=\(Int(size.height)) menuWindow before=\(Int(before))")
        }
    }

    // MARK: - Actions
    // kill 里有 300ms 等待，rm -rf 走盘：都不在主线程做
    @objc func cleanOrphansAction() {
        let targets = currentReport.orphans
        guard !targets.isEmpty else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = ProcessScanner.shared.killProcesses(targets)
            DispatchQueue.main.async {
                self?.sendNotification(
                    title: "清理完成",
                    body: "已释放 \(r.killed) 个断链 AI 进程，回收 \(String(format: "%.0f", r.freedMB)) MB 内存。" + (r.skipped > 0 ? "（\(r.skipped) 个已自行退出或 pid 变化，已跳过）" : "")
                )
                self?.updateStatus()
            }
        }
    }

    /// 删文件是不可逆动作 → 先弹确认，把"删什么、删多少、会失去什么、能不能捞回来"全写清楚
    @objc func purgeLogsAction() {
        let days = ProcessScanner.shared.logRetentionDays
        let items = currentReport.disk.filter { $0.purgeable && $0.oldMB >= 1 }
        let totalMB = items.reduce(0.0) { $0 + $1.oldMB }
        let totalFiles = items.reduce(0) { $0 + $1.oldFiles }
        guard totalFiles > 0 else { return }

        let alert = NSAlert()
        alert.messageText = "清理 \(days) 天前的会话记录？"
        alert.informativeText = items.map {
            String(format: "· %@：%d 个文件 %.0f MB\n  %@", $0.label, $0.oldFiles, $0.oldMB, $0.note)
        }.joined(separator: "\n")
        + String(format: "\n\n合计 %d 个文件 %.2f GB，移入废纸篓（可恢复）。\n近 %d 天的一个都不动。",
                 totalFiles, totalMB / 1024, days)
        alert.alertStyle = .warning
        alert.addButton(withTitle: "移入废纸篓")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = ProcessScanner.shared.purgeOldSessionLogs(olderThanDays: days)
            DispatchQueue.main.async {
                self?.sendNotification(
                    title: "会话记录已清理",
                    body: String(format: "%d 个文件、%.2f GB 已移入废纸篓。", r.files, r.freedMB / 1024)
                        + (r.failed > 0 ? "（\(r.failed) 个失败，多半是权限）" : "")
                )
                self?.updateStatus()
            }
        }
    }

    @objc func cleanNPXAction() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let freedMB = ProcessScanner.shared.cleanNPXCache()
            DispatchQueue.main.async {
                self?.sendNotification(
                    title: "NPX 缓存已清理",
                    body: "已清空 ~/.npm/_npx 目录，释放约 \(String(format: "%.1f", freedMB)) MB 磁盘空间。"
                )
                self?.updateStatus()
            }
        }
    }

    func installProxy() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var msg = "已安装并启动，前缀 \(ProxyManager.shared.prefix)，登录自启。"
            do { try ProxyManager.shared.install() } catch { msg = "安装失败：\(error.localizedDescription)" }
            DispatchQueue.main.async {
                self?.sendNotification(title: "API 记账代理", body: msg)
                self?.updateStatus()
            }
        }
    }

    func uninstallProxy() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            ProxyManager.shared.uninstall()
            DispatchQueue.main.async {
                self?.sendNotification(title: "API 记账代理", body: "已停止并卸载。记账文件保留在 ~/.config/vibegauge/。")
                self?.updateStatus()
            }
        }
    }

    func copyProxyPrefix() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(ProxyManager.shared.prefix, forType: .string)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                print("Toggle launch error: \(error)")
            }
        }
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    @objc func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
