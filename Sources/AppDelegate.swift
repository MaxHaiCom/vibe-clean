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

        DispatchQueue.global(qos: .utility).async { ProxyManager.shared.syncIfInstalled() }   // 包里脚本更新了就热替换
        updateStatus()

        timer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: true) { [weak self] _ in
            self?.updateStatus()
        }

        setupAutoCleanTimer()
    }

    private func setupAutoCleanTimer() {
        autoCleanTimer?.invalidate()
        autoCleanTimer = nil

        if isAutoCleanEnabled {
            autoCleanTimer = Timer.scheduledTimer(withTimeInterval: 1800.0, repeats: true) { [weak self] _ in
                self?.performSilentAutoClean()
            }
        }
    }

    private func performSilentAutoClean() {
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
    private static let tabCount = 3

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
            }
        }
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

    private func renderStatusButton(report: ScanReport) {
        guard let button = statusItem.button else { return }
        button.image = renderChipFrameImage(percentage: report.freePercentage)
        button.imagePosition = .imageOnly
        button.title = ""
        button.attributedTitle = NSAttributedString(string: "")
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
        actions.installProxy = { [weak self] in
            self?.menu.cancelTracking()
            self?.installProxy()
        }
        actions.uninstallProxy = { [weak self] in
            self?.menu.cancelTracking()
            self?.uninstallProxy()
        }
        actions.copyProxyPrefix = { [weak self] in self?.copyProxyPrefix() }
        actions.relayout = { [weak self] in self?.relayoutMenuPanel() }

        let dashboard = DashboardView(
            report: report,
            settings: PanelSettings(autoClean: isAutoCleanEnabled, launchAtLogin: isLaunchAtLoginEnabled()),
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
