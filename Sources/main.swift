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

    // 限流响应头 → 额度（各家写法不同，统一按"去掉 limit/remaining/reset 后同族"配对）
    do {
        // Anthropic：族名在前，reset 是 ISO8601
        let a = ProcessScanner.parseRateLimitHeaders([
            "anthropic-ratelimit-requests-limit": "1000",
            "anthropic-ratelimit-requests-remaining": "900",
            "anthropic-ratelimit-requests-reset": "2026-09-18T12:00:00Z",
            "anthropic-ratelimit-tokens-limit": "100000",
            "anthropic-ratelimit-tokens-remaining": "20000",      // 更紧 → 应该选这族
            "anthropic-ratelimit-tokens-reset": "2026-09-18T12:00:00Z",
        ], now: now)!
        precondition(a.usedPct == 80 && a.label == "tokens", "实际 \(a)")
        precondition(a.resetsAt != nil)

        // OpenAI：kind 在中间，reset 是时长
        let o = ProcessScanner.parseRateLimitHeaders([
            "x-ratelimit-limit-requests": "500",
            "x-ratelimit-remaining-requests": "125",
            "x-ratelimit-reset-requests": "6m0s",
        ], now: now)!
        precondition(o.usedPct == 75 && o.label == "requests", "实际 \(o)")
        precondition(abs((o.resetsAt ?? 0) - (now + 360)) < 1, "6m0s = 360 秒")

        // GitHub/通用：epoch 秒（真实抓的样本形态）
        let g = ProcessScanner.parseRateLimitHeaders([
            "x-ratelimit-limit": "60", "x-ratelimit-remaining": "58",
            "x-ratelimit-used": "2", "x-ratelimit-resource": "core",
            "x-ratelimit-reset": "1789727826",
        ], now: now)!
        precondition(g.usedPct == 3, "58/60 → 已用 3%，实际 \(g.usedPct)")
        precondition(abs((g.resetsAt ?? 0) - 1789727826) < 1)

        // 毫秒时间戳 / 纯相对秒数
        precondition(abs((ProcessScanner.parseResetValue("1789727826000", now: now) ?? 0) - 1789727826) < 1)
        precondition(abs((ProcessScanner.parseResetValue("30", now: now) ?? 0) - (now + 30)) < 1)
        precondition(abs((ProcessScanner.parseResetValue("1h2m3s", now: now) ?? 0) - (now + 3723)) < 1)
        // 没有 limit/remaining 配对就不瞎猜
        precondition(ProcessScanner.parseRateLimitHeaders(["x-ratelimit-reset": "60"], now: now) == nil)
        precondition(ProcessScanner.parseRateLimitHeaders(["content-type": "application/json"], now: now) == nil)
    }

    // 记账覆盖体检：只抠变量名与主机，同一行的 key 一律不碰
    do {
        let pfx = "http://127.0.0.1:18790/"
        let a = ProcessScanner.parseBaseURLLine("  export ANTHROPIC_BASE_URL=http://127.0.0.1:18790/https://open.bigmodel.cn/api/anthropic", proxyPrefix: pfx)!
        precondition(a.name == "ANTHROPIC_BASE_URL" && a.host == "open.bigmodel.cn" && a.proxied)
        let b = ProcessScanner.parseBaseURLLine("OPENAI_API_BASE='https://api.deepseek.com/v1'", proxyPrefix: pfx)!
        precondition(b.host == "api.deepseek.com" && !b.proxied)
        precondition(ProcessScanner.parseBaseURLLine("# ANTHROPIC_BASE_URL=https://x.com", proxyPrefix: pfx) == nil, "注释行不算")
        precondition(ProcessScanner.parseBaseURLLine("export ANTHROPIC_API_KEY=sk-ant-xxxx", proxyPrefix: pfx) == nil, "key 行不该被当成 BASE_URL")
        precondition(ProcessScanner.parseBaseURLLine("alias cc='claude'", proxyPrefix: pfx) == nil)
        // zsh 里这些行普遍以续行符结尾，别被它吃掉
        let c = ProcessScanner.parseBaseURLLine("    ANTHROPIC_BASE_URL=http://127.0.0.1:18790/https://openrouter.ai/api \\", proxyPrefix: pfx)!
        precondition(c.host == "openrouter.ai" && c.proxied, "实际 \(c)")
        let d = ProcessScanner.parseBaseURLLine("  ANTHROPIC_BASE_URL=\"http://127.0.0.1:18790/http://localhost:18080\" \\", proxyPrefix: pfx)!
        precondition(d.host == "localhost:18080" && d.proxied, "实际 \(d)")
    }

    // 燃烧速率：窗口长度 + 重置点 → 不用攒历史采样
    do {
        // 5h 窗口过了 1 小时用掉 20% → 4%/h，到重置(还剩 4h)会到 100%
        let w = QuotaWindow(usedPct: 20, resetsAt: now + 4 * 3600, capturedAt: now, windowSeconds: 5 * 3600)
        let b = w.burn(now: now)!
        precondition(abs(b.pctPerHour - 20.0) < 0.01, "1 小时用 20% = 20%/h，实际 \(b.pctPerHour)")
        precondition(b.projectedAtReset == 100, "实际 \(b.projectedAtReset)")
        precondition(b.exhaustAt != nil && abs(b.exhaustAt! - (now + 4 * 3600)) < 60)
        // 慢速：4h 才用 10% → 到重置只有 12%，不该报"会打满"
        let slow = QuotaWindow(usedPct: 10, resetsAt: now + 3600, capturedAt: now, windowSeconds: 5 * 3600)
        precondition(slow.burn(now: now)!.exhaustAt == nil)
        // 窗口刚开头 / 没窗口长度 / 已过重置 → 一律不推算，不瞎猜
        precondition(QuotaWindow(usedPct: 5, resetsAt: now + 17_500, capturedAt: now, windowSeconds: 5 * 3600).burn(now: now) == nil)  // 窗口才过 500 秒
        precondition(QuotaWindow(usedPct: 50, resetsAt: now + 3600, capturedAt: now).burn(now: now) == nil)
        precondition(QuotaWindow(usedPct: 50, resetsAt: now - 1, capturedAt: now, windowSeconds: 5 * 3600).burn(now: now) == nil)
        precondition(QuotaWindow(usedPct: 100, resetsAt: now + 3600, capturedAt: now, windowSeconds: 5 * 3600).burn(now: now) == nil, "已打满不推算")

        // 近期速度优先：窗口均速只有 4%/h，但近 30 分钟在以 60%/h 猛烧 → 必须按近期算
        var hot = QuotaWindow(usedPct: 20, resetsAt: now + 4 * 3600, capturedAt: now, windowSeconds: 5 * 3600)
        hot.recentPctPerHour = 60; hot.recentSpanMinutes = 30
        let hb = hot.burn(now: now)!
        precondition(hb.isRecent && hb.basis == "近 30 分钟")
        precondition(hb.projectedAtReset == 260, "20 + 60*4 = 260，实际 \(hb.projectedAtReset)")
        precondition(hb.exhaustAt != nil && abs(hb.exhaustAt! - (now + 80.0 / 60 * 3600)) < 60)
        // 跨度不足 10 分钟 → 噪声太大，退回窗口均速
        var noisy = QuotaWindow(usedPct: 20, resetsAt: now + 4 * 3600, capturedAt: now, windowSeconds: 5 * 3600)
        noisy.recentPctPerHour = 60; noisy.recentSpanMinutes = 3
        precondition(noisy.burn(now: now)!.basis == "本窗口均")
        // 有近期速度时，窗口刚开头也能算（不必等满 15 分钟）
        var early = QuotaWindow(usedPct: 2, resetsAt: now + 17_700, capturedAt: now, windowSeconds: 5 * 3600)
        early.recentPctPerHour = 12; early.recentSpanMinutes = 15
        precondition(early.burn(now: now)?.isRecent == true)
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
        let burn = q.burn(now: now).map {
            String(format: ", %.1f%%/h→重置时 %d%%%@", $0.pctPerHour, $0.projectedAtReset,
                   $0.exhaustAt.flatMap { Fmt.countdown(to: $0, now: now) }.map { " ⚡\($0)后打满" } ?? "")
        } ?? ""
        return "  \(label)=\(q.effectivePct(now: now))%(raw \(q.usedPct), 重置 \(reset), 采集 \(age)\(burn))"
    }
    for l in r.detectedLLMs {
        print("\(l.isRunning ? "●" : "○") \(l.name) [\(l.tier)] \(l.detail)" + w("5H", l.fiveHour) + w("W", l.sevenDay) + w("\(l.secondaryPoolName)5H", l.secondaryFiveHour) + w("\(l.secondaryPoolName)W", l.secondarySevenDay) + (l.hasQuota ? "" : "  | \(l.quotaSubtitle)"))
    }
    let rs = ProcessScanner.shared.codexRemoteStatus()
    print("Codex 远程 \(rs.host): \(rs.ok ? "已连上" : "未连上") · \(rs.ageSeconds)s 前拉取")
    let a = r.api
    let cov = a.coverage
    print("--- 记账覆盖 \(cov.proxiedCount)/\(cov.entries.count) 处走代理 ---")
    for e in cov.entries { print("  \(e.proxied ? "✓" : "✗") \(e.name) → \(e.host)  (\(e.file):\(e.line))") }
    print("--- API 代理 --- 安装=\(a.installed) 运行=\(a.running) 端口=\(a.port) 启动后调用=\(a.callsSinceStart)")
    print("  价目表: " + (a.hasPriceTable ? "已配置 \(a.priceAsOf)" : "未配置（~/.config/vibegauge/prices.json）"))
    for p in a.providers {
        print("  \(p.provider) [\(p.host)] 今日 \(p.calls) 次 ctx \(p.ctx) cache \(p.cacheRead) out \(p.out) think \(p.think) 模型 \(p.models.joined(separator: ",")) \(p.plan) \(p.balanceText) \(p.fiveHour.map { "5H \($0.usedPct)%" } ?? "") \(p.sevenDay.map { "W \($0.usedPct)%" } ?? "") \(p.monthly.map { "M \($0.usedPct)%" } ?? "") \(p.quotaError)")
        print(String(format: "    延迟 p50 %@ p95 %@ 最慢 %@ · 错误 %d(%.1f%%) 429 %d · 花费 %@ · key %@",
                     Fmt.ms(p.p50ms), Fmt.ms(p.p95ms), Fmt.ms(p.maxms), p.errors, p.errorRate, p.count429,
                     p.cost.map { String(format: "%.4f %@", $0, p.costCurrency) } ?? "—",
                     p.keys.map { "\($0.fingerprint):\($0.calls)" }.joined(separator: " ")))
        if let hw = p.headerWindow { print("    限流头: \(p.headerLabel) 已用 \(hw.usedPct)% 重置 \(Fmt.countdown(to: hw.resetsAt, now: now) ?? "?")") }
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
