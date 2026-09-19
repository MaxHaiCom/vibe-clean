import Foundation
import os
import Darwin

// MARK: - 网络数据模型

public struct AIExitStatus: Identifiable, Equatable {
    public let id: String
    public var name: String
    public var host: String
    public var ip: String = ""
    public var loc: String = ""
    public var colo: String = ""
    public var latencyMS: Int = 0
    public var attemptedAt: TimeInterval = 0
    public var capturedAt: TimeInterval = 0
    public var error: String = ""
    public var changed: Bool = false
    public var previousIP: String = ""
    public var previousAt: TimeInterval = 0
    public var changedNewIP: String = ""
    public var isGemini: Bool = false

    public init(id: String, name: String, host: String, isGemini: Bool = false) {
        self.id = id; self.name = name; self.host = host; self.isGemini = isGemini
    }
}

public struct ProxyGroupStatus: Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public let type: String
    public let now: String
}

public struct AIConnectionStatus: Identifiable, Equatable {
    public var id: String { name }
    public let name: String
    public var count: Int = 0
    public var chains: [String] = []
    public var rules: [String] = []
}

public struct ProxyKernelStatus: Equatable {
    public var running = false
    public var version = ""
    public var error = ""
    public var groups: [ProxyGroupStatus] = []
    public var connections: [AIConnectionStatus] = []
}

public struct LocalNetworkStatus: Equatable {
    public var gateway = ""
    public var interfaceName = ""
    public var ipv4 = ""
    public var ipv6 = ""
    public var dnsServers: [String] = []
    public var wifiName = ""
    public var tailscaleIP = ""
    public var uploadBPS: Double?
    public var downloadBPS: Double?
    public var capturedAt: TimeInterval = 0
}

public enum DNSLeakVerdict: String, Equatable {
    case domesticWarning = "DNS 可能漏到国内 ⚠️"
    case proxyOK = "DNS 走代理内核 ✓"
    case unknown = "DNS 查不到（本机 resolver 无法判断）"
}

public struct LeakCheckStatus: Equatable {
    public var ipv6Blocked: Bool?
    public var ipv6Country = ""
    public var ipv6Message = "未检测"
    public var dnsVerdict: DNSLeakVerdict = .unknown
    public var checkedAt: TimeInterval = 0
}

public struct NetworkSnapshot: Equatable {
    public var aiExits: [AIExitStatus] = []
    public var proxy = ProxyKernelStatus()
    public var local = LocalNetworkStatus()
    public var leak = LeakCheckStatus()
    public var capturedAt: TimeInterval = 0
    public var isRefreshing = false
}

public struct ExitChangeEvent: Equatable {
    public let aiName: String
    public let oldIP: String
    public let newIP: String
    public let oldLoc: String
    public let newLoc: String
    public let changedAt: TimeInterval

    public var isCountryChange: Bool { !oldLoc.isEmpty && !newLoc.isEmpty && oldLoc != newLoc }
}

// MARK: - 纯函数（网络自测与 UI 共用）

/// Cloudflare trace 是键值行；只接受同时有出口 IP 的响应，缺字段时明确显示查不到。
public func parseTrace(_ text: String) -> (ip: String, loc: String, colo: String)? {
    var values: [String: String] = [:]
    for line in text.components(separatedBy: .newlines) {
        let pair = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard pair.count == 2 else { continue }
        values[pair[0].trimmingCharacters(in: .whitespacesAndNewlines)] = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let ip = values["ip"], isValidIP(ip), let loc = values["loc"], !loc.isEmpty,
          let colo = values["colo"], !colo.isEmpty else { return nil }
    return (ip, loc, colo)
}

private func isValidIP(_ value: String) -> Bool {
    if !value.contains(":") {
        var address = in_addr()
        return value.withCString { inet_pton(AF_INET, $0, &address) == 1 }
    }
    guard value.contains(":") else { return false }
    var address = in6_addr()
    return value.withCString { inet_pton(AF_INET6, $0, &address) == 1 }
}

public func rate(prev: UInt64, cur: UInt64, dt: TimeInterval) -> Double? {
    guard dt.isFinite, dt > 0, cur >= prev else { return nil } // 回绕或网卡重置不能显示成负速率；采样间隔由后台调度保证至少 2 秒
    return Double(cur - prev) / dt
}

public func rate(prev: Int64, cur: Int64, dt: TimeInterval) -> Double? {
    guard prev >= 0, cur >= 0 else { return nil }
    return rate(prev: UInt64(prev), cur: UInt64(cur), dt: dt)
}

public func dnsVerdict(_ nameservers: [String]) -> DNSLeakVerdict {
    let domestic: Set<String> = ["223.5.5.5", "223.6.6.6", "119.29.29.29", "114.114.114.114", "180.76.76.76", "1.12.12.12", "120.53.53.53"]
    let normalized = nameservers.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")) }
    guard !normalized.isEmpty else { return .unknown }
    if normalized.contains(where: { domestic.contains($0) }) { return .domesticWarning }
    let valid = normalized.filter { isValidIP($0) }
    guard valid.count == normalized.count else { return .unknown }
    let proxy = valid.filter { ip in
        if ip.hasPrefix("127.") || ip == "::1" { return true }
        let p = ip.split(separator: ".").compactMap { Int($0) }
        return p.count == 4 && p[0] == 198 && (p[1] == 18 || p[1] == 19)
    }
    return proxy.count == valid.count ? .proxyOK : .unknown
}

public func exitChange(previous: AIExitStatus, current: AIExitStatus) -> ExitChangeEvent? {
    guard !previous.ip.isEmpty, !current.ip.isEmpty,
          previous.ip != current.ip || (!previous.loc.isEmpty && previous.loc != current.loc) else { return nil }
    return ExitChangeEvent(aiName: current.name, oldIP: previous.ip, newIP: current.ip,
                           oldLoc: previous.loc, newLoc: current.loc,
                           changedAt: current.capturedAt)
}

// MARK: - 后台网络采集

public final class NetworkScanner {
    public static let shared = NetworkScanner()

    private let lock = NSRecursiveLock()
    private let log = Logger(subsystem: "com.haifeng.vibegauge", category: "network")
    private let worker = DispatchQueue(label: "com.haifeng.vibegauge.network", qos: .utility)
    private let rateQueue = DispatchQueue(label: "com.haifeng.vibegauge.network.rate", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var rateTimer: DispatchSourceTimer?
    private var running = false
    private var refreshInFlight = false
    private var snapshotCache = NetworkSnapshot()
    private var exitEvents: [ExitChangeEvent] = []
    private var lastTraceAt: TimeInterval = 0
    private var lastManualTraceAt: TimeInterval = 0
    private var lastProxyAt: TimeInterval = 0
    private var lastLocalAt: TimeInterval = 0
    private var lastLeakAt: TimeInterval = 0
    private var previousCounters: (iface: String, input: UInt64, output: UInt64, at: TimeInterval)?
    private let defaults = UserDefaults.standard

    private struct Target {
        let id: String; let name: String; let host: String
        var url: URL { URL(string: "https://\(host)/cdn-cgi/trace")! }
    }

    private let targets = [
        Target(id: "claude", name: "Claude", host: "api.anthropic.com"),
        Target(id: "chatgpt", name: "ChatGPT/Codex", host: "chatgpt.com"),
        Target(id: "openai", name: "OpenAI API", host: "api.openai.com"),
        Target(id: "grok", name: "Grok", host: "grok.com")
    ]

    private init() {
        var initial = targets.map { AIExitStatus(id: $0.id, name: $0.name, host: $0.host) }
        initial.append(AIExitStatus(id: "gemini", name: "Gemini", host: "generativelanguage.googleapis.com", isGemini: true))
        snapshotCache.aiExits = initial
    }

    /// 启动后仅安排后台工作；面板每秒读取的 snapshot 永远只拿锁读缓存。
    public func start() {
        lock.lock()
        guard !running else { lock.unlock(); return }
        running = true
        lock.unlock()
        worker.async { [weak self] in self?.refresh(forceTrace: true, forceAll: true) }
        let t = DispatchSource.makeTimerSource(queue: worker)
        t.schedule(deadline: .now() + 2, repeating: 2)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        let rt = DispatchSource.makeTimerSource(queue: rateQueue)
        rt.schedule(deadline: .now() + 2, repeating: 2)
        rt.setEventHandler { [weak self] in self?.sampleRate() }
        rt.resume()
        lock.lock(); timer = t; rateTimer = rt; lock.unlock()
    }

    public func snapshot() -> NetworkSnapshot {
        lock.lock(); defer { lock.unlock() }
        return snapshotCache
    }

    /// 手动重测只跳过 60 秒门槛，仍保留 10 秒防抖，防止按钮连点打满网络。
    public func forceRefresh() {
        let now = Date().timeIntervalSince1970
        lock.lock()
        guard now - lastManualTraceAt >= 10, !refreshInFlight else { lock.unlock(); return }
        lastManualTraceAt = now
        lock.unlock()
        worker.async { [weak self] in self?.refresh(forceTrace: true, forceAll: false) }
    }

    public func drainExitEvents() -> [ExitChangeEvent] {
        lock.lock(); defer { lock.unlock() }
        let out = exitEvents
        exitEvents.removeAll(keepingCapacity: true)
        return out
    }

    private func tick() {
        let now = Date().timeIntervalSince1970
        lock.lock()
        let doTrace = now - lastTraceAt >= 60
        let doProxy = now - lastProxyAt >= 10
        let doLocal = now - lastLocalAt >= 30
        let doLeak = now - lastLeakAt >= 600
        let busy = refreshInFlight
        lock.unlock()
        guard !busy, doTrace || doProxy || doLocal || doLeak else { return }
        refresh(forceTrace: doTrace, forceAll: false)
    }

    private func refresh(forceTrace: Bool, forceAll: Bool) {
        lock.lock()
        guard !refreshInFlight else { lock.unlock(); return }
        refreshInFlight = true
        snapshotCache.isRefreshing = true
        lock.unlock()
        defer {
            lock.lock(); refreshInFlight = false; snapshotCache.isRefreshing = false; lock.unlock()
        }

        let now = Date().timeIntervalSince1970
        lock.lock()
        let doProxy = forceAll || now - lastProxyAt >= 10
        let doLocal = forceAll || now - lastLocalAt >= 30
        let doLeak = forceAll || now - lastLeakAt >= 600
        lock.unlock()

        if forceTrace {
            let group = DispatchGroup()
            var results: [(Target, AIExitStatus)] = []
            let resultLock = NSLock()
            for target in targets {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    let result = self.probe(target)
                    resultLock.lock(); results.append((target, result)); resultLock.unlock()
                    group.leave()
                }
            }
            group.wait()
            applyTrace(results)
            lock.lock(); lastTraceAt = now; lock.unlock()
        }
        if doProxy {
            let proxy = probeProxy()
            lock.lock(); snapshotCache.proxy = proxy; lastProxyAt = now; lock.unlock()
            applyGeminiConnections(proxy)
        }
        if doLocal {
            let local = probeLocal()
            lock.lock()
            // 本机重扫与独立速率采样并发时，保留已有速率，避免一次较慢的 ifconfig 把速率清成采样中。
            var merged = local
            if snapshotCache.local.interfaceName == local.interfaceName {
                merged.downloadBPS = snapshotCache.local.downloadBPS
                merged.uploadBPS = snapshotCache.local.uploadBPS
            }
            snapshotCache.local = merged; lastLocalAt = now; lock.unlock()
        }
        if doLeak {
            let leak = probeLeak()
            lock.lock(); snapshotCache.leak = leak; lastLeakAt = now; lock.unlock()
        }
        lock.lock(); snapshotCache.capturedAt = now; lock.unlock()
    }

    private func applyTrace(_ values: [(Target, AIExitStatus)]) {
        // UserDefaults 是文件/偏好存储，不能在快照锁内读写；先取一份数组，最后只短暂交换结果。
        lock.lock(); var exits = snapshotCache.aiExits; lock.unlock()
        var newEvents: [ExitChangeEvent] = []
        for (target, incoming) in values {
            guard let i = exits.firstIndex(where: { $0.id == target.id }) else { continue }
            var next = incoming
            if !incoming.error.isEmpty {
                // 失败时清空当前成功值，避免把上一次出口冒充成这次仍然有效；成功时间也不前移。
                exits[i].ip = ""; exits[i].loc = ""; exits[i].colo = ""; exits[i].latencyMS = 0
                exits[i].attemptedAt = incoming.attemptedAt; exits[i].capturedAt = incoming.attemptedAt; exits[i].error = incoming.error
                continue
            }
            let saved = defaults.dictionary(forKey: "vg.aiExit.\(target.name)")
            let old = saved?["ip"] as? String ?? defaults.string(forKey: "vg.aiExit.\(target.name)") ?? ""
            let previousLoc = saved?["loc"] as? String ?? ""
            var previous = AIExitStatus(id: target.id, name: target.name, host: target.host)
            previous.ip = old; previous.loc = previousLoc
            next.changed = exits[i].changed
            next.previousIP = exits[i].previousIP
            next.previousAt = exits[i].previousAt
            next.changedNewIP = exits[i].changedNewIP
            if let event = exitChange(previous: previous, current: incoming) {
                let changedAt = incoming.capturedAt
                next.changed = true; next.previousIP = old; next.previousAt = changedAt; next.changedNewIP = incoming.ip
                // 通知开关与十分钟冷却属于 AppDelegate；队列保留每次真实变化，关闭通知时不会吞掉状态。
                newEvents.append(event)
            }
            defaults.set(["ip": incoming.ip, "loc": incoming.loc, "capturedAt": incoming.capturedAt], forKey: "vg.aiExit.\(target.name)")
            exits[i] = next
        }
        lock.lock(); snapshotCache.aiExits = exits; exitEvents.append(contentsOf: newEvents); lock.unlock()
    }

    private func applyGeminiConnections(_ proxy: ProxyKernelStatus) {
        let connection = proxy.connections.first(where: { $0.name == "Gemini" })
        let message: String
        if !proxy.error.isEmpty { message = "查不到出口：代理连接表不可用" }
        else if connection?.count ?? 0 == 0 { message = "无活动连接，查不到出口" }
        else if connection?.chains.isEmpty != false { message = "有活动连接，但连接表未提供出站链路" }
        else { message = "走出站：" + connection!.chains.joined(separator: "、") }
        lock.lock(); defer { lock.unlock() }
        guard let i = snapshotCache.aiExits.firstIndex(where: { $0.id == "gemini" }) else { return }
        snapshotCache.aiExits[i].error = message
        snapshotCache.aiExits[i].capturedAt = Date().timeIntervalSince1970
    }

    private func probe(_ target: Target) -> AIExitStatus {
        var status = AIExitStatus(id: target.id, name: target.name, host: target.host)
        status.attemptedAt = Date().timeIntervalSince1970
        let started = Date().timeIntervalSince1970
        do {
            let text = try request(target.url, timeout: 8, headers: ["Connection": "close"])
            guard let trace = parseTrace(text) else { status.error = "响应缺少有效的 ip / loc / colo 字段"; return status }
            status.ip = trace.ip; status.loc = trace.loc; status.colo = trace.colo
            status.latencyMS = max(0, Int(((Date().timeIntervalSince1970 - started) * 1000).rounded()))
            status.capturedAt = Date().timeIntervalSince1970
        } catch { status.error = "请求失败：\(error.localizedDescription)" }
        return status
    }

    private func probeProxy() -> ProxyKernelStatus {
        var result = ProxyKernelStatus()
        guard let base = clashBaseURL() else { result.error = "未检测到代理内核（clash API 未开或端口不对）"; return result }
        do {
            let version = try jsonRequest(base, path: "/version")
            guard let versionText = (version["version"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) ?? (version["meta"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) else { throw ScanError.invalidResponse }
            result.running = true
            result.version = versionText
            let proxies = try jsonRequest(base, path: "/proxies")
            guard let all = proxies["proxies"] as? [String: Any] else { throw ScanError.invalidResponse }
            result.groups = all.compactMap { name, raw in
                guard let p = raw as? [String: Any], let type = p["type"] as? String,
                      ["Selector", "URLTest", "Fallback"].contains(type) else { return nil }
                return ProxyGroupStatus(name: name, type: type, now: p["now"] as? String ?? "")
            }.sorted { $0.name < $1.name }
            let connections = try jsonRequest(base, path: "/connections")
            guard let parsed = NetworkScanner.parseConnections(connections) else { throw ScanError.invalidResponse }
            result.connections = parsed
        } catch { result.error = "未检测到代理内核（clash API 未开或端口不对）" }
        return result
    }

    public static func parseConnections(_ json: [String: Any]) -> [AIConnectionStatus]? {
        // 先匹配 api.openai.com，再匹配 openai.com，避免 API 流量被归到 ChatGPT。
        let suffixes: [(String, [String])] = [("Claude", ["anthropic.com", "claude.ai"]), ("OpenAI API", ["api.openai.com"]),
                                               ("ChatGPT/Codex", ["chatgpt.com", "openai.com"]), ("Grok", ["x.ai", "grok.com"]),
                                               ("Gemini", ["googleapis.com", "gemini.google.com"])]
        var out = suffixes.map { AIConnectionStatus(name: $0.0) }
        guard let list = json["connections"] as? [[String: Any]] else { return nil }
        for c in list {
            let host = (((c["metadata"] as? [String: Any])?["host"] as? String) ?? (c["host"] as? String) ?? "")
                .lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            guard let i = suffixes.firstIndex(where: { $0.1.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) }) else { continue }
            out[i].count += 1
            if let chains = c["chains"] as? [String], !chains.isEmpty { out[i].chains.append(chains.joined(separator: " → ")) }
            let rule = (c["rule"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let payload = (c["rulePayload"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !rule.isEmpty && !payload.isEmpty { out[i].rules.append("\(rule):\(payload)") }
            else if !rule.isEmpty { out[i].rules.append(rule) }
            else if !payload.isEmpty { out[i].rules.append(payload) }
        }
        for i in out.indices {
            var seenChains = Set<String>(); out[i].chains = out[i].chains.filter { seenChains.insert($0).inserted }
            var seenRules = Set<String>(); out[i].rules = out[i].rules.filter { seenRules.insert($0).inserted }
        }
        return out
    }

    private func probeLocal() -> LocalNetworkStatus {
        var local = LocalNetworkStatus()
        let route = execute("/sbin/route", ["-n", "get", "default"], timeout: 3)
        for line in route.components(separatedBy: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2, pair[0] == "gateway" { local.gateway = pair[1] }
            if pair.count == 2, pair[0] == "interface" { local.interfaceName = pair[1] }
        }
        if !local.interfaceName.isEmpty {
            let ifconfig = execute("/sbin/ifconfig", [local.interfaceName], timeout: 3)
            for line in ifconfig.components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("inet "), local.ipv4.isEmpty { local.ipv4 = t.split(separator: " ").dropFirst().first.map(String.init) ?? "" }
                if t.hasPrefix("inet6 ") {
                    let value = t.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let candidate = value.components(separatedBy: "%").first ?? value
                    if Self.isGlobalIPv6(candidate) { local.ipv6 = candidate }
                }
            }
            let wifi = execute("/usr/sbin/networksetup", ["-getairportnetwork", local.interfaceName], timeout: 3)
            let name = wifi.components(separatedBy: ":").dropFirst().joined(separator: ":").trimmingCharacters(in: .whitespacesAndNewlines)
            // 没连 Wi-Fi 时输出里没有冒号（"You are not associated…"），不能一律说成权限问题
            if !name.isEmpty, !name.localizedCaseInsensitiveContains("error") { local.wifiName = name }
            else { local.wifiName = wifi.contains("not associated") ? "未连接 Wi-Fi" : "查不到（可能需定位权限）" }
        }
        let dns = execute("/usr/sbin/scutil", ["--dns"], timeout: 3)
        local.dnsServers = NetworkScanner.parseDNS(dns)
        local.tailscaleIP = tailscaleIP() ?? ""
        local.capturedAt = Date().timeIntervalSince1970
        return local
    }

    public static func parseNetstat(_ text: String, iface: String) -> (input: UInt64, output: UInt64)? {
        let rows = text.components(separatedBy: "\n").map { $0.split(whereSeparator: { $0.isWhitespace }).map(String.init) }
        guard let header = rows.first(where: { $0.contains("Ibytes") && $0.contains("Obytes") }),
              let ii = header.firstIndex(of: "Ibytes"), let oi = header.firstIndex(of: "Obytes") else { return nil }
        for row in rows where row.first == iface && row.count > max(ii, oi) {
            guard let input = UInt64(row[ii]), let output = UInt64(row[oi]) else { continue }
            return (input, output)
        }
        return nil
    }

    static func isGlobalIPv6(_ value: String) -> Bool {
        guard isValidIP(value), value.contains(":"), let first = value.split(separator: ":").first,
              let prefix = UInt16(first, radix: 16) else { return false }
        return prefix & 0xe000 == 0x2000
    }

    private func sampleRate() {
        lock.lock(); let iface = snapshotCache.local.interfaceName; lock.unlock()
        guard !iface.isEmpty else {
            lock.lock(); snapshotCache.local.downloadBPS = nil; snapshotCache.local.uploadBPS = nil; previousCounters = nil; lock.unlock()
            return
        }
        let text = execute("/usr/sbin/netstat", ["-ib", "-I", iface], timeout: 2)
        guard let c = NetworkScanner.parseNetstat(text, iface: iface) else {
            lock.lock(); snapshotCache.local.downloadBPS = nil; snapshotCache.local.uploadBPS = nil; previousCounters = nil; lock.unlock()
            return
        }
        let now = Date().timeIntervalSince1970
        lock.lock(); defer { lock.unlock() }
        guard snapshotCache.local.interfaceName == iface else { previousCounters = nil; return }
        if let prev = previousCounters, prev.iface == iface, now - prev.at < 2 { return }
        if let prev = previousCounters, prev.iface == iface {
            snapshotCache.local.downloadBPS = rate(prev: prev.input, cur: c.input, dt: now - prev.at)
            snapshotCache.local.uploadBPS = rate(prev: prev.output, cur: c.output, dt: now - prev.at)
        } else {
            snapshotCache.local.downloadBPS = nil; snapshotCache.local.uploadBPS = nil
        }
        previousCounters = (iface, c.input, c.output, now)
    }

    public static func parseDNS(_ text: String) -> [String] {
        var out: [String] = []; var resolver = false
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if resolver && trimmed.hasPrefix("resolver #") { break }
            if trimmed == "resolver #1" { resolver = true; continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if resolver, t.hasPrefix("nameserver["), let value = t.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces), !value.isEmpty { out.append(String(value)) }
        }
        return Array(NSOrderedSet(array: out)) as? [String] ?? []
    }

    private func tailscaleIP() -> String? {
        let which = execute("/usr/bin/which", ["tailscale"], timeout: 2).trimmingCharacters(in: .whitespacesAndNewlines)
        if !which.isEmpty { let value = execute(which, ["ip", "-4"], timeout: 3).trimmingCharacters(in: .whitespacesAndNewlines); if isTailscaleIPv4(value) { return value } }
        let list = execute("/sbin/ifconfig", [], timeout: 3)
        var current = ""
        for line in list.components(separatedBy: "\n") {
            if !line.hasPrefix("\t") && !line.hasPrefix(" ") { current = line.split(separator: ":").first.map(String.init) ?? "" }
            let t = line.trimmingCharacters(in: .whitespaces)
            if current.hasPrefix("utun"), t.hasPrefix("inet ") {
                let ip = t.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                if isTailscaleIPv4(ip) { return ip }
            }
        }
        return nil
    }

    private func isTailscaleIPv4(_ ip: String) -> Bool {
        let p = ip.split(separator: ".").compactMap { Int($0) }
        guard isValidIP(ip), p.count == 4, p[0] == 100 else { return false }
        return p[1] >= 64 && p[1] <= 127
    }

    private func probeLeak() -> LeakCheckStatus {
        var leak = LeakCheckStatus()
        let marker = "__VG_STATUS__"
        let text = execute("/usr/bin/curl", ["-q", "-6", "-s", "-m", "5", "--noproxy", "*", "-w", "\n\(marker)%{http_code}\n", "https://www.cloudflare.com/cdn-cgi/trace"], timeout: 7)
        let pieces = text.components(separatedBy: marker)
        let body = pieces.first ?? text
        let httpStatus = pieces.dropFirst().first.flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        if let trace = parseTrace(body) { leak.ipv6Blocked = false; leak.ipv6Country = trace.loc; leak.ipv6Message = "IPv6 可直连（可能绕过代理隧道）⚠️" }
        else if httpStatus > 0 { leak.ipv6Blocked = false; leak.ipv6Message = "IPv6 可直连（响应无 trace）⚠️" }
        else { leak.ipv6Blocked = true; leak.ipv6Message = "IPv6 出站已阻断 ✓" }
        lock.lock(); let dns = snapshotCache.local.dnsServers; lock.unlock()
        leak.dnsVerdict = dnsVerdict(dns); leak.checkedAt = Date().timeIntervalSince1970
        return leak
    }

    private func clashBaseURL() -> URL? {
        Self.validatedClashURL(defaults.string(forKey: "clashAPI") ?? "http://127.0.0.1:9090")
    }

    static func validatedClashURL(_ raw: String) -> URL? {
        guard var components = URLComponents(string: raw), let host = components.host?.lowercased(),
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
              ["http", "https"].contains(components.scheme ?? ""), components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        if host == "localhost" { components.host = "127.0.0.1" }
        return components.url
    }

    private func jsonRequest(_ base: URL, path: String) throws -> [String: Any] {
        var u = base; u.appendPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        var headers = ["Connection": "close"]
        if let secret = defaults.string(forKey: "clashSecret"), !secret.isEmpty { headers["Authorization"] = "Bearer \(secret)" }
        let data = try requestData(u, timeout: 5, headers: headers)
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ScanError.invalidResponse }
        return j
    }

    private func request(_ url: URL, timeout: TimeInterval, headers: [String: String]) throws -> String { String(data: try requestData(url, timeout: timeout, headers: headers), encoding: .utf8) ?? "" }

    private func requestData(_ url: URL, timeout: TimeInterval, headers: [String: String]) throws -> Data {
        var req = URLRequest(url: url); req.timeoutInterval = timeout; req.httpMethod = "GET"
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil; config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        // 本机控制端口不经过系统 HTTP 代理，避免把 clashSecret 发到代理服务器。
        if Self.validatedClashURL(url.deletingLastPathComponent().absoluteString) != nil { config.connectionProxyDictionary = [:] }
        let session = URLSession(configuration: config, delegate: NoRedirectDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let resultBox = RequestResult()
        let sem = DispatchSemaphore(value: 0)
        session.dataTask(with: req) { data, response, error in
            let value: Result<Data, Error>
            if let error { value = .failure(error) }
            else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { value = .failure(ScanError.http(http.statusCode)) }
            else { value = .success(data ?? Data()) }
            resultBox.lock.lock(); resultBox.value = value; resultBox.lock.unlock()
            sem.signal()
        }.resume()
        if sem.wait(timeout: .now() + timeout + 1) == .timedOut { session.invalidateAndCancel(); throw ScanError.timeout }
        resultBox.lock.lock(); defer { resultBox.lock.unlock() }
        guard let result = resultBox.value else { throw ScanError.invalidResponse }
        return try result.get()
    }

    private enum ScanError: LocalizedError { case timeout, invalidResponse, http(Int); var errorDescription: String? { switch self { case .timeout: return "请求超时"; case .invalidResponse: return "响应格式不正确"; case .http(let code): return "HTTP \(code)" } } }
    private final class RequestResult {
        let lock = NSLock()
        var value: Result<Data, Error>?
    }
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate { func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) } }

    private func execute(_ path: String, _ args: [String], timeout: TimeInterval) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { return "" }
        let box = RequestResult()
        let readDone = DispatchSemaphore(value: 0)
        // 持续排空管道，避免命令因 stdout 满而无法退出；读完才把结果交给调用方。
        DispatchQueue.global(qos: .utility).async {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            box.lock.lock(); box.value = .success(data); box.lock.unlock()
            readDone.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            log.warning("只读命令超时：\(path, privacy: .public)")
            process.terminate()
            if done.wait(timeout: .now() + 0.2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            return ""
        }
        guard readDone.wait(timeout: .now() + 1) == .success, process.terminationStatus == 0 else { return "" }
        box.lock.lock(); defer { box.lock.unlock() }
        guard case let .success(data) = box.value else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
