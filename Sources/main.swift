import Cocoa

// `VibeGauge --install-proxy` / `--uninstall-proxy`：命令行装卸 API 记账代理（与菜单同一条代码路径）
if CommandLine.arguments.contains("--install-proxy") {
    do {
        try ProxyManager.shared.install()
        print("已安装并启动：\(ProxyManager.shared.prefix)  日志 \(ProxyManager.shared.logPath)")
    } catch {
        print("安装失败：\(error.localizedDescription)")
        exit(1)
    }
    exit(0)
}
if CommandLine.arguments.contains("--uninstall-proxy") {
    ProxyManager.shared.uninstall()
    print("已卸载")
    exit(0)
}

// `VibeGauge --selftest`：不起 UI，校验纯函数 + 打印一次完整扫描结果（档位/额度/Token 去重后数据）
if CommandLine.arguments.contains("--selftest") {
    precondition(Fmt.modelDisplayName("claude-fable-5-1") == "Fable 5.1")
    precondition(Fmt.modelDisplayName("claude-opus-5") == "Opus 5")
    precondition(Fmt.modelDisplayName("claude-sonnet-4-5-20250929") == "Sonnet 4.5")
    precondition(Fmt.modelDisplayName("claude-3-7-sonnet-20250219") == "Sonnet 3.7")
    precondition(ProcessScanner.codexPlanLabel("prolite") == "Pro Lite")
    precondition(ProcessScanner.codexPlanLabel("plus") == "Plus")
    let now = Date().timeIntervalSince1970
    precondition(QuotaWindow(usedPct: 66, resetsAt: now - 1, capturedAt: nil).effectivePct(now: now) == 0)
    precondition(QuotaWindow(usedPct: 66, resetsAt: now + 100, capturedAt: nil).effectivePct(now: now) == 66)
    precondition(Fmt.countdown(to: now + 90, now: now) == "1m")
    precondition(Fmt.countdown(to: now + 6540, now: now) == "1h49m")
    precondition(Fmt.countdown(to: now + 2 * 86400 + 10 * 3600, now: now) == "2d10h")
    precondition(Fmt.countdown(to: now - 5, now: now) == "已重置")
    precondition(Fmt.parseISODate("2026-09-19T10:34:27.346461+00:00") != nil)   // grok 6 位小数秒
    precondition(Fmt.parseISODate("2026-09-17T09:07:45.133Z") != nil)           // claude 3 位
    precondition(Fmt.parseISODate("2026-09-17T03:14:39Z") != nil)               // 无小数

    // 探测只看可执行文件路径：别人 grep 这些名字不该算"在跑"
    precondition(ProcessScanner.isClaudeCLISession(cmd: "claude --resume abc"))
    precondition(!ProcessScanner.isClaudeCLISession(cmd: "/bin/zsh -c ps -ax | grep claude"))
    precondition(ProcessScanner.isCodexCLISession(cmd: "node /Users/x/.npm-global/bin/codex --foo"))
    precondition(!ProcessScanner.isCodexCLISession(cmd: "/Users/x/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex-path/rg"))
    precondition(!ProcessScanner.isCodexCLISession(cmd: "ssh host codex mcp-server"))

    // Codex 额度耗尽文案里的重置时刻
    precondition(Fmt.parseUsageLimitReset("You've hit your usage limit. Visit https://x to purchase more credits or try again at Sep 19th, 2026 5:03 PM.") != nil)
    precondition(Fmt.parseUsageLimitReset("try again at Oct 1st, 2026 12:00 AM") != nil)
    precondition(Fmt.parseUsageLimitReset("no reset info here") == nil)

    // 压力信号排序：按"离各自报警线的距离"，不按百分比（内存 60% 不该压住额度 55%）
    do {
        var s = ScanReport()
        s.totalMemoryGB = 64; s.freePercentage = 40          // 内存已用 60%，线 85 → margin -25
        s.diskTotalGB = 1000; s.diskFreeGB = 500; s.diskFreePct = 50   // 已用 50%，线 90 → margin -40
        s.detectedLLMs = [DetectedLLMRuntime(name: "Claude", isRunning: true, tier: "Max", detail: "",
                                             fiveHour: QuotaWindow(usedPct: 55, resetsAt: now + 3600, capturedAt: now))]
        precondition(s.tightest?.short == "内存", "60% 内存该压住 55% 额度（离线更近）")
        precondition(s.tightest?.level == 0)
        s.detectedLLMs[0].fiveHour = QuotaWindow(usedPct: 82, resetsAt: now + 3600, capturedAt: now)
        precondition(s.tightest?.short == "Claude 5h" && s.tightest?.level == 1, "额度 82% 越线 → 最紧且报警")
        s.detectedLLMs[0].fiveHour = QuotaWindow(usedPct: 99, resetsAt: now - 1, capturedAt: now)
        precondition(s.pressures.first(where: { $0.short == "Claude 5h" })?.pct == 0, "过了重置点的旧值不许再报警")
        precondition(s.pressures.contains { $0.short == "磁盘" })
    }

    // 百分位取最近秩：p95 一定落在某次真实调用上
    precondition(Fmt.percentile([100], 0.95) == 100)
    precondition(Fmt.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.5) == 5)
    precondition(Fmt.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.95) == 10)
    precondition(Fmt.percentile([], 0.5) == 0)
    precondition(Fmt.ms(0) == "—" && Fmt.ms(312) == "312ms" && Fmt.ms(4298) == "4.3s" && Fmt.ms(62_000) == "1m02s")

    // 价目表：ctx 是"全部输入"，算价前要把缓存读/写扣出来，否则新鲜 token 会被重复计价
    do {
        let t = ProcessScanner.PriceTable(json: [
            "_currency": "CNY", "_asof": "2026-09-18",
            "glm-4.7": ["in": 4.0, "cache_read": 1.0, "cache_write": 5.0, "out": 12.0],
            "zero-price-placeholder": ["in": 0, "out": 0],
        ])
        // 新鲜 60w + 缓存读 30w + 缓存写 10w + 输出 10w
        let c = t.cost(model: "glm-4.7", ctx: 1_000_000, cacheRead: 300_000, cacheWrite: 100_000, out: 100_000)!
        precondition(abs(c - (0.6 * 4.0 + 0.3 * 1.0 + 0.1 * 5.0 + 0.1 * 12.0)) < 1e-9, "算出来 \(c)")
        precondition(t.cost(model: "glm-4.7-flash", ctx: 1_000_000, cacheRead: 0, cacheWrite: 0, out: 0) != nil, "前缀命中")
        precondition(t.cost(model: "unknown-model", ctx: 999, cacheRead: 0, cacheWrite: 0, out: 9) == nil, "没价的模型不许估")
        precondition(t.cost(model: "zero-price-placeholder", ctx: 999, cacheRead: 0, cacheWrite: 0, out: 9) == nil, "占位行不算价")
        precondition(ProcessScanner.PriceTable().isEmpty)
    }

    // 订阅制 Coding Plan 的额度估算：滚动窗口内的请求数 ÷ 上限
    do {
        let stamps: [TimeInterval] = (0..<600).map { now - Double($0) * 10 }      // 最近 100 分钟里 600 次
        let w = ProcessScanner.rollingWindow(stamps, seconds: 5 * 3600, limit: 1200, now: now)!
        precondition(w.usedPct == 50, "600/1200 该是 50%，实际 \(w.usedPct)")
        precondition(abs((w.resetsAt ?? 0) - (stamps.min()! + 5 * 3600)) < 1, "重置点 = 窗口内最早一次 + 窗口长")
        let old = ProcessScanner.rollingWindow([now - 6 * 3600], seconds: 5 * 3600, limit: 1200, now: now)!
        precondition(old.usedPct == 0, "窗口外的调用不该算")
        precondition(ProcessScanner.rollingWindow(stamps, seconds: 3600, limit: 0, now: now) == nil, "没填上限就不估")
    }

    // 会话日志保留期硬下限 7 天（本工具自己要读近两天的文件算额度）
    precondition(ProcessScanner.effectiveRetention(30) == 30)
    precondition(ProcessScanner.effectiveRetention(3) == 7)
    precondition(ProcessScanner.effectiveRetention(0) == 7)
    precondition(ProcessScanner.effectiveRetention(-99) == 7)

    // ssh 主机名会被拼进 shell 命令 → 只放行合法主机名
    precondition(ProcessScanner.isValidSSHHost("mac-mini"))
    precondition(ProcessScanner.isValidSSHHost("user@192.168.1.9"))
    precondition(!ProcessScanner.isValidSSHHost("mac-mini; rm -rf ~"))
    precondition(!ProcessScanner.isValidSSHHost("$(whoami)"))
    precondition(!ProcessScanner.isValidSSHHost("a`id`b"))
    precondition(!ProcessScanner.isValidSSHHost(""))

    let t0 = Date()
    let r = ProcessScanner.shared.scan()
    let t1 = Date()
    print(String(format: "scan 耗时 %.0f ms", t1.timeIntervalSince(t0) * 1000))
    print(String(format: "内存 可用%d%%  已用 %.1f/%.1f GB  swap %.2f GB  压缩 %.2f GB", r.freePercentage, r.usedMemoryGB, r.totalMemoryGB, r.swapUsedGB, r.compressorGB))
    print(String(format: "磁盘 剩余 %.1f/%.1f GB  负载 %.2f  NPX %.0f MB  MCP %d 进程 %.0f MB", r.diskFreeGB, r.diskTotalGB, r.loadAvg1m, r.npxCacheMB, r.activeMCPProcessCount, r.activeMCPTotalMemMB))
    print("孤儿 \(r.totalOrphanCount) 个 \(Int(r.totalOrphanMemMB)) MB: " + r.orphanedGroups.map { "\($0.serviceName)x\($0.processCount)" }.joined(separator: ", "))
    if !r.orphans.isEmpty || !r.protected.isEmpty {
        print("--- 会被清理的（逐条）---")
        for o in r.orphans { print(String(format: "  pid %-7d %5.0f MB  %@", o.pid, o.memMB, String(o.cmd.prefix(90)))) }
        print("--- 规则放过的（原因）---")
        for p in r.protected { print(String(format: "  pid %-7d %5.0f MB  [%@]  %@", p.pid, p.memMB, p.reason, String(p.cmd.prefix(70)))) }
    }
    print(String(format: "--- 磁盘：AI 工具目录合计 %.2f GB，可清理（%d 天前的会话记录）%.2f GB ---",
                 r.diskTotalAIGB, ProcessScanner.shared.logRetentionDays, r.purgeableMB / 1024))
    for d in r.disk {
        print(String(format: "  %@ %-16@ %7.0f MB (%d 文件)%@  %@", d.purgeable ? "🧹" : "🔒", d.label, d.totalMB, d.files,
                     d.purgeable ? String(format: "  其中旧 %.0f MB/%d 个", d.oldMB, d.oldFiles) : "", d.note))
    }
    print("--- 压力信号（图标画第一条）---")
    for s in r.pressures.prefix(8) {
        print(String(format: "  %-16@ %3d%%  线 %d/%d  margin %+d  level %d  %@", s.short, s.pct, s.warn, s.crit, s.margin, s.level, s.detail))
    }
    print("--- 平台 ---")
    func w(_ label: String, _ q: QuotaWindow?) -> String {
        guard let q = q else { return "" }
        let reset = Fmt.countdown(to: q.resetsAt, now: now) ?? "?"
        let age = q.ageSeconds(now: now).map { Fmt.ago($0) } ?? "?"
        return "  \(label)=\(q.effectivePct(now: now))%(raw \(q.usedPct), 重置 \(reset), 采集 \(age))"
    }
    for l in r.detectedLLMs {
        print("\(l.isRunning ? "●" : "○") \(l.name) [\(l.tier)] \(l.detail)" + w("5H", l.fiveHour) + w("W", l.sevenDay) + w("\(l.secondaryPoolName)5H", l.secondaryFiveHour) + w("\(l.secondaryPoolName)W", l.secondarySevenDay) + (l.hasQuota ? "" : "  | \(l.quotaSubtitle)"))
    }
    let rs = ProcessScanner.shared.codexRemoteStatus()
    print("Codex 远程 \(rs.host): \(rs.ok ? "已连上" : "未连上") · \(rs.ageSeconds)s 前拉取")
    let a = r.api
    print("--- API 代理 --- 安装=\(a.installed) 运行=\(a.running) 端口=\(a.port) 启动后调用=\(a.callsSinceStart)")
    print("  价目表: " + (a.hasPriceTable ? "已配置 \(a.priceAsOf)" : "未配置（~/.config/vibegauge/prices.json）"))
    for p in a.providers {
        print("  \(p.provider) [\(p.host)] 今日 \(p.calls) 次 ctx \(p.ctx) cache \(p.cacheRead) out \(p.out) think \(p.think) 模型 \(p.models.joined(separator: ",")) \(p.plan) \(p.balanceText) \(p.fiveHour.map { "5H \($0.usedPct)%" } ?? "") \(p.sevenDay.map { "W \($0.usedPct)%" } ?? "") \(p.monthly.map { "M \($0.usedPct)%" } ?? "") \(p.quotaError)")
        print(String(format: "    延迟 p50 %@ p95 %@ 最慢 %@ · 错误 %d(%.1f%%) 429 %d · 花费 %@ · key %@",
                     Fmt.ms(p.p50ms), Fmt.ms(p.p95ms), Fmt.ms(p.maxms), p.errors, p.errorRate, p.count429,
                     p.cost.map { String(format: "%.4f %@", $0, p.costCurrency) } ?? "—",
                     p.keys.map { "\($0.fingerprint):\($0.calls)" }.joined(separator: " ")))
        if p.quotaIsEstimate { print("    额度=估算 · \(p.estimateNote) · 上限 \(p.planLimitText)") }
    }
    print("--- Token ---")
    let t = r.tokens
    print(String(format: "今日 %d 次调用  上下文 %lld  缓存读 %lld  命中 %.1f%%  输出 %lld  思考 %lld", t.todayTurns, t.todayContext, t.todayCacheRead, t.todayCacheHitRate, t.todayOutput, t.todayThinking))
    for i in t.recentInteractions {
        print(String(format: "  %@ %@  ctx %d  out %d  think %d  hit %.1f%%  [%@]", Fmt.modelDisplayName(i.model), Fmt.ago(Int(now - i.timestamp)), i.contextTokens, i.outputTokens, i.thinkingTokens, i.cacheHitRate, i.id))
    }
    print("--- 各 CLI 今日用量 ---")
    for u in r.cliUsage {
        if u.hasTokens {
            print(String(format: "  %@: ctx %lld  cache %lld  out %lld  think %lld  %d 次  命中 %.1f%%", u.name, u.ctx, u.cacheRead, u.out, u.think, u.requests, u.cacheHitRate))
        } else {
            print("  \(u.name): \(u.turns) 轮 · \(u.note)")
        }
    }

    let t2 = Date()
    _ = ProcessScanner.shared.scanTokens()
    _ = ProcessScanner.shared.scanActiveLLMs()
    print(String(format: "二次轻量刷新耗时 %.0f ms (ticker 每秒跑的就是这个)", Date().timeIntervalSince(t2) * 1000))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
