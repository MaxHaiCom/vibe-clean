import Foundation

/// API 记账代理的安装 / 状态。代理本体是 Resources/vibeclean-proxy.py（纯 stdlib Python），
/// 安装时拷到 ~/.config/vibeclean/ 并注册 LaunchAgent（登录自启、崩溃自拉），不依赖 VibeClean 存活。
final class ProxyManager {
    static let shared = ProxyManager()

    let port = 18790
    let label = "com.haifeng.vibeclean.proxy"
    private let home = FileManager.default.homeDirectoryForCurrentUser.path

    var dir: String { "\(home)/.config/vibeclean" }
    var scriptPath: String { "\(dir)/vibeclean-proxy.py" }
    var callsPath: String { "\(dir)/api-calls.jsonl" }
    var quotaPath: String { "\(dir)/api-quota.json" }
    var logPath: String { "\(dir)/proxy.log" }
    var plistPath: String { "\(home)/Library/LaunchAgents/\(label).plist" }
    var prefix: String { "http://127.0.0.1:\(port)/" }

    var isInstalled: Bool { FileManager.default.fileExists(atPath: plistPath) }

    struct Health {
        var calls: Int
        var parsed: Int
        var errors: Int
        var uptime: Int
        var hosts: [String]
    }

    /// 同步探活，超时 0.4s；nil = 没在跑
    func health() -> Health? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/_vibeclean/health") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 0.4
        var result: Health? = nil
        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, _, _ in
            if let data = data, let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any], j["ok"] as? Bool == true {
                result = Health(calls: j["calls"] as? Int ?? 0, parsed: j["parsed"] as? Int ?? 0, errors: j["errors"] as? Int ?? 0,
                                uptime: j["uptime_s"] as? Int ?? 0, hosts: j["hosts"] as? [String] ?? [])
            }
            sema.signal()
        }.resume()
        _ = sema.wait(timeout: .now() + 0.5)
        return result
    }

    private var bundledScript: String? { Bundle.main.path(forResource: "vibeclean-proxy", ofType: "py") }

    /// 把 App 包里的脚本拷到 ~/.config/vibeclean/（内容不同才覆盖），返回是否有更新
    @discardableResult
    private func syncScript() throws -> Bool {
        guard let src = bundledScript else {
            throw NSError(domain: "VibeClean", code: 1, userInfo: [NSLocalizedDescriptionKey: "App 包里没有 vibeclean-proxy.py（build.sh 没拷？）"])
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let new = try Data(contentsOf: URL(fileURLWithPath: src))
        if let old = try? Data(contentsOf: URL(fileURLWithPath: scriptPath)), old == new { return false }
        try new.write(to: URL(fileURLWithPath: scriptPath))
        return true
    }

    func install() throws {
        try syncScript()
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>\(label)</string>
            <key>ProgramArguments</key>
            <array><string>/usr/bin/python3</string><string>\(scriptPath)</string></array>
            <key>EnvironmentVariables</key>
            <dict><key>VIBECLEAN_PROXY_PORT</key><string>\(port)</string><key>PYTHONUNBUFFERED</key><string>1</string></dict>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardOutPath</key><string>\(logPath)</string>
            <key>StandardErrorPath</key><string>\(logPath)</string>
        </dict>
        </plist>
        """
        try FileManager.default.createDirectory(atPath: "\(home)/Library/LaunchAgents", withIntermediateDirectories: true)
        try plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])          // 已有就先卸，忽略失败
        let rc = launchctl(["bootstrap", "gui/\(getuid())", plistPath])
        if rc != 0 {
            throw NSError(domain: "VibeClean", code: Int(rc), userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap 失败 rc=\(rc)，看 \(logPath)"])
        }
    }

    func uninstall() {
        _ = launchctl(["bootout", "gui/\(getuid())/\(label)"])
        try? FileManager.default.removeItem(atPath: plistPath)
    }

    /// App 启动时：已安装且包里脚本更新了 → 覆盖并重启代理
    func syncIfInstalled() {
        guard isInstalled else { return }
        if (try? syncScript()) == true {
            _ = launchctl(["kickstart", "-k", "gui/\(getuid())/\(label)"])
        }
    }

    private func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
            return p.terminationStatus
        } catch {
            return -1
        }
    }
}
