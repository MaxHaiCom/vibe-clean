import Foundation
import CryptoKit
import os

/// 只缓存用量字段，不保存对话正文；按文件保留贡献，才能在日志重写后撤销旧账。
public final class UsageHistory {
    public static let shared = UsageHistory()

    public struct ModelTotals: Codable, Equatable {
        public var ctx: Int64 = 0
        public var cacheRead: Int64 = 0
        public var cacheWrite: Int64 = 0
        public var out: Int64 = 0
        public var think: Int64 = 0
        public var tokenTotal: Int64 { ctx + out }
        mutating func add(_ other: ModelTotals) {
            ctx += other.ctx; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite
            out += other.out; think += other.think
        }
    }

    public struct Totals: Codable, Equatable {
        public var ctx: Int64 = 0
        public var cacheRead: Int64 = 0
        public var cacheWrite: Int64 = 0
        public var out: Int64 = 0
        public var think: Int64 = 0
        public var turns = 0
        public var sessions = 0
        public var models: [String: ModelTotals] = [:]
        public var tokenTotal: Int64 { ctx + out }
        public var newInput: Int64 { max(0, ctx - cacheRead - cacheWrite) }
        public var cacheTotal: Int64 { cacheRead + cacheWrite }

        mutating func add(_ record: Record) {
            let u = record.usage
            ctx += u.ctx; cacheRead += u.cacheRead; cacheWrite += u.cacheWrite
            out += u.out; think += u.think; turns += 1
            models[record.model, default: ModelTotals()].add(u)
        }
        mutating func merge(_ other: Totals) {
            ctx += other.ctx; cacheRead += other.cacheRead; cacheWrite += other.cacheWrite
            out += other.out; think += other.think; turns += other.turns
            for (model, usage) in other.models { models[model, default: ModelTotals()].add(usage) }
        }
    }

    public struct Day: Codable, Equatable, Identifiable {
        public var id: String { date }
        public let date: String
        public var sources: [String: Totals]
        public var total: Totals { sources.values.reduce(into: Totals()) { $0.merge($1) } }
    }

    public struct Snapshot: Equatable {
        public var days: [Day] = []
        public var dailyTokens: [String: Int64] = [:]
        public var totals: [String: Totals] = [:]
        public var aggregate = Totals()
        public var earliestDate: String?
        public var activeDays = 0
        public var isScanning = false
        public var processedFiles = 0
        public var totalFiles = 0
        public var error = ""
        public var sourceNotes: [String: String] = [:]
        public var hasPriceTable = false
        public var priceCurrency = ""
        public var cost: Double?
        public var costBySource: [String: Double] = [:]
        public var unpricedModels = 0
        public var unpricedBySource: [String: Int] = [:]
        public var cumulativeTurns = 0
        public var skippedRecords = 0
        public var capturedAt: TimeInterval = 0
        public var tokenTotal: Int64 { aggregate.tokenTotal }
        public var ctx: Int64 { aggregate.ctx }
        public var cacheRead: Int64 { aggregate.cacheRead }
        public var cacheHitRate: Double? { ctx > 0 ? Double(cacheRead) / Double(ctx) : nil }
        public init() {}
    }

    /// 经记账代理的上游（"API · GLM" 这类）：同一请求多半已在 CLI 日志里，不进总数
    public static func isProxySource(_ source: String) -> Bool { source.hasPrefix("API") }

    /// 同值同档，零日留空；档位只由非零日的最近秩分位数决定。
    public static func levels(_ values: [Int64]) -> [Int] {
        let positive = values.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return values.map { _ in 0 } }
        let thresholds = (1...4).map { positive[max(0, Int(ceil(Double(positive.count) * Double($0) / 5)) - 1)] }
        return values.map { value in value <= 0 ? 0 : 1 + thresholds.filter { value > $0 }.count }
    }

    public static func dayKey(timestamp: TimeInterval, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: timestamp))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    public static func codexLastTokenUsage(_ fields: [String: Int64]) -> ModelTotals {
        ModelTotals(ctx: fields["input_tokens"] ?? 0, cacheRead: fields["cached_input_tokens"] ?? 0,
                    cacheWrite: fields["cache_write_input_tokens"] ?? 0, out: fields["output_tokens"] ?? 0,
                    think: fields["reasoning_output_tokens"] ?? 0)
    }

    /// 累计值回退时只建立新基线；不把负差变成零，也不把整个重置值再记一次。
    public static func codexCumulativeDelta(previous: [String: Int64]?, current: [String: Int64]) -> ModelTotals? {
        var delta: [String: Int64] = [:]
        for key in tokenKeys {
            let now = current[key] ?? 0, old = previous?[key] ?? 0
            guard now >= old else { return nil }
            delta[key] = now - old
        }
        let result = codexLastTokenUsage(delta)
        return result.tokenTotal > 0 ? result : nil
    }

    /// 同一累计快照可被额度刷新重复写入；不同请求即便单次 token 完全相同，也不能被去重。
    static func codexUsage(info: [String: Any], previous: inout [String: Int64]?) -> (usage: ModelTotals, cumulative: Bool)? {
        let total = tokenFields(info["total_token_usage"])
        let last = tokenFields(info["last_token_usage"])
        let old = previous
        if let total { previous = total }
        if let total, total == old { return nil }
        if let last { return (codexLastTokenUsage(last), false) }
        guard let total, let delta = codexCumulativeDelta(previous: old, current: total) else { return nil }
        return (delta, true)
    }

    struct Record: Codable, Equatable {
        var id: String
        var source: String
        var timestamp: TimeInterval
        var model: String
        var usage: ModelTotals
        var cumulative = false
    }

    /// 文件内同 requestId 后写覆盖前写，跨文件再选 timestamp 最新的，和即时扫描器口径一致。
    static func deduplicateClaude(_ files: [String: [Record]]) -> [String: Record] {
        var result: [String: Record] = [:]
        for path in files.keys.sorted() {
            var latest: [String: Record] = [:]
            for record in files[path] ?? [] { latest[record.id] = record }
            for (id, record) in latest {
                if let old = result[id], old.timestamp >= record.timestamp { continue }
                result[id] = record
            }
        }
        return result
    }

    private struct FileState: Codable {
        var source: String
        var model = "?"
        var size: UInt64 = 0
        var mtime: TimeInterval = 0
        var offset: UInt64 = 0
        var head = ""
        var previousTotal: [String: Int64]?
        var records: [String: Record] = [:]
        var skipped = 0
    }
    private struct DiskCache: Codable {
        var version = 3
        var files: [String: FileState] = [:]
        var days: [Day] = []
        var updatedAt: TimeInterval = 0
    }

    private let lock = NSLock()
    private let worker = DispatchQueue(label: "com.haifeng.vibegauge.usage-history", qos: .utility)
    private let log = Logger(subsystem: "com.haifeng.vibegauge", category: "usage-history")
    private let home: String
    private let cachePath: String
    private var timer: DispatchSourceTimer?
    private var started = false
    private var loaded = false
    private var errors: Set<String> = []
    private var cache = DiskCache()
    private var cached = Snapshot()
    /// 缓存约 30MB：有变化才写、且至少隔 30 分钟。崩溃丢掉的只是 offset 进度，
    /// 下次从旧 offset 重读，记录按 requestId/行偏移做键，重复读不会重复计数。
    private var dirty = false
    private var savedAt: TimeInterval = 0
    private static let saveEvery: TimeInterval = 1800
    private let iso = ISO8601DateFormatter()
    private let isoPlain = ISO8601DateFormatter()
    private static let tokenKeys = ["input_tokens", "cached_input_tokens", "cache_write_input_tokens", "output_tokens", "reasoning_output_tokens"]
    private static let usageMarker = Data("\"usage\"".utf8)
    private static let codexMarkers = ["\"token_count\"", "\"turn_context\"", "\"session_meta\""].map { Data($0.utf8) }

    public init(home: String = FileManager.default.homeDirectoryForCurrentUser.path, cachePath: String? = nil) {
        self.home = home
        self.cachePath = cachePath ?? "\(home)/.config/vibegauge/usage-daily.json"
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        isoPlain.formatOptions = [.withInternetDateTime]
    }

    public func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        worker.async { [weak self] in
            guard let self else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.worker)
            timer.schedule(deadline: .now(), repeating: 300)
            timer.setEventHandler { [weak self] in self?.scan() }
            self.timer = timer
            timer.resume()
        }
    }

    /// 锁只保护快照交换，不参与读盘、解码、归并或落盘。
    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    /// 自测的临时日志树也走真实增量路径，和定时扫描共用串行队列。
    func scanNowForTesting() { worker.sync { scan() } }

    private func scan() {
        errors = []
        publishProgress(0, total: 0)
        loadCache()
        let paths = discoverFiles()
        publishProgress(0, total: paths.count)
        for (index, item) in paths.enumerated() {
            autoreleasepool { process(item.path, source: item.source) }
            publishProgress(index + 1, total: paths.count)
        }
        var result = summarize()
        result.processedFiles = paths.count
        result.totalFiles = paths.count
        for source in ["Claude", "Codex"] where !paths.contains(where: { $0.source == source }) {
            result.sourceNotes[source] = result.totals[source] == nil ? "未检测到本机会话日志" : "日志已移除，显示已缓存历史"
        }
        cache.days = result.days
        cache.updatedAt = Date().timeIntervalSince1970
        if dirty, cache.updatedAt - savedAt >= Self.saveEvery {
            saveCache()
            dirty = false
            savedAt = cache.updatedAt
        }
        result.capturedAt = cache.updatedAt
        result.error = errors.sorted().joined(separator: "；")
        lock.lock()
        let old = cached
        cached = result
        lock.unlock()
        withExtendedLifetime(old) {}
        log.notice("历史汇总完成：\(paths.count) 文件，\(result.days.count) 天，跳过 \(result.skippedRecords) 条不完整记录")
    }

    private func discoverFiles() -> [(path: String, source: String)] {
        let fm = FileManager.default
        var result: [(path: String, source: String)] = []
        for (suffix, source) in [(".claude/projects", "Claude"), (".codex/sessions", "Codex")] {
            let root = URL(fileURLWithPath: "\(home)/\(suffix)")
            guard fm.fileExists(atPath: root.path) else { continue }
            guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], errorHandler: { _, _ in
                self.errors.insert("部分日志目录无法读取，汇总可能不完整")
                return true
            }) else { errors.insert("日志目录无法读取"); continue }
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                result.append((url.path, source))
            }
        }
        let api = "\(home)/.config/vibegauge/api-calls.jsonl"
        if fm.fileExists(atPath: api) { result.append((api, "API")) }
        return result.sorted { $0.path < $1.path }
    }

    private func process(_ path: String, source: String) {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            guard let mod = attrs[.modificationDate] as? Date, let size = (attrs[.size] as? NSNumber)?.uint64Value else { throw CocoaError(.fileReadUnknown) }
            let fh = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? fh.close() }
            let head = try fh.read(upToCount: 256) ?? Data()
            var state = cache.files[path] ?? FileState(source: source)
            let oldHead = Self.fingerprint(Data(head.prefix(Int(min(256, state.size)))))
            let rewritten = state.offset > size || size < state.size || (!state.head.isEmpty && oldHead != state.head)
                || (size == state.size && mod.timeIntervalSince1970 != state.mtime)
            if state.source != source || rewritten { state = FileState(source: source) }
            if state.size == size, state.mtime == mod.timeIntervalSince1970, state.head == Self.fingerprint(head) { return }
            try fh.seek(toOffset: state.offset)
            try readNewLines(fh, state: &state, size: size)
            state.head = Self.fingerprint(head)
            state.size = size; state.mtime = mod.timeIntervalSince1970
            cache.files[path] = state
            dirty = true
        } catch { errors.insert("部分日志无法读取，保留上次汇总并等待重试") }
    }

    private func readNewLines(_ fh: FileHandle, state: inout FileState, size: UInt64) throws {
        var remaining = size - state.offset
        var pending = Data()
        while remaining > 0 {
            guard let chunk = try fh.read(upToCount: Int(min(1_048_576, remaining))), !chunk.isEmpty else { break }
            remaining -= UInt64(chunk.count)
            pending.append(chunk)
            guard let lastNL = pending.lastIndex(of: 0x0A) else { continue }
            let end = pending.index(after: lastNL)
            let complete = pending[pending.startIndex..<end]
            var offset = state.offset
            for line in complete.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
                autoreleasepool { consume(Data(line), offset: offset, state: &state) }
                offset += UInt64(line.count + 1)
            }
            state.offset = offset
            pending = Data(pending[end...])
        }
    }

    private func consume(_ data: Data, offset: UInt64, state: inout FileState) {
        // 大多数行是工具结果和正文，先筛字段名，避免把数 GB 无关 JSON 全部解码。
        if state.source == "Claude", data.range(of: Self.usageMarker) == nil { return }
        if state.source == "Codex", !Self.codexMarkers.contains(where: { data.range(of: $0) != nil }) { return }
        guard !data.isEmpty else { return }
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { state.skipped += 1; return }
        if state.source == "Claude" {
            guard j["type"] as? String == "assistant", let msg = j["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { return }
            let model = msg["model"] as? String ?? "?"
            guard !model.contains("synthetic") else { return }
            guard let ts = timestamp(j["timestamp"]),
                  let id = (j["requestId"] as? String) ?? (msg["id"] as? String) ?? (j["uuid"] as? String), !id.isEmpty,
                  let input = number(usage["input_tokens"]), let output = number(usage["output_tokens"]) else { state.skipped += 1; return }
            let read = number(usage["cache_read_input_tokens"]) ?? 0
            let write = number(usage["cache_creation_input_tokens"]) ?? 0
            let think = number((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"]) ?? 0
            state.records[id] = Record(id: id, source: "Claude", timestamp: ts, model: model.isEmpty ? "?" : model,
                                       usage: ModelTotals(ctx: input + read + write, cacheRead: read, cacheWrite: write, out: output, think: think))
        } else if state.source == "Codex" {
            guard let payload = j["payload"] as? [String: Any] else { return }
            if ["turn_context", "session_meta"].contains(j["type"] as? String ?? "") {
                if let model = payload["model"] as? String, !model.isEmpty { state.model = model }
                return
            }
            guard j["type"] as? String == "event_msg", payload["type"] as? String == "token_count", let info = payload["info"] as? [String: Any] else { return }
            guard let parsed = Self.codexUsage(info: info, previous: &state.previousTotal) else { return }
            guard let ts = timestamp(j["timestamp"]) else { state.skipped += 1; return }
            let model = (payload["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? state.model
            let id = String(offset)
            state.records[id] = Record(id: id, source: "Codex", timestamp: ts, model: model, usage: parsed.usage, cumulative: parsed.cumulative)
        } else {
            guard let ts = timestamp(j["epoch"]) ?? timestamp(j["ts"]), let host = j["host"] as? String,
                  let ctx = number(j["ctx"]), let out = number(j["out"]) else { state.skipped += 1; return }
            let provider = (j["provider"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? host
            let model = (j["model"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "?"
            let id = String(offset)
            state.records[id] = Record(id: id, source: "API · " + provider, timestamp: ts, model: model,
                                       usage: ModelTotals(ctx: ctx, cacheRead: number(j["cache_read"]) ?? 0,
                                                          cacheWrite: number(j["cache_write"]) ?? 0, out: out, think: number(j["think"]) ?? 0))
        }
    }

    private static func tokenFields(_ raw: Any?) -> [String: Int64]? {
        guard let fields = raw as? [String: Any], fields["input_tokens"] is NSNumber, fields["output_tokens"] is NSNumber else { return nil }
        var result: [String: Int64] = [:]
        for key in tokenKeys {
            let n = (fields[key] as? NSNumber)?.int64Value ?? 0
            guard n >= 0 else { return nil }
            result[key] = n
        }
        return result
    }
    private func number(_ raw: Any?) -> Int64? {
        guard let n = raw as? NSNumber, n.int64Value >= 0 else { return nil }
        return n.int64Value
    }
    private func timestamp(_ raw: Any?) -> TimeInterval? {
        if let n = raw as? NSNumber { return n.doubleValue > 0 && n.doubleValue.isFinite ? n.doubleValue : nil }
        guard var text = raw as? String else { return nil }
        if let range = text.range(of: #"\.\d{4,}"#, options: .regularExpression) { text.replaceSubrange(range, with: text[range].prefix(4)) }
        return (iso.date(from: text) ?? isoPlain.date(from: text))?.timeIntervalSince1970
    }
    private static func fingerprint(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func loadCache() {
        guard !loaded else { return }
        loaded = true
        guard FileManager.default.fileExists(atPath: cachePath) else { return }
        do {
            let decoded = try JSONDecoder().decode(DiskCache.self, from: Data(contentsOf: URL(fileURLWithPath: cachePath)))
            guard decoded.version == 3 else { errors.insert("历史缓存版本变化，已重新汇总"); return }
            cache = decoded
        } catch { errors.insert("历史缓存无法读取，已重新汇总") }
    }
    private func saveCache() {
        do {
            let url = URL(fileURLWithPath: cachePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
            try JSONEncoder().encode(cache).write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cachePath)
        } catch { errors.insert("历史缓存保存失败，重启后需重新汇总") }
    }
    private func readJSON(_ path: String) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        do {
            guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            return json
        } catch { errors.insert("价目表无法读取，未计入成本"); return nil }
    }
    private func publishProgress(_ processed: Int, total: Int) {
        lock.lock()
        cached.isScanning = true; cached.processedFiles = processed; cached.totalFiles = total
        lock.unlock()
    }

    private func summarize() -> Snapshot {
        var result = Snapshot()
        var buckets: [String: [String: Totals]] = [:]
        var sessions: [String: Set<String>] = [:]
        var dailySessions: [String: [String: Set<String>]] = [:]
        var claudeFiles: [String: [Record]] = [:]
        var records: [Record] = []
        // 旧日志被清理后仍保留历史；同一路径重写时 process 已替换该文件的全部贡献。
        for (path, state) in cache.files {
            result.skippedRecords += state.skipped
            if state.source == "Claude" { claudeFiles[path] = Array(state.records.values) }
            else { records.append(contentsOf: state.records.values) }
            for record in state.records.values {
                let day = Self.dayKey(timestamp: record.timestamp)
                sessions[record.source, default: []].insert(path)
                dailySessions[day, default: [:]][record.source, default: []].insert(path)
            }
        }
        records.append(contentsOf: Self.deduplicateClaude(claudeFiles).values)
        for record in records {
            let day = Self.dayKey(timestamp: record.timestamp)
            buckets[day, default: [:]][record.source, default: Totals()].add(record)
            result.totals[record.source, default: Totals()].add(record)
            if record.cumulative { result.cumulativeTurns += 1 }
        }
        for source in result.totals.keys { result.totals[source]?.sessions = sessions[source]?.count ?? 0 }
        for day in buckets.keys {
            for source in buckets[day]!.keys { buckets[day]?[source]?.sessions = dailySessions[day]?[source]?.count ?? 0 }
        }
        result.days = buckets.keys.sorted().map { Day(date: $0, sources: buckets[$0]!) }
        result.earliestDate = result.days.first?.date
        // 经记账代理的 API 调用不计入总数与热力图：代理前面挂的多半就是 Claude Code / Codex，
        // 同一次请求在 CLI 日志里已经记过一次，再加就是重复计数。API 只单独出卡片。
        func cliTokens(_ d: Day) -> Int64 {
            d.sources.filter { !Self.isProxySource($0.key) }.values.reduce(0) { $0 + $1.tokenTotal }
        }
        result.dailyTokens = Dictionary(uniqueKeysWithValues: result.days.map { ($0.date, cliTokens($0)) })
        result.activeDays = result.dailyTokens.values.filter { $0 > 0 }.count
        for (source, totals) in result.totals where !Self.isProxySource(source) { result.aggregate.merge(totals) }
        let price = readJSON("\(home)/.config/vibegauge/prices.json").map { ProcessScanner.PriceTable(json: $0) } ?? ProcessScanner.PriceTable()
        result.hasPriceTable = !price.isEmpty
        result.priceCurrency = price.currency
        for (source, totals) in result.totals {
            for (model, usage) in totals.models {
                if let cost = price.cost(model: model, ctx: usage.ctx, cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite, out: usage.out) {
                    result.cost = (result.cost ?? 0) + cost
                    result.costBySource[source, default: 0] += cost
                } else {
                    result.unpricedModels += 1
                    result.unpricedBySource[source, default: 0] += 1
                }
            }
        }
        return result
    }
}

public extension Fmt {
    static func tokens(_ count: Int64) -> String {
        if count >= 100_000_000 { return String(format: "%.2f 亿", Double(count) / 100_000_000) }
        if count >= 10_000 { return String(format: "%.1f 万", Double(count) / 10_000) }
        return String(count)
    }
}
