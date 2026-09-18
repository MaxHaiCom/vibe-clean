import Cocoa

// `VibeClean --install-proxy` / `--uninstall-proxy`：命令行装卸 API 记账代理（与菜单同一条代码路径）
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

// `VibeClean --selftest`：不起 UI，校验纯函数 + 打印一次完整扫描结果（档位/额度/Token 去重后数据）
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

    let t0 = Date()
    let r = ProcessScanner.shared.scan()
    let t1 = Date()
    print(String(format: "scan 耗时 %.0f ms", t1.timeIntervalSince(t0) * 1000))
    print(String(format: "内存 可用%d%%  已用 %.1f/%.1f GB  swap %.2f GB  压缩 %.2f GB", r.freePercentage, r.usedMemoryGB, r.totalMemoryGB, r.swapUsedGB, r.compressorGB))
    print(String(format: "磁盘 剩余 %.1f/%.1f GB  负载 %.2f  NPX %.0f MB  MCP %d 进程 %.0f MB", r.diskFreeGB, r.diskTotalGB, r.loadAvg1m, r.npxCacheMB, r.activeMCPProcessCount, r.activeMCPTotalMemMB))
    print("孤儿 \(r.totalOrphanCount) 个 \(Int(r.totalOrphanMemMB)) MB: " + r.orphanedGroups.map { "\($0.serviceName)x\($0.processCount)" }.joined(separator: ", "))
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
    for p in a.providers {
        print("  \(p.provider) [\(p.host)] 今日 \(p.calls) 次 ctx \(p.ctx) cache \(p.cacheRead) out \(p.out) think \(p.think) 模型 \(p.models.joined(separator: ",")) \(p.plan) \(p.balanceText) \(p.fiveHour.map { "5H \($0.usedPct)%" } ?? "") \(p.sevenDay.map { "W \($0.usedPct)%" } ?? "") \(p.quotaError)")
    }
    print("--- Token ---")
    let t = r.tokens
    print(String(format: "今日 %d 次调用  上下文 %lld  缓存读 %lld  命中 %.1f%%  输出 %lld  思考 %lld", t.todayTurns, t.todayContext, t.todayCacheRead, t.todayCacheHitRate, t.todayOutput, t.todayThinking))
    for i in t.recentInteractions {
        print(String(format: "  %@ %@  ctx %d  out %d  think %d  hit %.1f%%  [%@]", Fmt.modelDisplayName(i.model), Fmt.ago(Int(now - i.timestamp)), i.contextTokens, i.outputTokens, i.thinkingTokens, i.cacheHitRate, i.id))
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
