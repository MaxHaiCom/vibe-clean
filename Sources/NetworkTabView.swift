import SwiftUI
import Foundation

/// 网络页只接收缓存快照；所有采集都由 NetworkScanner 的后台队列完成，避免菜单栏主线程被命令或网络请求卡住。
public struct NetworkTabView: View {
    public let snapshot: NetworkSnapshot
    public let onRetest: () -> Void
    public let width: CGFloat

    public init(snapshot: NetworkSnapshot, onRetest: @escaping () -> Void = {}, width: CGFloat = 331) {
        self.snapshot = snapshot; self.onRetest = onRetest; self.width = width
    }

    private var traceExits: [AIExitStatus] { snapshot.aiExits.filter { !$0.isGemini } }

    private var exitSummary: String {
        let good = traceExits.filter { !$0.ip.isEmpty && $0.error.isEmpty }
        guard !good.isEmpty else { return "出口暂不可用：查不到 AI trace" }
        let groups = Dictionary(grouping: good, by: { "\($0.ip)|\($0.loc)" })
        if groups.count == 1 { return "\(good.count) 家 AI 同一出口 · \(good[0].loc.isEmpty ? "国家未知" : good[0].loc)" }
        let places = good.map { "\($0.name.replacingOccurrences(of: "/Codex", with: "")) \($0.loc.isEmpty ? "未知" : $0.loc)" }.joined(separator: " / ")
        return "出口不一致：\(places) ⚠️"
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("网络")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                if snapshot.isRefreshing { ProgressView().controlSize(.mini) }
                Button(action: onRetest) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.plain)
                .help("立即重测（10 秒内最多一次）")
            }
            .padding(.horizontal, 10)
            Text(exitSummary)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(exitSummary.contains("不一致") ? .orange : .secondary)
                .lineLimit(2)
                .padding(.horizontal, 10)

            section("AI 出口") { aiExitSection }
            section("代理内核") { proxySection }
            section("本机") { localSection }
            section("泄漏体检") { leakSection }
        }
        .frame(width: width, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
            content()
        }
        .padding(10)
        .frame(width: width, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(8)
    }

    private var aiExitSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(snapshot.aiExits) { item in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(item.name).font(.system(size: 10.5, weight: .medium)).frame(width: 78, alignment: .leading)
                        if item.isGemini {
                            Text("由活动连接判断")
                                .font(.system(size: 9.5, design: .monospaced)).foregroundColor(.secondary)
                        } else if !item.error.isEmpty {
                            Text("查不到").font(.system(size: 9.5)).foregroundColor(.orange)
                                .help(item.error)
                        } else {
                            Text(item.ip.isEmpty ? "查不到" : item.ip)
                                .font(.system(size: 9.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                .help(item.ip.isEmpty ? "未检测到出口 IP" : item.ip)
                        }
                        Spacer(minLength: 0)
                        if item.changed {
                            Text("变过").font(.system(size: 8, weight: .bold)).padding(.horizontal, 3).padding(.vertical, 1)
                                .background(Color.orange.opacity(0.18)).foregroundColor(.orange).cornerRadius(3)
                                .help("旧 IP：\(item.previousIP) → 新 IP：\(item.changedNewIP.isEmpty ? item.ip : item.changedNewIP) · \(item.previousAt > 0 ? Fmt.dateText(item.previousAt) : "时间未知")")
                        }
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(!item.error.isEmpty ? item.error : item.isGemini ? "等待连接表采集" : "国家 \(item.loc.isEmpty ? "—" : item.loc) · 机房 \(item.colo.isEmpty ? "—" : item.colo)")
                            .font(.system(size: 8.8)).foregroundColor(item.error.isEmpty ? .secondary : .orange).lineLimit(2)
                            .help(item.error)
                        Spacer(minLength: 0)
                        if !item.isGemini {
                            Text(item.latencyMS > 0 ? "\(item.latencyMS)ms" : "—").font(.system(size: 8.5)).foregroundColor(.secondary)
                            if item.capturedAt > 0 { Text(Fmt.ago(max(0, Int(Date().timeIntervalSince1970 - item.capturedAt)))).font(.system(size: 8.5)).foregroundColor(.secondary) }
                        }
                    }
                }
            }
            if traceExits.allSatisfy({ $0.capturedAt == 0 }) { Text("等待后台采集…").font(.system(size: 9)).foregroundColor(.secondary) }
        }
    }

    private var proxySection: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !snapshot.proxy.error.isEmpty {
                Text(snapshot.proxy.error).font(.system(size: 9.5)).foregroundColor(.secondary)
            } else {
                HStack {
                    Text(snapshot.proxy.running ? "运行中" : "未检测到")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(snapshot.proxy.running ? .green : .secondary)
                    if !snapshot.proxy.version.isEmpty { Text("· \(snapshot.proxy.version)").font(.system(size: 9)).foregroundColor(.secondary) }
                }
                ForEach(snapshot.proxy.groups) { group in
                    HStack(spacing: 5) {
                        Text(group.name).font(.system(size: 9.5)).lineLimit(1)
                        Text(group.type).font(.system(size: 8)).foregroundColor(.secondary)
                        Spacer(); Text(group.now.isEmpty ? "未选择" : group.now).font(.system(size: 9, design: .monospaced)).lineLimit(1)
                    }
                }
                ForEach(snapshot.proxy.connections) { c in
                    if c.count > 0 {
                        HStack(spacing: 5) {
                            Text(c.name).font(.system(size: 9.5)); Text("\(c.count) 连接").font(.system(size: 9)).foregroundColor(.secondary)
                            if !c.chains.isEmpty { Text(c.chains.joined(separator: "、")).font(.system(size: 8.5)).foregroundColor(.secondary).lineLimit(1) }
                        }
                        if !c.rules.isEmpty {
                            Text("规则：" + c.rules.joined(separator: " / ")).font(.system(size: 8)).foregroundColor(.secondary).lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var localSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            localRow("默认路由", value: snapshot.local.gateway.isEmpty ? "查不到（系统未提供默认路由）" : "\(snapshot.local.gateway) · \(snapshot.local.interfaceName)")
            localRow("IPv4", value: snapshot.local.ipv4.isEmpty ? "未检测到接口 IPv4" : snapshot.local.ipv4)
            localRow("IPv6", value: snapshot.local.ipv6.isEmpty ? "未检测到 global IPv6" : snapshot.local.ipv6)
            localRow("DNS", value: snapshot.local.dnsServers.isEmpty ? "查不到（resolver #1 未提供 nameserver）" : snapshot.local.dnsServers.joined(separator: ", "))
            if !snapshot.local.wifiName.isEmpty { localRow("Wi-Fi", value: snapshot.local.wifiName) }
            if !snapshot.local.tailscaleIP.isEmpty { localRow("Tailscale", value: snapshot.local.tailscaleIP) }
            if let down = snapshot.local.downloadBPS, let up = snapshot.local.uploadBPS {
                localRow("实时速率", value: "↓ \(formatRate(down))  ↑ \(formatRate(up))")
            } else { localRow("实时速率", value: "查不到（采样不足或接口计数器不可用）") }
        }
    }

    private func localRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 9.5, weight: .medium)).frame(width: 52, alignment: .leading)
            Text(value).font(.system(size: 9)).foregroundColor(.secondary).lineLimit(2).help(value)
        }
    }

    private var leakSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text("IPv6").font(.system(size: 9.5, weight: .medium)).frame(width: 52, alignment: .leading)
                Text(snapshot.leak.ipv6Message + (snapshot.leak.ipv6Country.isEmpty ? "" : " · \(snapshot.leak.ipv6Country)"))
                    .font(.system(size: 9)).foregroundColor(snapshot.leak.ipv6Blocked == false ? .orange : .secondary).lineLimit(2)
            }
            HStack(spacing: 5) {
                Text("DNS").font(.system(size: 9.5, weight: .medium)).frame(width: 52, alignment: .leading)
                Text(snapshot.leak.dnsVerdict.rawValue).font(.system(size: 9)).foregroundColor(snapshot.leak.dnsVerdict == .domesticWarning ? .orange : .secondary)
            }
        }
    }

    private func formatRate(_ bytes: Double) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB/s", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.1f KB/s", bytes / 1_000) }
        return String(format: "%.0f B/s", bytes)
    }
}
