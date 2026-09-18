import Foundation
import os

// MARK: - 数据模型

/// 一个候选孤儿进程：带完整命令行，供杀之前核对与在面板上预览
public struct OrphanProc: Identifiable {
    public var id: Int { pid }
    public let pid: Int
    public let cmd: String
    public let memMB: Double
    public let service: String
}

/// 被规则放过的进程 + 放过的原因（面板上要能说清"为什么没动它"）
public struct ProtectedProc: Identifiable {
    public var id: Int { pid }
    public let pid: Int
    public let cmd: String
    public let memMB: Double
    public let reason: String
}

public struct ServiceGroup: Identifiable {
    public var id: String { serviceName }
    public let serviceName: String
    public var processCount: Int
    public var totalMemMB: Double
    public var pids: [Int]
}

/// 一次 API 调用（同一 requestId 在 jsonl 里会写多行，按 requestId 去重后才是"一轮"）
public struct InteractionRecord: Identifiable, Equatable {
    public var id: String
    public var model: String
    public var timestamp: TimeInterval
    public var contextTokens: Int
    public var cacheReadTokens: Int
    public var outputTokens: Int
    public var thinkingTokens: Int

    public var cacheHitRate: Double {
        contextTokens > 0 ? Double(cacheReadTokens) / Double(contextTokens) * 100.0 : 0.0
    }
}

public struct TokenStats: Equatable {
    /// 最近 3 轮（跨所有会话，按时间倒序）
    public var recentInteractions: [InteractionRecord] = []

    /// 今日 = 本地日历日（按每轮 timestamp 归类，不按文件 mtime）
    public var todayTurns: Int = 0
    public var todayContext: Int64 = 0
    public var todayCacheRead: Int64 = 0
    public var todayOutput: Int64 = 0
    public var todayThinking: Int64 = 0
    public var todayCacheHitRate: Double {
        todayContext > 0 ? Double(todayCacheRead) / Double(todayContext) * 100.0 : 0.0
    }
}

/// 某个 CLI 今日自己的用量（各家日志能给多少就给多少，给不了的说明原因）
public struct CLIUsage: Identifiable {
    public var id: String { name }
    public let name: String
    public var requests: Int = 0
    public var ctx: Int64 = 0
    public var cacheRead: Int64 = 0
    public var out: Int64 = 0
    public var think: Int64 = 0
    public var turns: Int = 0
    public var note: String = ""          // 非空 = 本地拿不到 token，只能给这句说明
    public var hasTokens: Bool { ctx > 0 || out > 0 }
    public var cacheHitRate: Double { ctx > 0 ? Double(cacheRead) / Double(ctx) * 100.0 : 0.0 }
}

/// 一个额度窗口（5h / 周）：已用百分比 + 重置点 + 数据采集时间
public struct QuotaWindow: Equatable {
    public var usedPct: Int
    public var resetsAt: TimeInterval?
    public var capturedAt: TimeInterval?

    public func isExpired(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let r = resetsAt else { return false }
        return now >= r
    }

    /// 过了重置点 → 缓存里的旧值作废，视为 0%
    public func effectivePct(now: TimeInterval = Date().timeIntervalSince1970) -> Int {
        isExpired(now: now) ? 0 : usedPct
    }

    public func ageSeconds(now: TimeInterval = Date().timeIntervalSince1970) -> Int? {
        capturedAt.map { max(0, Int(now - $0)) }
    }
}

public struct SubQuota: Identifiable {
    public var id: String { name }
    public let name: String
    public let window: QuotaWindow
    public init(name: String, window: QuotaWindow) {
        self.name = name
        self.window = window
    }
}

/// 一个活跃 CLI 会话（详情页列出来：在哪个目录、跑了多久）
public struct SessionInfo: Identifiable {
    public var id: Int { pid }
    public let pid: Int
    public let cwd: String
    public let startedAgo: Int      // 秒
    public let memMB: Double
}

/// 详情页用的补充信息：平台级的订阅/账号/来源字段（只放本地文件里真实存在的，邮箱类一律不取）
public struct PlatformDetail {
    public var rows: [(String, String)] = []        // 展示用键值对
    public var sessions: [SessionInfo] = []
    public var sourceFiles: [String] = []           // 数据来自哪些文件
    public var extraPools: [(String, QuotaWindow)] = []   // 主卡没显示的桶（如 Codex Spark）
}

public struct DetectedLLMRuntime: Identifiable {
    public var id: String { name }
    public let name: String
    public let isRunning: Bool
    public let tier: String
    public let detail: String
    public var fiveHour: QuotaWindow? = nil
    public var sevenDay: QuotaWindow? = nil
    public var secondaryPoolName: String = ""
    public var secondaryFiveHour: QuotaWindow? = nil
    public var secondarySevenDay: QuotaWindow? = nil
    public var isFullWidth: Bool = false
    public var quotaSubtitle: String = ""
    /// 卡片第三行附加信息（API Key 卡片用：模型 + 今日 token）
    public var extraLine: String = ""
    /// 卡片第四行（API Key 卡片用：p95 延迟 / 错误率 / 花费）
    public var extraLine2: String = ""
    /// 一个套餐带多个模型各自额度（如 OpenCode Zen）：卡内只显示用得最紧的 3 个，其余折叠
    public var subQuotas: [SubQuota] = []

    public var platformDetail: PlatformDetail = PlatformDetail()

    public var hasQuota: Bool { fiveHour != nil || sevenDay != nil || secondaryFiveHour != nil || secondarySevenDay != nil }
}

/// 一个 API Key（只存代理写下的 SHA-256 前 8 位指纹，永不落明文）今日的用量
public struct APIKeyUsage: Identifiable {
    public var id: String { fingerprint }
    public let fingerprint: String
    public var calls: Int = 0
    public var errors: Int = 0
    public var ctx: Int64 = 0
    public var out: Int64 = 0
    public var lastTS: TimeInterval = 0
    public var cost: Double? = nil
    public var models: [String] = []
}

/// 经记账代理的某个上游：今日调用汇总 + 额度/余额
public struct APIProviderStatus: Identifiable {
    public var id: String { host }
    public let host: String
    public let provider: String
    public var calls: Int = 0
    public var errors: Int = 0
    public var ctx: Int64 = 0
    public var cacheRead: Int64 = 0
    public var out: Int64 = 0
    public var think: Int64 = 0
    public var lastTS: TimeInterval = 0
    public var models: [String] = []
    public var plan: String = ""
    public var fiveHour: QuotaWindow? = nil
    public var sevenDay: QuotaWindow? = nil
    public var balanceText: String = ""
    public var quotaError: String = ""
    public var cacheHitRate: Double { ctx > 0 ? Double(cacheRead) / Double(ctx) * 100.0 : 0.0 }

    // 可观测性（全部由 api-calls.jsonl 里已有的 status/ms/key 字段算出）
    public var p50ms: Int = 0
    public var p95ms: Int = 0
    public var maxms: Int = 0
    public var count429: Int = 0
    /// nil = 没配价目表，不估（不编价格）
    public var cost: Double? = nil
    public var costCurrency: String = ""
    public var keys: [APIKeyUsage] = []
    public var errorRate: Double { calls > 0 ? Double(errors) / Double(calls) * 100.0 : 0.0 }
}

public struct ProxyStatus {
    public var installed: Bool = false
    /// 价目表状态（没配就别在界面上编花费）
    public var hasPriceTable: Bool = false
    public var priceAsOf: String = ""

    public var running: Bool = false
    public var port: Int = 18790
    public var callsSinceStart: Int = 0
    public var providers: [APIProviderStatus] = []
}

public struct ScanReport {
    // 内存与虚拟内存
    public var freePercentage: Int = 0
    public var totalMemoryGB: Double = 0.0
    public var usedMemoryGB: Double = 0.0
    public var swapUsedGB: Double = 0.0
    public var compressorGB: Double = 0.0

    // 硬件与发热负载
    public var thermalStateString: String = "正常"
    public var loadAvg1m: Double = 0.0
    public var loadAvg5m: Double = 0.0
    public var diskFreeGB: Double = 0.0
    public var diskTotalGB: Double = 0.0
    public var diskFreePct: Double = 0.0

    // 各平台运行时 + 档位 + 额度
    public var detectedLLMs: [DetectedLLMRuntime] = []

    public var activeMCPProcessCount: Int = 0
    public var activeMCPTotalMemMB: Double = 0.0

    public var tokens: TokenStats = TokenStats()
    public var npxCacheMB: Double = 0.0

    // 各 CLI 今日自己的用量
    public var cliUsage: [CLIUsage] = []

    // API Key 调用（记账代理）
    public var api: ProxyStatus = ProxyStatus()

    // 断链孤儿
    public var orphanedGroups: [ServiceGroup] = []
    public var orphans: [OrphanProc] = []
    public var protected: [ProtectedProc] = []
    public var allOrphanPids: [Int] = []
    public var totalOrphanCount: Int = 0
    public var totalOrphanMemMB: Double = 0.0
}

// MARK: - 压力信号（菜单栏图标 + 阈值通知共用，纯计算可自测）

/// 一条统一方向的"压力"信号：pct 越大越紧张。
/// 额度本来就是"已用 %"；内存/磁盘取"已用 %"后与额度同向，可放在一起比。
public struct PressureSignal: Identifiable, Equatable {
    public enum Kind: Equatable { case quota, memory, disk }

    /// 去重键：通知状态按它记。额度键里带重置点，换窗口后自然是新键，能再报一次
    public let key: String
    public let short: String        // 短名，进图标旁的文字与通知标题
    public let pct: Int
    public let detail: String       // 通知正文
    public let kind: Kind

    public var id: String { key }

    /// 各信号自己的报警线：内存 85% 已用才算紧，磁盘要到 90%，额度 80% 就该收手
    public var warn: Int {
        switch kind {
        case .quota: return 80
        case .memory: return 85
        case .disk: return 90
        }
    }
    public var crit: Int {
        switch kind {
        case .quota: return 95
        case .memory: return 93
        case .disk: return 96
        }
    }
    /// 0 = 正常，1 = 警告，2 = 危急
    public var level: Int { pct >= crit ? 2 : (pct >= warn ? 1 : 0) }
    /// 离自己报警线还差多少（正数 = 已越线）。排序按它，而不是按 pct，
    /// 否则"内存已用 60%"会永远压住"额度已用 55%"，而后者其实更该被看见
    public var margin: Int { pct - warn }
}

public extension ScanReport {
    /// 全部压力信号，按"离各自报警线的距离"倒序。没数据的额度窗口不参与（不编）
    var pressures: [PressureSignal] {
        var out: [PressureSignal] = []

        func addQuota(_ w: QuotaWindow?, _ platform: String, _ pool: String) {
            guard let w = w else { return }
            let pct = w.effectivePct()
            var detail = "已用 \(pct)%"
            if let c = Fmt.countdown(to: w.resetsAt) { detail += " · 重置 \(c)" }
            let stamp = w.resetsAt.map { String(Int($0)) } ?? "na"
            out.append(PressureSignal(key: "quota:\(platform):\(pool)@\(stamp)",
                                      short: "\(platform) \(pool)", pct: pct, detail: detail, kind: .quota))
        }

        for l in detectedLLMs {
            addQuota(l.fiveHour, l.name, "5h")
            addQuota(l.sevenDay, l.name, "周")
            let sec = l.secondaryPoolName.isEmpty ? "副池" : l.secondaryPoolName
            addQuota(l.secondaryFiveHour, l.name, "\(sec) 5h")
            addQuota(l.secondarySevenDay, l.name, "\(sec) 周")
            for s in l.subQuotas { addQuota(s.window, l.name, s.name) }
        }
        for p in api.providers {
            addQuota(p.fiveHour, p.provider, "5h")
            addQuota(p.sevenDay, p.provider, "周")
        }

        if totalMemoryGB > 0 {
            out.append(PressureSignal(key: "mem", short: "内存", pct: max(0, 100 - freePercentage),
                                      detail: String(format: "已用 %.1f / %.1f GB · swap %.2f GB",
                                                     usedMemoryGB, totalMemoryGB, swapUsedGB), kind: .memory))
        }
        if diskTotalGB > 0 {
            out.append(PressureSignal(key: "disk", short: "磁盘", pct: Int((100.0 - diskFreePct).rounded()),
                                      detail: String(format: "剩余 %.0f GB / %.0f GB", diskFreeGB, diskTotalGB), kind: .disk))
        }

        return out.sorted { $0.margin != $1.margin ? $0.margin > $1.margin : $0.pct > $1.pct }
    }

    /// 最紧的那一条 —— 菜单栏图标画它
    var tightest: PressureSignal? { pressures.first }
}

// MARK: - 纯展示格式化（可自测）

public enum Fmt {
    /// "claude-fable-5-1" → "Fable 5.1"；"claude-sonnet-4-5-20250929" → "Sonnet 4.5"；"claude-3-7-sonnet-20250219" → "Sonnet 3.7"
    public static func modelDisplayName(_ raw: String) -> String {
        if raw.isEmpty { return "AI" }
        var s = raw.lowercased()
        for prefix in ["anthropic/", "models/", "claude-"] where s.hasPrefix(prefix) {
            s.removeFirst(prefix.count)
        }
        var parts = s.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, Int(last) != nil { parts.removeLast() } // 日期后缀
        let words = parts.filter { Int($0) == nil }.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        let nums = parts.filter { Int($0) != nil }
        let out = [words.joined(separator: " "), nums.joined(separator: ".")].filter { !$0.isEmpty }.joined(separator: " ")
        return out.isEmpty ? raw : out
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO8601 → epoch。ISO8601DateFormatter 只认 3 位小数秒，grok 写 6 位 → 先截到 3 位
    public static func parseISODate(_ raw: String?) -> TimeInterval? {
        guard var s = raw else { return nil }
        if let r = s.range(of: #"\.\d{4,}"#, options: .regularExpression) {
            s.replaceSubrange(r, with: s[r].prefix(4))
        }
        return (isoFrac.date(from: s) ?? isoPlain.date(from: s))?.timeIntervalSince1970
    }

    /// 距重置点倒计时："35m" / "1h49m" / "2d10h"；已过 → "已重置"；无数据 → nil
    public static func countdown(to resetsAt: TimeInterval?, now: TimeInterval = Date().timeIntervalSince1970) -> String? {
        guard let r = resetsAt else { return nil }
        let secs = Int(r - now)
        if secs <= 0 { return "已重置" }
        let m = secs / 60
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h\(m % 60)m" }
        return "\(h / 24)d\(h % 24)h"
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    public static func dateText(_ t: TimeInterval) -> String {
        dateFmt.string(from: Date(timeIntervalSince1970: t))
    }

    /// 紧凑相对时间（卡片脚注用）："刚刚" / "12m前" / "16h前" / "3d前"
    public static func agoShort(_ secs: Int) -> String {
        if secs < 60 { return "刚刚" }
        if secs < 3600 { return "\(secs / 60)m前" }
        if secs < 86400 { return "\(secs / 3600)h前" }
        return "\(secs / 86400)d前"
    }

    private static let usageResetFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yyyy h:mm a"
        return f
    }()

    /// Codex 额度耗尽文案里的重置时间："...try again at Sep 19th, 2026 5:03 PM." → epoch（按本机时区）
    public static func parseUsageLimitReset(_ message: String) -> TimeInterval? {
        guard let re = try? NSRegularExpression(pattern: #"try again (?:at|on)\s+([A-Za-z]{3,})\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})[,\s]+(\d{1,2}):(\d{2})\s*([AaPp])\.?[Mm]"#) else { return nil }
        let ns = message as NSString
        guard let m = re.firstMatch(in: message, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String { ns.substring(with: m.range(at: i)) }
        let month = String(g(1).prefix(3))
        let text = "\(month) \(g(2)), \(g(3)) \(g(4)):\(g(5)) \(g(6).uppercased())M"
        usageResetFormatter.timeZone = TimeZone.current
        return usageResetFormatter.date(from: text)?.timeIntervalSince1970
    }

    /// 最近秩百分位（样本少的时候比插值直观：p95 一定是某次真实调用的耗时）
    public static func percentile(_ values: [Int], _ p: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let s = values.sorted()
        let idx = Int((p * Double(s.count)).rounded(.up)) - 1
        return s[max(0, min(s.count - 1, idx))]
    }

    /// 毫秒 → "312ms" / "4.3s" / "1m02s"
    public static func ms(_ v: Int) -> String {
        if v <= 0 { return "—" }
        if v < 1000 { return "\(v)ms" }
        if v < 60_000 { return String(format: "%.1fs", Double(v) / 1000.0) }
        return String(format: "%dm%02ds", v / 60_000, (v % 60_000) / 1000)
    }

    /// 相对时间："刚刚" / "35秒前" / "12分钟前" / "3小时前"
    public static func ago(_ secs: Int) -> String {
        if secs < 8 { return "刚刚" }
        if secs < 60 { return "\(secs)秒前" }
        if secs < 3600 { return "\(secs / 60)分钟前" }
        return "\(secs / 3600)小时前"
    }
}

// MARK: - 扫描器

public final class ProcessScanner {
    public static let shared = ProcessScanner()

    private let lock = NSRecursiveLock()
    private let log = Logger(subsystem: "com.haifeng.vibegauge", category: "scan")
    private let home = FileManager.default.homeDirectoryForCurrentUser.path
    private let env = ProcessInfo.processInfo.environment

    // 缓存：JSON 文件按 mtime 缓存（~/.claude.json 有 200KB+，每秒解析太浪费）
    private var jsonCache: [String: (mtime: TimeInterval, json: [String: Any])] = [:]
    // 缓存：会话 jsonl 增量解析状态
    private struct FileParseState {
        var mtime: TimeInterval = 0
        var size: UInt64 = 0
        var parsedOffset: UInt64 = 0
        var head = Data()          // 文件前 256 字节指纹，识别原地重写 / 替换
        var turns: [String: InteractionRecord] = [:]
    }
    private var fileStates: [String: FileParseState] = [:]
    // 缓存：贵操作节流
    private var npxCache: (mb: Double, at: TimeInterval)? = nil
    private var ollamaCache: (count: Int, sub: String, at: TimeInterval)? = nil

    /// 由 launchd 托管的常驻服务：ppid 天然是 1，但它们是「该活着的」，绝不能当孤儿杀。
    /// 从 plist 的 Program / ProgramArguments 里取出非解释器的实参当特征（取解释器路径会保护掉所有 python/node，太宽）。
    private var launchdCache: (at: TimeInterval, tokens: [(token: String, label: String)])? = nil
    private let interpreters: Set<String> = ["python", "python3", "node", "bun", "deno", "ruby", "perl", "sh", "bash", "zsh", "env", "uvx", "npx", "uv", "npm", "pnpm", "yarn", "open", "osascript"]

    private func launchdProtectedTokens() -> [(token: String, label: String)] {
        let now = Date().timeIntervalSince1970
        if let c = launchdCache, now - c.at < 300 { return c.tokens }
        var out: [(String, String)] = []
        let fm = FileManager.default
        let dirs = ["\(home)/Library/LaunchAgents", "/Library/LaunchAgents", "/Library/LaunchDaemons"]
        for dir in dirs {
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".plist") {
                guard let data = try? Data(contentsOf: URL(fileURLWithPath: "\(dir)/\(n)")),
                      let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { continue }
                let label = plist["Label"] as? String ?? n
                var args: [String] = []
                if let prog = plist["Program"] as? String { args.append(prog) }
                if let pa = plist["ProgramArguments"] as? [String] { args.append(contentsOf: pa) }
                for a in args {
                    let base = String(a.split(separator: "/").last ?? "")
                    if a.hasPrefix("-") || base.isEmpty || interpreters.contains(base) { continue }
                    if a.count < 6 { continue }              // 太短的实参当特征会误伤
                    out.append((a, label))
                }
            }
        }
        launchdCache = (now, out)
        return out
    }

    private let whitelist = [
        "CleanMyMac", "figma-agent-bridge", "tailscale", "docker", "com.docker",
        "/System", "/usr/libexec", "/usr/sbin"
    ]

    private let serviceDefinitions: [(key: String, name: String)] = [
        ("apple-docs", "Apple Docs 接口服务"),
        ("chrome-devtools", "Chrome DevTools 自动化插件"),
        ("notebooklm", "NotebookLM 交互插件"),
        ("xcodebuildmcp", "Xcode 构建工具插件"),
        ("mcpvault", "Obsidian Vault 插件"),
        ("magicuidesign", "Magic UI 设计工具"),
        ("meigen", "Meigen 图像服务"),
        ("context7", "Context7 检索服务")
    ]

    // MARK: 会话判定（用户交互终端 vs 子脚本/MCP）

    private static func isShellWrapper(_ cmd: String) -> Bool {
        cmd.hasPrefix("/bin/zsh") || cmd.hasPrefix("/bin/bash") || cmd.hasPrefix("zsh") || cmd.hasPrefix("bash") || cmd.hasPrefix("sh ")
    }

    private static func binName(_ cmd: String) -> String {
        String(executablePath(cmd).split(separator: "/").last ?? "")
    }

    /// 命令行的第一个 token = 可执行文件路径。
    /// 探测必须只看这个，不能在整条命令行里找子串：任何 shell 命令（包括别人 grep 这些名字）都会命中，造成误判。
    private static func executablePath(_ cmd: String) -> String {
        String(cmd.split(separator: " ").first ?? "")
    }

    /// 某个 App/CLI 是否真的在跑：看可执行文件路径，且跳过 shell 包装器
    private static func isRunning(_ cmd: String, bundle: String, bins: [String]) -> Bool {
        let t = cmd.trimmingCharacters(in: .whitespaces)
        if isShellWrapper(t) { return false }
        let exe = executablePath(t).lowercased()
        if !bundle.isEmpty, exe.contains(bundle) { return true }
        let bin = String(exe.split(separator: "/").last ?? "")
        return bins.contains(bin)
    }

    public static func isClaudeCLISession(cmd: String) -> Bool {
        let t = cmd.trimmingCharacters(in: .whitespaces)
        if isShellWrapper(t) || t.contains("mcp-server") || t.contains("grep") { return false }
        return binName(t) == "claude"
    }

    public static func isCodexCLISession(cmd: String) -> Bool {
        let t = cmd.trimmingCharacters(in: .whitespaces)
        if isShellWrapper(t) { return false }
        if t.contains("mcp-server") || t.contains("ChatGPT for Chrome") || t.contains("chrome-extension") || t.contains("ssh") || t.contains("grep") { return false }
        // 同一会话派生出来的组件，不是独立会话
        if t.contains("codex-darwin") || t.contains("/vendor/") || t.contains("codex-path") || t.contains("/plugins/cache/") || t.contains("cua_node") { return false }
        let bin = binName(t)
        if bin == "codex" || bin == "codex.js" { return true }
        let parts = t.split(separator: " ")
        if bin.contains("node"), parts.count > 1, parts[1].contains("codex") { return true }
        return false
    }

    public static func isAgyCLISession(cmd: String) -> Bool {
        let t = cmd.trimmingCharacters(in: .whitespaces)
        if isShellWrapper(t) || t.contains("grep") { return false }
        for sub in ["agy-routed", "agy-batch", "agy-review", "agy-video"] where t.contains(sub) { return false }
        return binName(t) == "agy"
    }

    public static func isGrokCLISession(cmd: String) -> Bool {
        let t = cmd.trimmingCharacters(in: .whitespaces)
        if isShellWrapper(t) || t.contains("mcp-server") || t.contains("grep") { return false }
        return binName(t) == "grok"
    }

    // MARK: 基础工具

    private func execute(_ cmd: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", cmd]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    /// 按 mtime 缓存的 JSON 读取
    private func readJSON(_ path: String) -> [String: Any]? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mod = attrs[.modificationDate] as? Date else {
            jsonCache[path] = nil
            return nil
        }
        let mtime = mod.timeIntervalSince1970
        if let c = jsonCache[path], c.mtime == mtime { return c.json }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        jsonCache[path] = (mtime, json)
        return json
    }

    /// 读文件尾部 maxBytes（整行对齐由调用方处理）
    private func readTail(_ path: String, maxBytes: Int) -> String {
        guard let fh = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        let data = fh.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }

    private func parseISO(_ s: String?) -> TimeInterval? { Fmt.parseISODate(s) }

    private func clampPct(_ n: NSNumber?) -> Int? {
        guard let n = n else { return nil }
        return max(0, min(100, Int(round(n.doubleValue))))
    }

    // MARK: 进程表

    private struct RawProc {
        let pid: Int
        let ppid: Int
        let memMB: Double
        let cmd: String
    }

    /// 一批 pid 的 cwd（一次 lsof 拿完）
    private func cwds(of pids: [Int]) -> [Int: String] {
        guard !pids.isEmpty else { return [:] }
        let out = execute("lsof -p \(pids.map(String.init).joined(separator: ",")) -a -d cwd -Fpn 2>/dev/null")
        var map: [Int: String] = [:]
        var cur = 0
        for line in out.components(separatedBy: "\n") {
            if line.hasPrefix("p") { cur = Int(line.dropFirst()) ?? 0 }
            else if line.hasPrefix("n"), cur != 0 { map[cur] = String(line.dropFirst()) }
        }
        return map
    }

    /// 进程已运行秒数（ps etime）
    private func ages(of pids: [Int]) -> [Int: Int] {
        guard !pids.isEmpty else { return [:] }
        let out = execute("ps -o pid=,etime= -p \(pids.map(String.init).joined(separator: ","))")
        var map: [Int: Int] = [:]
        for line in out.components(separatedBy: "\n") {
            let f = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard f.count >= 2, let pid = Int(f[0]) else { continue }
            // etime: [[dd-]hh:]mm:ss
            var secs = 0
            let main = f[1].split(separator: "-")
            if main.count == 2 { secs += (Int(main[0]) ?? 0) * 86400 }
            let parts = (main.last ?? "").split(separator: ":").map { Int($0) ?? 0 }
            if parts.count == 3 { secs += parts[0] * 3600 + parts[1] * 60 + parts[2] }
            else if parts.count == 2 { secs += parts[0] * 60 + parts[1] }
            map[pid] = secs
        }
        return map
    }

    private struct SessionCounts {
        var claude = 0, codex = 0, agy = 0, grok = 0
        var ollama = false, cursor = false, lmStudio = false
        var pids: [CLIKind: [Int]] = [:]
        var mem: [Int: Double] = [:]
    }

    private func readProcs() -> [Int: RawProc] {
        var procs: [Int: RawProc] = [:]
        let out = execute("ps -axo pid,ppid,rss,command")
        for line in out.components(separatedBy: "\n").dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { continue }
            let parts = t.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = Int(parts[0]), let ppid = Int(parts[1]), let rssKB = Double(parts[2]) else { continue }
            procs[pid] = RawProc(pid: pid, ppid: ppid, memMB: rssKB / 1024.0, cmd: String(parts[3]))
        }
        return procs
    }

    private enum CLIKind { case claude, codex, agy, grok }

    private func countSessions(_ procs: [Int: RawProc]) -> SessionCounts {
        var c = SessionCounts()

        // 第一遍：命中的进程
        var matched: [Int: CLIKind] = [:]
        for p in procs.values {
            if ProcessScanner.isRunning(p.cmd, bundle: "/cursor.app/", bins: ["cursor"]) { c.cursor = true }
            if ProcessScanner.isRunning(p.cmd, bundle: "/ollama.app/", bins: ["ollama"]) { c.ollama = true }
            if ProcessScanner.isRunning(p.cmd, bundle: "lm studio.app/", bins: ["lm studio", "lmstudio"]) { c.lmStudio = true }
            guard p.ppid != 1 else { continue }
            if ProcessScanner.isClaudeCLISession(cmd: p.cmd) { matched[p.pid] = .claude }
            else if ProcessScanner.isCodexCLISession(cmd: p.cmd) { matched[p.pid] = .codex }
            else if ProcessScanner.isAgyCLISession(cmd: p.cmd) { matched[p.pid] = .agy }
            else if ProcessScanner.isGrokCLISession(cmd: p.cmd) { matched[p.pid] = .grok }
        }

        // 第二遍：一个会话 = 一棵进程树的根。CLI 会派生同名子进程（node 包装器 → 原生二进制 → 插件宿主），
        // 祖先已命中的就不再单独算一个会话，否则一个 Codex 会话会被数成 3 个。
        for (pid, kind) in matched {
            var cur = procs[pid]?.ppid ?? 1
            var hops = 0
            var nested = false
            while cur > 1, hops < 30 {
                if matched[cur] != nil { nested = true; break }
                cur = procs[cur]?.ppid ?? 1
                hops += 1
            }
            if nested { continue }
            c.pids[kind, default: []].append(pid)
            c.mem[pid] = procs[pid]?.memMB ?? 0
            switch kind {
            case .claude: c.claude += 1
            case .codex: c.codex += 1
            case .agy: c.agy += 1
            case .grok: c.grok += 1
            }
        }
        // Grok 双保险：~/.grok/active_sessions.json 里存活的 pid
        if c.grok == 0,
           let data = try? Data(contentsOf: URL(fileURLWithPath: "\(home)/.grok/active_sessions.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            c.grok = json.filter { ($0["pid"] as? Int).map { kill(pid_t($0), 0) == 0 } ?? false }.count
        }
        return c
    }

    // MARK: 全量扫描（8s 定时器）

    public func scan() -> ScanReport {
        refreshRemoteCodexIfDue()          // ssh 可能要几秒，放在锁外，不挡 ticker
        lock.lock(); defer { lock.unlock() }
        var report = ScanReport()

        // 1. memory_pressure
        for line in execute("memory_pressure").components(separatedBy: "\n") {
            if line.contains("System-wide memory free percentage:") {
                let parts = line.components(separatedBy: ":")
                if parts.count > 1 {
                    report.freePercentage = Int(parts[1].replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? 0
                }
            } else if line.contains("Pages used by compressor:") {
                let parts = line.components(separatedBy: ":")
                if parts.count > 1 {
                    let pages = Double(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0.0
                    report.compressorGB = pages * 16384.0 / (1024.0 * 1024.0 * 1024.0)
                }
            }
        }

        // 2. 总内存
        if let bytes = Double(execute("sysctl -n hw.memsize").trimmingCharacters(in: .whitespacesAndNewlines)) {
            report.totalMemoryGB = bytes / (1024.0 * 1024.0 * 1024.0)
            report.usedMemoryGB = report.totalMemoryGB * (1.0 - Double(report.freePercentage) / 100.0)
        }

        // 3. Swap
        let swapStr = execute("sysctl vm.swapusage")
        if let regex = try? NSRegularExpression(pattern: "used\\s*=\\s*([0-9\\.]+)M") {
            let ns = swapStr as NSString
            if let m = regex.firstMatch(in: swapStr, range: NSRange(location: 0, length: ns.length)) {
                report.swapUsedGB = (Double(ns.substring(with: m.range(at: 1))) ?? 0.0) / 1024.0
            }
        }

        // 4. 发热与负载
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: report.thermalStateString = "正常"
        case .fair: report.thermalStateString = "微热"
        case .serious: report.thermalStateString = "较高 (可能降频)"
        case .critical: report.thermalStateString = "严重过热"
        @unknown default: report.thermalStateString = "正常"
        }
        var loadavg = [Double](repeating: 0.0, count: 3)
        getloadavg(&loadavg, 3)
        report.loadAvg1m = loadavg[0]
        report.loadAvg5m = loadavg[1]

        // 5. 磁盘
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: "/"),
           let freeBytes = attrs[.systemFreeSize] as? Int64,
           let totalBytes = attrs[.systemSize] as? Int64 {
            report.diskFreeGB = Double(freeBytes) / (1024.0 * 1024.0 * 1024.0)
            report.diskTotalGB = Double(totalBytes) / (1024.0 * 1024.0 * 1024.0)
            if report.diskTotalGB > 0 { report.diskFreePct = report.diskFreeGB / report.diskTotalGB * 100.0 }
        }

        // 6. NPX 缓存（du 走盘慢，5 分钟节流）
        report.npxCacheMB = npxCacheSizeMB()

        // 7. 监听端口
        var listeningPids = Set<Int>()
        for line in execute("lsof -iTCP -sTCP:LISTEN -n -P").components(separatedBy: "\n").dropFirst() {
            let cols = line.split(whereSeparator: { $0.isWhitespace })
            if cols.count >= 2, let pid = Int(cols[1]) { listeningPids.insert(pid) }
        }

        // 8. 进程表 + 会话计数 + 活跃 MCP
        let procs = readProcs()
        let counts = countSessions(procs)
        let allKeywords = serviceDefinitions.map { $0.key } + ["_npx", "mcp"]
        func isRunner(_ lower: String) -> Bool {
            lower.contains("node") || lower.contains("npm") || lower.contains("python") || lower.contains("uv")
        }
        for p in procs.values where p.ppid != 1 {
            let lower = p.cmd.lowercased()
            if ProcessScanner.isClaudeCLISession(cmd: p.cmd) || ProcessScanner.isCodexCLISession(cmd: p.cmd)
                || ProcessScanner.isAgyCLISession(cmd: p.cmd) || ProcessScanner.isGrokCLISession(cmd: p.cmd) { continue }
            if isRunner(lower) && allKeywords.contains(where: { lower.contains($0) }) {
                report.activeMCPProcessCount += 1
                report.activeMCPTotalMemMB += p.memMB
            }
        }

        // 9. 孤儿：ppid==1 + 无监听端口 + 非白名单 + 非 launchd 托管 + runner + MCP 签名
        //    放过的都记下原因，面板要能解释"为什么没动它"
        let launchdTokens = launchdProtectedTokens()
        var orphanRoots = Set<Int>()
        var protectedList: [ProtectedProc] = []
        for (pid, p) in procs where p.ppid == 1 {
            let lower = p.cmd.lowercased()
            guard isRunner(lower), allKeywords.contains(where: { lower.contains($0) }) else { continue }
            if listeningPids.contains(pid) {
                protectedList.append(ProtectedProc(pid: pid, cmd: p.cmd, memMB: p.memMB, reason: "在监听端口（可能还有客户端会连）"))
                continue
            }
            if let hit = whitelist.first(where: { p.cmd.contains($0) }) {
                protectedList.append(ProtectedProc(pid: pid, cmd: p.cmd, memMB: p.memMB, reason: "白名单：\(hit)"))
                continue
            }
            if let hit = launchdTokens.first(where: { p.cmd.contains($0.token) }) {
                protectedList.append(ProtectedProc(pid: pid, cmd: p.cmd, memMB: p.memMB, reason: "launchd 托管：\(hit.label)"))
                continue
            }
            orphanRoots.insert(pid)
        }
        report.protected = protectedList.sorted { $0.memMB > $1.memMB }
        var allOrphans = orphanRoots
        var stack = Array(orphanRoots)
        while let curr = stack.popLast() {
            for (pid, p) in procs where p.ppid == curr && !allOrphans.contains(pid) {
                allOrphans.insert(pid)
                stack.append(pid)
            }
        }
        var groupMap: [String: (count: Int, mem: Double, pids: [Int])] = [:]
        for pid in allOrphans {
            guard let p = procs[pid] else { continue }
            let lower = p.cmd.lowercased()
            let name = serviceDefinitions.first(where: { lower.contains($0.key) })?.name ?? "其他已退出 AI 进程"
            var g = groupMap[name, default: (0, 0.0, [])]
            g.count += 1
            g.mem += p.memMB
            g.pids.append(pid)
            groupMap[name] = g
        }
        report.orphanedGroups = groupMap.map { ServiceGroup(serviceName: $0.key, processCount: $0.value.count, totalMemMB: $0.value.mem, pids: $0.value.pids) }
            .sorted { $0.totalMemMB > $1.totalMemMB }
        report.orphans = allOrphans.compactMap { pid -> OrphanProc? in
            guard let p = procs[pid] else { return nil }
            let lower = p.cmd.lowercased()
            let name = serviceDefinitions.first(where: { lower.contains($0.key) })?.name ?? "其他已退出 AI 进程"
            return OrphanProc(pid: pid, cmd: p.cmd, memMB: p.memMB, service: name)
        }.sorted { $0.memMB > $1.memMB }
        report.allOrphanPids = Array(allOrphans)
        report.totalOrphanCount = allOrphans.count
        report.totalOrphanMemMB = report.orphanedGroups.reduce(0.0) { $0 + $1.totalMemMB }

        // 10. Token 遥测 + 11. 各平台档位/额度 + 12. API Key 调用
        report.tokens = scanTokens()
        report.detectedLLMs = detectAllLLMRuntimes(counts)
        report.api = scanAPI()
        report.cliUsage = scanCLIUsage(claude: report.tokens)
        return report
    }

    /// 轻量探查（1s ticker）：只跑 ps 与小文件读取
    public func scanActiveLLMs() -> [DetectedLLMRuntime] {
        lock.lock(); defer { lock.unlock() }
        return detectAllLLMRuntimes(countSessions(readProcs()))
    }

    private func npxCacheSizeMB() -> Double {
        let now = Date().timeIntervalSince1970
        if let c = npxCache, now - c.at < 300 { return c.mb }
        let npxPath = "\(home)/.npm/_npx"
        var mb = 0.0
        if FileManager.default.fileExists(atPath: npxPath),
           let first = execute("/usr/bin/du -sk '\(npxPath)'").components(separatedBy: "\t").first,
           let kb = Double(first.trimmingCharacters(in: .whitespaces)) {
            mb = kb / 1024.0
        }
        npxCache = (mb, now)
        return mb
    }

    // MARK: 档位（只报数据里真实有的，查不到就说查不到，不猜）

    private func getClaudeTier() -> String {
        if let oa = readJSON("\(home)/.claude.json")?["oauthAccount"] as? [String: Any] {
            let rate = (oa["organizationRateLimitTier"] as? String ?? "").lowercased()   // e.g. default_claude_max_5x
            if rate.contains("max_20x") { return "Max 20x" }
            if rate.contains("max_5x") { return "Max 5x" }
            if rate.contains("max") { return "Max" }
            if rate.contains("enterprise") { return "Enterprise" }
            if rate.contains("team") { return "Team" }
            if rate.contains("pro") { return "Pro" }
            let orgType = (oa["organizationType"] as? String ?? "").lowercased()          // e.g. claude_max
            if orgType.contains("max") { return "Max" }
            if orgType.contains("pro") { return "Pro" }
            if (oa["billingType"] as? String ?? "").contains("subscription") { return "订阅" }
            return "已登录"
        }
        if env["ANTHROPIC_API_KEY"] != nil { return "API Key" }
        return "未登录"
    }

    /// OpenAI JWT 里的 chatgpt_plan_type → 展示名。没有 "5x" 这种档位，那是 Claude 的叫法。
    public static func codexPlanLabel(_ plan: String) -> String {
        switch plan.lowercased() {
        case "prolite": return "Pro Lite"
        case "pro": return "Pro"
        case "plus": return "Plus"
        case "go": return "Go"
        case "team", "business": return "Team"
        case "enterprise": return "Enterprise"
        case "edu": return "Edu"
        case "free": return "Free"
        case "": return ""
        default: return plan.prefix(1).uppercased() + plan.dropFirst()
        }
    }

    private func getCodexTier(sessionPlan: String) -> String {
        if let auth = readJSON("\(home)/.codex/auth.json") {
            if let idTok = (auth["tokens"] as? [String: Any])?["id_token"] as? String {
                let segs = idTok.split(separator: ".")
                if segs.count >= 2 {
                    var payload = String(segs[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                    let rem = payload.count % 4
                    if rem > 0 { payload += String(repeating: "=", count: 4 - rem) }
                    if let d = Data(base64Encoded: payload),
                       let p = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                       let plan = (p["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_plan_type"] as? String,
                       !plan.isEmpty {
                        return ProcessScanner.codexPlanLabel(plan)
                    }
                }
            }
            if !sessionPlan.isEmpty { return ProcessScanner.codexPlanLabel(sessionPlan) }
            let mode = auth["auth_mode"] as? String ?? ""
            if mode == "chatgpt" { return "ChatGPT 登录" }
            if mode == "api_key" || auth["OPENAI_API_KEY"] != nil { return "API Key" }
        }
        if env["OPENAI_API_KEY"] != nil { return "API Key" }
        return "未登录"
    }

    /// Antigravity 本地没有套餐字段；新版 agy 连 token 文件都不落盘了 → 能拉到额度就是登录态
    private func getGeminiTier(hasQuota: Bool) -> String {
        if let tok = readJSON("\(home)/.gemini/antigravity-cli/antigravity-oauth-token") {
            let method = (tok["auth_method"] as? String ?? "").lowercased()
            return method == "consumer" ? "个人 OAuth" : "OAuth"
        }
        if hasQuota { return "已登录" }
        if env["GEMINI_API_KEY"] != nil { return "API Key" }
        return "未登录"
    }

    /// 直接用 grok 自己缓存的 subscription_tier_display（形如 "X Premium+" / "SuperGrok"），原样显示不改写
    private func getGrokTier() -> String {
        if let cache = readJSON("\(home)/.grok/settings_cache.json"),
           let payloadStr = cache["payload"] as? String,
           let pData = payloadStr.data(using: .utf8),
           let pJson = try? JSONSerialization.jsonObject(with: pData) as? [String: Any],
           let settings = pJson["settings"] as? [String: Any] {
            if let display = settings["subscription_tier_display"] as? String, !display.isEmpty { return display }
            if let tier = settings["subscription_tier"] as? String, !tier.isEmpty { return tier }
        }
        if let auth = readJSON("\(home)/.grok/auth.json") {
            for v in auth.values {
                if let d = v as? [String: Any], d["auth_mode"] as? String == "oidc" { return "已登录" }
            }
        }
        if env["XAI_API_KEY"] != nil || env["GROK_API_KEY"] != nil { return "API Key" }
        return "未登录"
    }

    // MARK: 额度（全部带 resets_at + 采集时间）

    /// Claude：statusline 截获后写入 ~/.claude/claude-usage.json（Claude Code 下发的整个 rate_limits 对象）。
    /// 目前只有 five_hour / seven_day；若将来出现按模型的窗口键（如 seven_day_fable），自动当副池显示，键名即池名。
    private func readClaudeQuota() -> (fiveHour: QuotaWindow?, sevenDay: QuotaWindow?, extraName: String, extra5h: QuotaWindow?, extraW: QuotaWindow?) {
        guard let json = readJSON("\(home)/.claude/claude-usage.json") else { return (nil, nil, "", nil, nil) }
        let captured = (json["_captured_at"] as? NSNumber)?.doubleValue
        func win(_ d: Any?) -> QuotaWindow? {
            guard let d = d as? [String: Any], let used = clampPct(d["used_percentage"] as? NSNumber) else { return nil }
            return QuotaWindow(usedPct: used, resetsAt: (d["resets_at"] as? NSNumber)?.doubleValue, capturedAt: captured)
        }
        var extraName = ""
        var extra5h: QuotaWindow? = nil
        var extraW: QuotaWindow? = nil
        for (k, v) in json where !["five_hour", "seven_day", "_captured_at"].contains(k) {
            guard let w = win(v) else { continue }
            let base = k.replacingOccurrences(of: "seven_day_", with: "").replacingOccurrences(of: "five_hour_", with: "")
            let name = base.prefix(1).uppercased() + base.dropFirst()
            guard extraName.isEmpty || extraName == name else { continue }   // 只展示一个副池
            extraName = name
            if k.hasPrefix("five_hour") { extra5h = w } else { extraW = w }
        }
        return (win(json["five_hour"]), win(json["seven_day"]), extraName, extra5h, extraW)
    }

    // MARK: Codex 额度（按 limit_id 分桶：主桶 "codex"，新版 CLI 另报如 codex_bengalfox/Spark；本机 + 远程合并取最新）

    private struct CodexBucket {
        var id: String            // limit_id；旧版 CLI 不带 → 视为 "codex"
        var name: String          // limit_name，如 "GPT-5.3-Codex-Spark"
        var fiveHour: QuotaWindow?
        var weekly: QuotaWindow?
        var plan: String
        var captured: TimeInterval
    }
    /// 额度打满：请求被拒时 Codex 写 rate_limits 但百分比全为 null，真信号在 task_complete 的
    /// error.codex_error_info == "usage_limit_exceeded"，重置时刻在 error.message 文案里。
    private struct CodexLimitHit {
        var at: TimeInterval
        var resetsAt: TimeInterval?
    }
    private struct CodexParse {
        var buckets: [String: CodexBucket] = [:]
        var limitHit: CodexLimitHit? = nil
    }
    private var codexFileCache: [String: (mtime: TimeInterval, parsed: CodexParse)] = [:]

    private let remoteLock = NSLock()
    private var remoteCodex: (at: TimeInterval, ok: Bool, parsed: CodexParse) = (0, false, CodexParse())
    /// 另一台真正跑 Codex 的机器（默认空 = 关闭远程合并）。
    /// 开启：`defaults write com.haifeng.vibegauge codexRemoteHost <ssh-host>`，该 host 需能免密 ssh。
    public var codexRemoteHost: String {
        (UserDefaults.standard.string(forKey: "codexRemoteHost") ?? "").trimmingCharacters(in: .whitespaces)
    }

    public func codexRemoteStatus() -> (host: String, ok: Bool, ageSeconds: Int) {
        remoteLock.lock(); defer { remoteLock.unlock() }
        return (codexRemoteHost, remoteCodex.ok, Int(Date().timeIntervalSince1970 - remoteCodex.at))
    }

    private func findRateLimits(_ x: Any) -> [String: Any]? {
        guard let d = x as? [String: Any] else { return nil }
        if d["primary"] != nil { return d }
        for v in d.values { if let r = findRateLimits(v) { return r } }
        return nil
    }

    /// 每个 limit_id 取采集时间最新的一条，并抓最新的"额度耗尽"事件。
    /// 不能靠行序：远程输出是多文件拼接、顺序随机；半行/坏行直接跳过。
    private func parseCodexText(_ text: String, fallbackTime: TimeInterval) -> CodexParse {
        var out = CodexParse()
        for l in text.components(separatedBy: "\n") {
            let hasPct = l.contains("used_percent")
            let hasHit = l.contains("usage_limit_exceeded")
            guard hasPct || hasHit,
                  let data = l.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let ts = parseISO(json["timestamp"] as? String) ?? fallbackTime

            if hasHit, let msg = findErrorMessage(json) {
                if ts > (out.limitHit?.at ?? -1) {
                    out.limitHit = CodexLimitHit(at: ts, resetsAt: Fmt.parseUsageLimitReset(msg))
                }
            }

            guard hasPct, let rl = findRateLimits(json) else { continue }
            let rawId = rl["limit_id"] as? String ?? ""
            let id = rawId.isEmpty ? "codex" : rawId
            if ts <= (out.buckets[id]?.captured ?? -1) { continue }
            var b = CodexBucket(id: id, name: rl["limit_name"] as? String ?? "", fiveHour: nil, weekly: nil,
                                plan: rl["plan_type"] as? String ?? "", captured: ts)
            for key in ["primary", "secondary"] {
                guard let w = rl[key] as? [String: Any], let used = clampPct(w["used_percent"] as? NSNumber) else { continue }
                let win = QuotaWindow(usedPct: used, resetsAt: (w["resets_at"] as? NSNumber)?.doubleValue, capturedAt: ts)
                if ((w["window_minutes"] as? NSNumber)?.intValue ?? 0) >= 1440 { b.weekly = win } else { b.fiveHour = win }
            }
            // 百分比全 null（请求被拒时就是这样）→ 不是有效快照，别覆盖旧的真值
            if b.fiveHour != nil || b.weekly != nil { out.buckets[id] = b }
        }
        return out
    }

    private func findErrorMessage(_ x: Any) -> String? {
        guard let d = x as? [String: Any] else { return nil }
        if let e = d["error"] as? [String: Any] {
            if (e["codex_error_info"] as? String) == "usage_limit_exceeded", let m = e["message"] as? String { return m }
        }
        for v in d.values { if let r = findErrorMessage(v) { return r } }
        return nil
    }

    private func mergeNewest(_ into: inout CodexParse, _ src: CodexParse) {
        for (id, b) in src.buckets where b.captured > (into.buckets[id]?.captured ?? -1) { into.buckets[id] = b }
        if let h = src.limitHit, h.at > (into.limitHit?.at ?? -1) { into.limitHit = h }
    }

    /// 本机：近 7 天目录里 48h 内改过的会话文件，各取每桶最新；单文件按 mtime 缓存
    private func readLocalCodex() -> CodexParse {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"
        var files: [(path: String, mtime: TimeInterval)] = []
        for back in 0..<7 {
            let dir = "\(home)/.codex/sessions/\(df.string(from: Date(timeIntervalSinceNow: -Double(back) * 86400)))"
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".jsonl") {
                let p = "\(dir)/\(n)"
                if let d = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date,
                   now - d.timeIntervalSince1970 < 48 * 3600 {
                    files.append((p, d.timeIntervalSince1970))
                }
            }
        }
        var merged = CodexParse()
        var seen = Set<String>()
        for f in files {
            seen.insert(f.path)
            let parsed: CodexParse
            if let c = codexFileCache[f.path], c.mtime == f.mtime {
                parsed = c.parsed
            } else {
                let tailBytes = 256 * 1024
                let tail = readTail(f.path, maxBytes: tailBytes)
                var pr = parseCodexText(tail, fallbackTime: f.mtime)
                if pr.buckets.isEmpty, pr.limitHit == nil, tail.utf8.count >= tailBytes {   // 尾部没有就全量
                    pr = parseCodexText(readTail(f.path, maxBytes: Int.max), fallbackTime: f.mtime)
                }
                parsed = pr
                codexFileCache[f.path] = (f.mtime, pr)
            }
            mergeNewest(&merged, parsed)
        }
        codexFileCache = codexFileCache.filter { seen.contains($0.key) }
        return merged
    }

    /// 远程主机（`codexRemoteHost`，默认关闭）：ssh 拉 48h 内会话文件各自最后一条额度行。
    /// 60s 节流；失败保留上次结果；不持扫描锁。
    public func refreshRemoteCodexIfDue(force: Bool = false) {
        let host = codexRemoteHost
        guard !host.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        remoteLock.lock()
        let due = force || now - remoteCodex.at >= 60
        remoteLock.unlock()
        guard due else { return }
        // 每个文件取：最后一条含百分比的行 + 最后一条额度耗尽事件
        let script = #"for f in $(find ~/.codex/sessions -name "*.jsonl" -mmin -2880 2>/dev/null); do tail -c 262144 "$f" | grep used_percent | tail -1; tail -c 262144 "$f" | grep usage_limit_exceeded | tail -1; done; echo __OK__"#
        let out = execute("ssh -o BatchMode=yes -o ConnectTimeout=4 -o ServerAliveInterval=5 \(host) '\(script)' 2>/dev/null")
        let ok = out.contains("__OK__")
        let parsed = ok ? parseCodexText(out, fallbackTime: now) : CodexParse()
        remoteLock.lock()
        remoteCodex = ok ? (now, true, parsed) : (now, false, remoteCodex.parsed)
        remoteLock.unlock()
        log.notice("remote codex \(host, privacy: .public) ok=\(ok) buckets=\(parsed.buckets.count) limitHit=\(parsed.limitHit != nil)")
    }

    private struct CodexSnapshot {
        var primary: CodexBucket?
        var plan: String
        var remoteOK: Bool
    }

    /// 只展示主桶 "codex"；其他桶（如 codex_bengalfox / Spark）解析出来只为了不被误当主桶，不显示
    private func codexSnapshot() -> CodexSnapshot {
        var merged = readLocalCodex()
        remoteLock.lock()
        let remote = remoteCodex
        remoteLock.unlock()
        mergeNewest(&merged, remote.parsed)
        let plan = merged.buckets.values.sorted { $0.captured > $1.captured }.first { !$0.plan.isEmpty }?.plan ?? ""
        var primary = merged.buckets["codex"]

        // 额度耗尽事件比最后一个百分比快照更新 → 真值就是 100%，重置时刻取错误文案里的时间
        if let hit = merged.limitHit, hit.at > (primary?.weekly?.capturedAt ?? -1) {
            let now = Date().timeIntervalSince1970
            let stillHit = (hit.resetsAt ?? .greatestFiniteMagnitude) > now
            if stillHit {
                let win = QuotaWindow(usedPct: 100, resetsAt: hit.resetsAt ?? primary?.weekly?.resetsAt, capturedAt: hit.at)
                if primary == nil {
                    primary = CodexBucket(id: "codex", name: "", fiveHour: nil, weekly: win, plan: plan, captured: hit.at)
                } else {
                    primary?.weekly = win
                    primary?.captured = hit.at
                }
            }
        }
        return CodexSnapshot(primary: primary, plan: plan, remoteOK: remote.ok)
    }

    /// Grok：grok CLI 自己在 ~/.grok/logs/unified.jsonl 记 "billing: fetched credits config"
    /// （creditUsagePercent = 周额度已用 %，currentPeriod.end = 重置点，subscriptionTier）。文件按 mtime+size 缓存。
    private var grokQuotaCache: (mtime: TimeInterval, size: UInt64, weekly: QuotaWindow?, tier: String)? = nil
    private func readGrokQuota() -> (weekly: QuotaWindow?, tier: String) {
        let path = "\(home)/.grok/logs/unified.jsonl"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mod = attrs[.modificationDate] as? Date else { return (nil, "") }
        let mtime = mod.timeIntervalSince1970
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        if let c = grokQuotaCache, c.mtime == mtime, c.size == size { return (c.weekly, c.tier) }

        var weekly: QuotaWindow? = nil
        var tier = ""
        outer: for maxBytes in [512 * 1024, Int.max] {
            let text = readTail(path, maxBytes: maxBytes)
            for l in text.components(separatedBy: "\n").reversed() where l.contains("fetched credits config") {
                guard let data = l.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let ctx = json["ctx"] as? [String: Any],
                      let cfg = ctx["config"] as? [String: Any],
                      let pct = clampPct(cfg["creditUsagePercent"] as? NSNumber) else { continue }
                let period = cfg["currentPeriod"] as? [String: Any]
                weekly = QuotaWindow(usedPct: pct, resetsAt: parseISO(period?["end"] as? String), capturedAt: parseISO(json["ts"] as? String))
                tier = ctx["subscriptionTier"] as? String ?? ""
                break outer
            }
            if text.utf8.count < maxBytes { break }
        }
        grokQuotaCache = (mtime, size, weekly, tier)
        return (weekly, tier)
    }

    /// Gemini（Antigravity）：agy-hud 写的 quota_cache.json，两个池：gemini / 3p
    private func readGeminiQuota() -> (native5h: QuotaWindow?, nativeW: QuotaWindow?, tp5h: QuotaWindow?, tpW: QuotaWindow?) {
        guard let json = readJSON("\(home)/.cache/agy-hud/quota_cache.json"),
              let pools = json["pools"] as? [String: Any] else { return (nil, nil, nil, nil) }
        func win(_ pool: Any?, _ key: String) -> QuotaWindow? {
            guard let p = pool as? [String: Any], let w = p[key] as? [String: Any],
                  let rf = (w["remaining_fraction"] as? NSNumber)?.doubleValue else { return nil }
            return QuotaWindow(
                usedPct: max(0, min(100, Int(round((1.0 - rf) * 100.0)))),
                resetsAt: (w["reset_at"] as? NSNumber)?.doubleValue,
                capturedAt: (w["recorded_at"] as? NSNumber)?.doubleValue ?? (json["updated_at"] as? NSNumber)?.doubleValue
            )
        }
        let g = pools["gemini"], tp = pools["3p"]
        return (win(g, "5h"), win(g, "weekly"), win(tp, "5h"), win(tp, "weekly"))
    }

    // MARK: 平台汇聚

    // 会话 cwd/启动时长要跑 lsof + ps，太贵，不能跟着每秒的 ticker 跑 → 10s 节流
    private var sessionCache: [String: (at: TimeInterval, pids: [Int], infos: [SessionInfo])] = [:]

    private func sessionInfos(_ c: SessionCounts, _ kind: CLIKind) -> [SessionInfo] {
        let pids = (c.pids[kind] ?? []).sorted()
        guard !pids.isEmpty else { return [] }
        let key = "\(kind)"
        let now = Date().timeIntervalSince1970
        if let cached = sessionCache[key], cached.pids == pids, now - cached.at < 10 {
            return cached.infos
        }
        let cw = cwds(of: pids)
        let ag = ages(of: pids)
        let infos = pids.map { SessionInfo(pid: $0, cwd: cw[$0] ?? "?", startedAgo: ag[$0] ?? 0, memMB: c.mem[$0] ?? 0) }
            .sorted { $0.startedAgo > $1.startedAgo }
        sessionCache[key] = (now, pids, infos)
        return infos
    }

    private func claudeDetail(_ c: SessionCounts) -> PlatformDetail {
        var d = PlatformDetail()
        d.sourceFiles = ["~/.claude.json", "~/.claude/claude-usage.json", "~/.claude/projects/*.jsonl"]
        if let oa = readJSON("\(home)/.claude.json")?["oauthAccount"] as? [String: Any] {
            if let v = oa["organizationRateLimitTier"] as? String { d.rows.append(("限速档位字段", v)) }
            if let v = oa["organizationType"] as? String { d.rows.append(("组织类型", v)) }
            if let v = oa["billingType"] as? String { d.rows.append(("计费方式", v)) }
            if let v = oa["organizationRole"] as? String { d.rows.append(("角色", v)) }
            if let b = oa["hasExtraUsageEnabled"] as? Bool { d.rows.append(("额外用量", b ? "已开启" : "未开启")) }
            if let v = oa["subscriptionCreatedAt"] as? String, let t = Fmt.parseISODate(v) {
                d.rows.append(("订阅开始", Fmt.dateText(t) + "（\(Int((Date().timeIntervalSince1970 - t) / 86400)) 天前）"))
            }
        }
        d.sessions = sessionInfos(c, .claude)
        return d
    }

    private func codexDetail(_ c: SessionCounts, snapshot: CodexSnapshot, buckets: [String: CodexBucket]) -> PlatformDetail {
        var d = PlatformDetail()
        d.sourceFiles = ["~/.codex/auth.json", "~/.codex/sessions/*/*.jsonl"]
        if let auth = readJSON("\(home)/.codex/auth.json"),
           let idTok = (auth["tokens"] as? [String: Any])?["id_token"] as? String {
            let segs = idTok.split(separator: ".")
            if segs.count >= 2 {
                var payload = String(segs[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                let rem = payload.count % 4
                if rem > 0 { payload += String(repeating: "=", count: 4 - rem) }
                if let data = Data(base64Encoded: payload),
                   let p = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let a = p["https://api.openai.com/auth"] as? [String: Any] {
                    if let v = a["chatgpt_plan_type"] as? String { d.rows.append(("套餐字段", v)) }
                    if let v = a["chatgpt_subscription_active_until"] as? String, let t = Fmt.parseISODate(v) {
                        let left = Int((t - Date().timeIntervalSince1970) / 86400)
                        d.rows.append(("订阅有效期至", Fmt.dateText(t) + "（还剩 \(left) 天）"))
                    }
                }
            }
            if let mode = auth["auth_mode"] as? String { d.rows.append(("鉴权方式", mode)) }
        }
        if !codexRemoteHost.isEmpty {
            remoteLock.lock(); let ok = remoteCodex.ok; let at = remoteCodex.at; remoteLock.unlock()
            d.rows.append(("远程合并主机", "\(codexRemoteHost) · " + (ok ? "已连上（\(Fmt.agoShort(Int(Date().timeIntervalSince1970 - at))) 拉取）" : "未连上")))
        }
        for (id, b) in buckets.sorted(by: { $0.key < $1.key }) where id != "codex" {
            let label = b.name.isEmpty ? id : b.name
            if let w = b.weekly { d.extraPools.append(("\(label) 周", w)) }
            if let w = b.fiveHour { d.extraPools.append(("\(label) 5H", w)) }
        }
        d.sessions = sessionInfos(c, .codex)
        return d
    }

    private func geminiDetail(_ c: SessionCounts) -> PlatformDetail {
        var d = PlatformDetail()
        d.sourceFiles = ["~/.gemini/antigravity-cli/", "~/.cache/agy-hud/quota_cache.json"]
        if let st = readJSON("\(home)/.gemini/antigravity-cli/settings.json"), let m = st["model"] as? String {
            d.rows.append(("默认模型", m))
        }
        if let tok = readJSON("\(home)/.gemini/antigravity-cli/antigravity-oauth-token"), let m = tok["auth_method"] as? String {
            d.rows.append(("鉴权方式", m))
        }
        d.rows.append(("三方池说明", "只有跑 Claude/GPT 模型时才会刷新；耗尽后无法再刷，只能等重置"))
        d.sessions = sessionInfos(c, .agy)
        return d
    }

    private func grokDetail(_ c: SessionCounts) -> PlatformDetail {
        var d = PlatformDetail()
        d.sourceFiles = ["~/.grok/settings_cache.json", "~/.grok/logs/unified.jsonl"]
        if let cache = readJSON("\(home)/.grok/settings_cache.json"),
           let payloadStr = cache["payload"] as? String,
           let pData = payloadStr.data(using: .utf8),
           let pJson = try? JSONSerialization.jsonObject(with: pData) as? [String: Any],
           let settings = pJson["settings"] as? [String: Any] {
            if let v = settings["subscription_tier_display"] as? String { d.rows.append(("订阅档位（服务端原值）", v)) }
            if let v = pJson["grok_version"] as? String { d.rows.append(("CLI 版本", v)) }
        }
        d.rows.append(("额度来源", "grok 自己的 billing 日志，不必产生对话就会刷"))
        d.sessions = sessionInfos(c, .grok)
        return d
    }

    private func detectAllLLMRuntimes(_ c: SessionCounts) -> [DetectedLLMRuntime] {
        var list: [DetectedLLMRuntime] = []
        let fm = FileManager.default

        // Claude
        if c.claude > 0 || fm.fileExists(atPath: "\(home)/.claude.json") {
            let q = readClaudeQuota()
            list.append(DetectedLLMRuntime(
                name: "Claude", isRunning: c.claude > 0, tier: getClaudeTier(), detail: "\(c.claude) 会话",
                fiveHour: q.fiveHour, sevenDay: q.sevenDay,
                secondaryPoolName: q.extraName, secondaryFiveHour: q.extra5h, secondarySevenDay: q.extraW,
                isFullWidth: !q.extraName.isEmpty,
                quotaSubtitle: "Anthropic · 无额度数据 (状态栏未截获)",
                platformDetail: claudeDetail(c)
            ))
        }

        // Codex（本机 + 远程合并；只显示主桶 codex）
        if c.codex > 0 || fm.fileExists(atPath: "\(home)/.codex/auth.json") {
            let q = codexSnapshot()
            var allBuckets = readLocalCodex().buckets
            remoteLock.lock(); let rb = remoteCodex.parsed.buckets; remoteLock.unlock()
            for (k, v) in rb where v.captured > (allBuckets[k]?.captured ?? -1) { allBuckets[k] = v }
            let hasRemote = !codexRemoteHost.isEmpty
            list.append(DetectedLLMRuntime(
                name: "Codex",
                isRunning: c.codex > 0,
                tier: getCodexTier(sessionPlan: q.plan),
                detail: "\(c.codex) 会话",
                fiveHour: q.primary?.fiveHour, sevenDay: q.primary?.weekly,
                quotaSubtitle: (hasRemote && !q.remoteOK) ? "OpenAI · 无额度数据 (\(codexRemoteHost) 未连上)" : "OpenAI · 无额度数据 (近两日无 session)",
                platformDetail: codexDetail(c, snapshot: q, buckets: allBuckets)
            ))
        }

        // Gemini / Antigravity（双池，独占整行）
        if c.agy > 0 || fm.fileExists(atPath: "\(home)/.gemini/antigravity-cli") {
            let q = readGeminiQuota()
            let hasAny = q.native5h != nil || q.nativeW != nil || q.tp5h != nil || q.tpW != nil
            list.append(DetectedLLMRuntime(
                name: "Gemini", isRunning: c.agy > 0, tier: getGeminiTier(hasQuota: hasAny), detail: "\(c.agy) 会话",
                fiveHour: q.native5h, sevenDay: q.nativeW,
                secondaryPoolName: "三方", secondaryFiveHour: q.tp5h, secondarySevenDay: q.tpW,
                isFullWidth: hasAny,
                quotaSubtitle: "Antigravity · 无额度数据 (agy-hud 未刷新)",
                platformDetail: geminiDetail(c)
            ))
        }

        // Grok（周额度来自 grok 自己的 billing 日志）
        if c.grok > 0 || fm.fileExists(atPath: "\(home)/.grok/auth.json") {
            let q = readGrokQuota()
            var tier = getGrokTier()
            if (tier == "已登录" || tier == "未登录"), !q.tier.isEmpty { tier = q.tier }
            list.append(DetectedLLMRuntime(
                name: "Grok", isRunning: c.grok > 0, tier: tier, detail: "\(c.grok) 会话",
                sevenDay: q.weekly,
                quotaSubtitle: "xAI · 无额度数据 (grok 未跑过)",
                platformDetail: grokDetail(c)
            ))
        }

        // Ollama（探测结果缓存 10s，避免 ticker 每秒阻塞）
        if c.ollama {
            let o = probeOllama()
            list.append(DetectedLLMRuntime(
                name: "Ollama", isRunning: o.count > 0, tier: "本地", detail: "\(o.count) 模型", quotaSubtitle: o.sub
            ))
        }

        if c.cursor {
            list.append(DetectedLLMRuntime(name: "Cursor", isRunning: true, tier: "", detail: "运行中", quotaSubtitle: "IDE 进程在线 · 本地无档位/额度数据"))
        }

        if c.lmStudio {
            list.append(DetectedLLMRuntime(name: "LM Studio", isRunning: true, tier: "本地", detail: "运行中", quotaSubtitle: "端侧运行 · 0 额度消耗"))
        }

        return list
    }

    private func probeOllama() -> (count: Int, sub: String) {
        let now = Date().timeIntervalSince1970
        if let c = ollamaCache, now - c.at < 10 { return (c.count, c.sub) }
        // 结果放独立加锁的盒子：超时后迟到的回调只写盒子，不与扫描线程的读竞争
        final class Box { let lock = NSLock(); var count = 0; var sub = "端侧运行 · 无已加载模型" }
        let box = Box()
        if let url = URL(string: "http://127.0.0.1:11434/api/ps") {
            var request = URLRequest(url: url)
            request.timeoutInterval = 0.3
            let sema = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { data, _, _ in
                if let data = data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let models = json["models"] as? [[String: Any]], !models.isEmpty {
                    box.lock.lock()
                    box.count = models.count
                    box.sub = "已加载: " + models.compactMap { $0["name"] as? String }.joined(separator: ", ")
                    box.lock.unlock()
                }
                sema.signal()
            }.resume()
            _ = sema.wait(timeout: .now() + 0.3)
        }
        box.lock.lock()
        let result = (count: box.count, sub: box.sub)
        box.lock.unlock()
        ollamaCache = (result.count, result.sub, now)
        return result
    }

    // MARK: Token 遥测（增量解析，requestId 去重）

    private func parseAssistantLine(_ line: Substring) -> InteractionRecord? {
        guard line.contains("\"type\":\"assistant\""), line.contains("\"usage\":"),
              let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = json["message"] as? [String: Any],
              let usage = msg["usage"] as? [String: Any] else { return nil }
        let model = msg["model"] as? String ?? ""
        if model.contains("synthetic") { return nil }
        let id = (json["requestId"] as? String) ?? (msg["id"] as? String) ?? (json["uuid"] as? String) ?? UUID().uuidString
        let inp = usage["input_tokens"] as? Int ?? 0
        let cRead = usage["cache_read_input_tokens"] as? Int ?? 0
        let cCreate = usage["cache_creation_input_tokens"] as? Int ?? 0
        let out = usage["output_tokens"] as? Int ?? 0
        let thinking = (usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"] as? Int ?? 0
        return InteractionRecord(
            id: id, model: model, timestamp: parseISO(json["timestamp"] as? String) ?? 0,
            contextTokens: inp + cRead + cCreate, cacheReadTokens: cRead, outputTokens: out, thinkingTokens: thinking
        )
    }

    /// jsonl 是 append-only：只解析上次 offset 之后新增的完整行；文件变小则整体重解析
    private func refreshFileState(path: String, mtime: TimeInterval, size: UInt64) -> FileParseState {
        var state = fileStates[path] ?? FileParseState()
        if state.mtime == mtime && state.size == size { return state }

        guard let fh = FileHandle(forReadingAtPath: path) else { return state }
        defer { try? fh.close() }
        // 变小、或前 256 字节指纹变了 = 被截断重写 / 替换 → 整体重解析（正常 append 两者都不变）
        let head = (try? fh.read(upToCount: 256)) ?? Data()
        if size < state.size || head != state.head { state = FileParseState() }
        state.head = head
        do { try fh.seek(toOffset: state.parsedOffset) } catch { return state }
        let data = fh.readDataToEndOfFile()

        if let lastNL = data.lastIndex(of: 0x0A) {
            let chunk = data[data.startIndex...lastNL]
            let text = String(decoding: chunk, as: UTF8.self)   // lossy：坏字节只毁一行，不丢整块
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                if var rec = parseAssistantLine(line) {
                    if rec.timestamp == 0 { rec.timestamp = mtime }
                    state.turns[rec.id] = rec   // 同 requestId 后写覆盖前写（usage 相同）
                }
            }
            state.parsedOffset += UInt64(chunk.count)
        }
        state.mtime = mtime
        state.size = size
        fileStates[path] = state
        return state
    }

    public func scanTokens() -> TokenStats {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        let projectsDir = "\(home)/.claude/projects"
        let fm = FileManager.default
        guard let en = fm.enumerator(atPath: projectsDir) else {
            fileStates = [:]
            return TokenStats()
        }

        let horizon = now - 24.0 * 3600.0
        var seen = Set<String>()
        var byId: [String: InteractionRecord] = [:]   // 跨文件再去重（--fork-session 会把历史复制进新文件）
        while let el = en.nextObject() as? String {
            guard el.hasSuffix(".jsonl") else { continue }
            let path = "\(projectsDir)/\(el)"
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let mod = attrs[.modificationDate] as? Date else { continue }
            let mtime = mod.timeIntervalSince1970
            guard mtime > horizon else { continue }
            let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
            seen.insert(path)
            for (id, rec) in refreshFileState(path: path, mtime: mtime, size: size).turns {
                if let old = byId[id], old.timestamp >= rec.timestamp { continue }
                byId[id] = rec
            }
        }
        fileStates = fileStates.filter { seen.contains($0.key) }
        let all = byId.values

        let startOfToday = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var s = TokenStats()
        for t in all where t.timestamp >= startOfToday {
            s.todayTurns += 1
            s.todayContext += Int64(t.contextTokens)
            s.todayCacheRead += Int64(t.cacheReadTokens)
            s.todayOutput += Int64(t.outputTokens)
            s.todayThinking += Int64(t.thinkingTokens)
        }
        s.recentInteractions = Array(all.sorted { $0.timestamp > $1.timestamp }.prefix(3))
        return s
    }

    // MARK: 各 CLI 今日用量

    private var codexUsageCache: [String: (mtime: TimeInterval, usage: CLIUsage)] = [:]

    /// Codex：`token_count` 事件的 `info.total_token_usage` 是**该会话的累计值** → 每个会话文件取最后一条非空的，再跨文件相加。
    /// 跨零点的会话会把昨天那部分也算进来（Codex 不按天分账，只能这样近似）。
    private func codexUsageToday(startOfToday: TimeInterval) -> CLIUsage {
        var u = CLIUsage(name: "Codex")
        let fm = FileManager.default
        let df = DateFormatter()
        df.dateFormat = "yyyy/MM/dd"
        var seen = Set<String>()
        for back in 0...1 {
            let dir = "\(home)/.codex/sessions/\(df.string(from: Date(timeIntervalSinceNow: -Double(back) * 86400)))"
            guard let names = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".jsonl") {
                let path = "\(dir)/\(n)"
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mod = attrs[.modificationDate] as? Date else { continue }
                let mtime = mod.timeIntervalSince1970
                guard mtime >= startOfToday else { continue }
                seen.insert(path)
                let one: CLIUsage
                if let c = codexUsageCache[path], c.mtime == mtime {
                    one = c.usage
                } else {
                    var acc = CLIUsage(name: "Codex")
                    let text = readTail(path, maxBytes: 256 * 1024)
                    let lines = text.components(separatedBy: "\n")
                    for l in lines.reversed() where l.contains("\"type\":\"token_count\"") && !l.contains("\"info\":null") {
                        guard let data = l.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let info = findTokenInfo(json),
                              let t = info["total_token_usage"] as? [String: Any] else { continue }
                        func n64(_ k: String) -> Int64 { Int64((t[k] as? NSNumber)?.intValue ?? 0) }
                        acc.ctx = n64("input_tokens")               // 已含 cached
                        acc.cacheRead = n64("cached_input_tokens")
                        acc.out = n64("output_tokens")
                        acc.think = n64("reasoning_output_tokens")
                        break
                    }
                    acc.requests = lines.filter { $0.contains("\"type\":\"token_count\"") && !$0.contains("\"info\":null") }.count
                    one = acc
                    codexUsageCache[path] = (mtime, acc)
                }
                u.ctx += one.ctx
                u.cacheRead += one.cacheRead
                u.out += one.out
                u.think += one.think
                u.requests += one.requests
            }
        }
        codexUsageCache = codexUsageCache.filter { seen.contains($0.key) }
        if !u.hasTokens { u.note = "今日无调用" }
        return u
    }

    private func findTokenInfo(_ x: Any) -> [String: Any]? {
        guard let d = x as? [String: Any] else { return nil }
        if d["total_token_usage"] != nil { return d }
        for v in d.values { if let r = findTokenInfo(v) { return r } }
        return nil
    }

    /// Grok：`signals.json` 只有 `turnCount` 与当前上下文占用，没有累计 token
    private func grokUsageToday(startOfToday: TimeInterval) -> CLIUsage {
        var u = CLIUsage(name: "Grok")
        let fm = FileManager.default
        let root = "\(home)/.grok/sessions"
        guard let dirs = try? fm.contentsOfDirectory(atPath: root) else {
            u.note = "本地无 token 统计"
            return u
        }
        for d in dirs {
            guard let subs = try? fm.contentsOfDirectory(atPath: "\(root)/\(d)") else { continue }
            for sub in subs {
                let path = "\(root)/\(d)/\(sub)/signals.json"
                guard let attrs = try? fm.attributesOfItem(atPath: path),
                      let mod = attrs[.modificationDate] as? Date,
                      mod.timeIntervalSince1970 >= startOfToday,
                      let j = readJSON(path) else { continue }
                u.turns += (j["turnCount"] as? NSNumber)?.intValue ?? 0
            }
        }
        u.note = u.turns > 0 ? "本地无 token 统计，仅轮次" : "今日无调用"
        return u
    }

    public func scanCLIUsage(claude: TokenStats) -> [CLIUsage] {
        lock.lock(); defer { lock.unlock() }
        let startOfToday = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        var claudeRow = CLIUsage(name: "Claude Code")
        claudeRow.requests = claude.todayTurns
        claudeRow.ctx = claude.todayContext
        claudeRow.cacheRead = claude.todayCacheRead
        claudeRow.out = claude.todayOutput
        claudeRow.think = claude.todayThinking
        if !claudeRow.hasTokens { claudeRow.note = "今日无调用" }

        var gemini = CLIUsage(name: "Gemini")
        gemini.note = "本地无 token 统计（额度见上）"      // conversations 是 SQLite，无 token 字段

        return [claudeRow, codexUsageToday(startOfToday: startOfToday), grokUsageToday(startOfToday: startOfToday), gemini]
    }

    // MARK: API Key 调用（读记账代理写的 api-calls.jsonl / api-quota.json）

    private struct APICall {
        let ts: TimeInterval
        let host: String
        let provider: String
        let model: String
        let ctx: Int64
        let cacheRead: Int64
        let cacheWrite: Int64
        let out: Int64
        let think: Int64
        let status: Int
        let ms: Int
        let key: String
    }

    /// 价目表：`~/.config/vibegauge/prices.json`，单位 = 每百万 token。
    /// ```
    /// { "_asof": "2026-09-18", "_currency": "CNY",
    ///   "glm-4.7": { "in": 0.6, "cache_read": 0.11, "cache_write": 0.6, "out": 2.2 } }
    /// ```
    /// 没这文件就不估花费 —— 价格会变，编一个假的比不显示更糟。模型名取「最长前缀命中」。
    public struct PriceTable {
        public struct Row { public var input = 0.0, cacheRead = 0.0, cacheWrite = 0.0, output = 0.0 }
        public var rows: [String: Row] = [:]
        public var currency: String = ""
        public var asOf: String = ""
        public var isEmpty: Bool { rows.isEmpty }

        public init() {}
        public init(json: [String: Any]) {
            currency = (json["_currency"] as? String) ?? "USD"
            asOf = (json["_asof"] as? String) ?? ""
            for (k, v) in json where !k.hasPrefix("_") {
                guard let d = v as? [String: Any] else { continue }
                func f(_ key: String) -> Double { (d[key] as? NSNumber)?.doubleValue ?? 0 }
                var r = Row()
                r.input = f("in"); r.output = f("out")
                r.cacheRead = d["cache_read"] == nil ? r.input : f("cache_read")
                r.cacheWrite = d["cache_write"] == nil ? r.input : f("cache_write")
                // 全 0 视为"没填价"（示例文件里的占位行不该算出 ¥0.00 的假花费）
                if r.input == 0, r.output == 0, r.cacheRead == 0, r.cacheWrite == 0 { continue }
                rows[k.lowercased()] = r
            }
        }

        func row(for model: String) -> Row? {
            let m = model.lowercased()
            if let exact = rows[m] { return exact }
            // 最长前缀命中："glm-4.7" 能覆盖 "glm-4.7-flash"；取最长的那条，避免被短名抢走
            return rows.filter { m.hasPrefix($0.key) }.max { $0.key.count < $1.key.count }?.value
        }

        /// ctx 是「全部输入」（新鲜 + 缓存读 + 缓存写），算价时要先把缓存部分扣出来
        public func cost(model: String, ctx: Int64, cacheRead: Int64, cacheWrite: Int64, out: Int64) -> Double? {
            guard let r = row(for: model) else { return nil }
            let fresh = max(0, ctx - cacheRead - cacheWrite)
            return (Double(fresh) * r.input + Double(cacheRead) * r.cacheRead
                    + Double(cacheWrite) * r.cacheWrite + Double(out) * r.output) / 1_000_000.0
        }
    }

    private var priceCache: (mtime: TimeInterval, table: PriceTable)? = nil

    private func priceTable() -> PriceTable {
        let path = "\(home)/.config/vibegauge/prices.json"
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mod = attrs[.modificationDate] as? Date else { return PriceTable() }
        let mtime = mod.timeIntervalSince1970
        if let c = priceCache, c.mtime == mtime { return c.table }
        let t = readJSON(path).map { PriceTable(json: $0) } ?? PriceTable()
        priceCache = (mtime, t)
        return t
    }
    private var apiCalls: [APICall] = []
    private var apiFile = FileParseState()          // 只用 mtime/size/parsedOffset/head
    private var healthCache: (at: TimeInterval, running: Bool, calls: Int)? = nil

    private func parseAPICallLine(_ line: Substring) -> APICall? {
        guard let data = line.data(using: .utf8),
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let ts = (j["epoch"] as? NSNumber)?.doubleValue ?? parseISO(j["ts"] as? String) ?? 0
        guard ts > 0, let host = j["host"] as? String else { return nil }
        func n(_ k: String) -> Int64 { Int64((j[k] as? NSNumber)?.intValue ?? 0) }
        return APICall(ts: ts, host: host, provider: j["provider"] as? String ?? host,
                       model: (j["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?",
                       ctx: n("ctx"), cacheRead: n("cache_read"), cacheWrite: n("cache_write"),
                       out: n("out"), think: n("think"),
                       status: (j["status"] as? NSNumber)?.intValue ?? 0,
                       ms: (j["ms"] as? NSNumber)?.intValue ?? 0,
                       key: j["key"] as? String ?? "")
    }

    /// api-calls.jsonl 也是 append-only：同样的 offset 增量 + 指纹识别重写；只保留 48h 内记录
    private func ingestAPICalls() {
        let path = ProxyManager.shared.callsPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mod = attrs[.modificationDate] as? Date else {
            apiCalls = []
            apiFile = FileParseState()
            return
        }
        let mtime = mod.timeIntervalSince1970
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        if apiFile.mtime == mtime && apiFile.size == size { return }
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 256)) ?? Data()
        if size < apiFile.size || head != apiFile.head {
            apiFile = FileParseState()
            apiCalls = []
        }
        apiFile.head = head
        do { try fh.seek(toOffset: apiFile.parsedOffset) } catch { return }
        let data = fh.readDataToEndOfFile()
        if let lastNL = data.lastIndex(of: 0x0A) {
            let chunk = data[data.startIndex...lastNL]
            for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
                if let c = parseAPICallLine(line) { apiCalls.append(c) }
            }
            apiFile.parsedOffset += UInt64(chunk.count)
        }
        apiFile.mtime = mtime
        apiFile.size = size
        let horizon = Date().timeIntervalSince1970 - 48 * 3600
        if let first = apiCalls.first, first.ts < horizon { apiCalls.removeAll { $0.ts < horizon } }
    }

    private func balanceText(_ d: [String: Any]) -> String {
        let cur = (d["currency"] as? String ?? "").uppercased()
        let sym = cur == "CNY" ? "¥" : (cur == "USD" ? "$" : (cur.isEmpty ? "" : cur + " "))
        if let b = (d["balance"] as? NSNumber)?.doubleValue { return String(format: "余额 %@%.2f", sym, b) }
        if let u = (d["usage"] as? NSNumber)?.doubleValue {
            if let l = (d["limit"] as? NSNumber)?.doubleValue { return String(format: "已用 %@%.2f / %@%.2f", sym, u, sym, l) }
            return String(format: "已用 %@%.2f", sym, u)
        }
        return ""
    }

    public func scanAPI() -> ProxyStatus {
        lock.lock(); defer { lock.unlock() }
        let pm = ProxyManager.shared
        var st = ProxyStatus()
        st.installed = pm.isInstalled
        st.port = pm.port
        let now = Date().timeIntervalSince1970
        if let h = healthCache, now - h.at < 5 {
            st.running = h.running
            st.callsSinceStart = h.calls
        } else {
            let h = pm.health()
            healthCache = (now, h != nil, h?.calls ?? 0)
            st.running = h != nil
            st.callsSinceStart = h?.calls ?? 0
        }

        ingestAPICalls()
        let startOfToday = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let prices = priceTable()
        var byHost: [String: APIProviderStatus] = [:]
        var latency: [String: [Int]] = [:]              // host → 今日各次耗时（算 p50/p95）
        var byKey: [String: [String: APIKeyUsage]] = [:]  // host → 指纹 → 用量

        for c in apiCalls where c.ts >= startOfToday {
            var p = byHost[c.host] ?? APIProviderStatus(host: c.host, provider: c.provider)
            p.calls += 1
            if c.status >= 400 || c.status == 0 { p.errors += 1 }
            if c.status == 429 { p.count429 += 1 }
            p.ctx += c.ctx
            p.cacheRead += c.cacheRead
            p.out += c.out
            p.think += c.think
            p.lastTS = max(p.lastTS, c.ts)
            if !p.models.contains(c.model) { p.models.append(c.model) }

            let cost = prices.cost(model: c.model, ctx: c.ctx, cacheRead: c.cacheRead, cacheWrite: c.cacheWrite, out: c.out)
            if let cost = cost { p.cost = (p.cost ?? 0) + cost }
            byHost[c.host] = p

            if c.ms > 0 { latency[c.host, default: []].append(c.ms) }

            let fp = c.key.isEmpty ? "无 key" : c.key
            var k = byKey[c.host]?[fp] ?? APIKeyUsage(fingerprint: fp)
            k.calls += 1
            if c.status >= 400 || c.status == 0 { k.errors += 1 }
            k.ctx += c.ctx
            k.out += c.out
            k.lastTS = max(k.lastTS, c.ts)
            if let cost = cost { k.cost = (k.cost ?? 0) + cost }
            if !k.models.contains(c.model) { k.models.append(c.model) }
            byKey[c.host, default: [:]][fp] = k
        }

        for (host, ms) in latency {
            byHost[host]?.p50ms = Fmt.percentile(ms, 0.50)
            byHost[host]?.p95ms = Fmt.percentile(ms, 0.95)
            byHost[host]?.maxms = ms.max() ?? 0
        }
        for (host, keys) in byKey {
            byHost[host]?.keys = keys.values.sorted { $0.calls > $1.calls }
            byHost[host]?.costCurrency = prices.currency
        }
        if let q = readJSON(pm.quotaPath) {
            for (host, v) in q {
                guard let d = v as? [String: Any] else { continue }
                var p = byHost[host] ?? APIProviderStatus(host: host, provider: d["provider"] as? String ?? host)
                let cap = (d["captured_at"] as? NSNumber)?.doubleValue
                if let e = d["error"] as? String { p.quotaError = e }
                let kind = d["kind"] as? String ?? ""
                if kind == "quota" {
                    p.plan = d["plan"] as? String ?? ""
                    let wins = d["windows"] as? [String: Any] ?? [:]
                    func win(_ k: String) -> QuotaWindow? {
                        guard let w = wins[k] as? [String: Any], let used = clampPct(w["used_pct"] as? NSNumber) else { return nil }
                        return QuotaWindow(usedPct: used, resetsAt: (w["resets_at"] as? NSNumber)?.doubleValue, capturedAt: cap)
                    }
                    p.fiveHour = win("5h")
                    p.sevenDay = win("weekly")
                } else if kind == "balance" {
                    p.balanceText = balanceText(d)
                }
                byHost[host] = p
            }
        }
        st.hasPriceTable = !prices.isEmpty
        st.priceAsOf = prices.asOf
        st.providers = byHost.values.sorted { $0.lastTS > $1.lastTS }
        return st
    }

    // MARK: 清理动作

    // 连续两次扫描都在、且已孤儿 minSeconds 以上，才允许静默清理
    private var orphanFirstSeen: [Int: (at: TimeInterval, cmd: String)] = [:]

    public func stableOrphans(_ orphans: [OrphanProc], minSeconds: Double) -> [OrphanProc] {
        lock.lock(); defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        var next: [Int: (at: TimeInterval, cmd: String)] = [:]
        var out: [OrphanProc] = []
        for o in orphans {
            if let prev = orphanFirstSeen[o.pid], prev.cmd == o.cmd {
                next[o.pid] = prev
                if now - prev.at >= minSeconds { out.append(o) }
            } else {
                next[o.pid] = (now, o.cmd)      // 第一次见到，这轮不动它
            }
        }
        orphanFirstSeen = next
        return out
    }

    /// 按「快照里记下的命令行」逐个复核后再杀。
    /// 面板上的快照最多 8 秒前，而 macOS 的 pid 会回绕复用 —— 直接按旧 pid 开枪有可能打到刚起来的别的进程。
    /// 复核：pid 仍存在、ppid 仍为 1、命令行与快照一致；任一不符就跳过。
    /// 先 SIGTERM，300ms 后仍存活的补 SIGKILL。
    public func killProcesses(_ targets: [OrphanProc]) -> (killed: Int, skipped: Int, freedMB: Double) {
        if targets.isEmpty { return (0, 0, 0) }
        lock.lock()
        let live = readProcs()
        lock.unlock()

        var confirmed: [OrphanProc] = []
        var skipped = 0
        for t in targets {
            guard let p = live[t.pid], p.ppid == 1, p.cmd == t.cmd else {
                skipped += 1
                log.notice("kill skipped pid=\(t.pid) (已消失或 pid 被复用)")
                continue
            }
            confirmed.append(t)
        }
        for t in confirmed { kill(pid_t(t.pid), SIGTERM) }
        usleep(300_000)
        for t in confirmed where kill(pid_t(t.pid), 0) == 0 { kill(pid_t(t.pid), SIGKILL) }
        return (confirmed.count, skipped, confirmed.reduce(0.0) { $0 + $1.memMB })
    }

    public func cleanNPXCache() -> Double {
        lock.lock(); defer { lock.unlock() }
        let npxPath = "\(home)/.npm/_npx"
        guard FileManager.default.fileExists(atPath: npxPath) else { return 0.0 }
        npxCache = nil
        let freedMB = npxCacheSizeMB()
        _ = execute("/bin/rm -rf '\(npxPath)'/*")
        npxCache = nil
        return freedMB
    }
}
