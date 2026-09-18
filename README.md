# VibeClean 🧠

专为 **Vibe Coding** 打造的极简 macOS 菜单栏原生监控与清理工具（纯 Swift + AppKit + SwiftUI，无第三方依赖）。

> 解决频繁使用 Claude Code、Codex、Antigravity（agy）、Grok CLI 时，死掉的 MCP 进程越积越多把内存吃光的问题；顺带把各家订阅档位、额度窗口、Token 消耗、API Key 调用放到同一块面板上。

**English**: A tiny native macOS menu-bar monitor for AI coding workflows. It reaps orphaned MCP processes that leak memory, and shows — in one panel — subscription tiers with 5h/weekly quota windows for Claude Code, Codex, Gemini (Antigravity) and Grok, today's token usage with prompt-cache hit rate, and per-provider API-key usage captured by a built-in local accounting proxy (Chinese providers and coding plans included: GLM, Doubao, MiMo, Kimi, MiniMax, DeepSeek, OpenRouter…). Everything is read from local CLI session logs or the vendors' own usage endpoints; nothing is uploaded anywhere. macOS 14+, no dependencies beyond the system Swift toolchain and `/usr/bin/python3`.

---

## 面板内容

菜单 = 一块面板 + 「退出」。面板顶部三个 Tab（记住上次选择），高度随当前 Tab 内容自适应（超过屏幕可用高度才滚动），右上角 ⟳ 重新扫描：

1. **订阅**：每个平台一张卡片 —— 在线状态 · 订阅档位 · 活跃会话数 · 5H/周额度进度条 · 重置倒计时 · 数据新鲜度；今日（本地日历日）调用次数、上下文总量、Prompt Cache 命中率、输出/思考 Token；最近 3 轮交互实时滚动。一个套餐带多个模型额度时，卡内只列用得最紧的 3 个，其余折叠。
2. **API**：经记账代理的每个上游一张卡（见下文"API Key 调用记账"）；底部装/卸代理、复制前缀。
3. **系统**：顶部清理按钮（一键回收断链孤儿 MCP：`PPID == 1` + 无监听端口 + 非白名单 + node/python 运行器 + MCP 签名；清空 `~/.npm/_npx`）；内存可用率（`memory_pressure`）、压缩池、Swap、磁盘剩余、CPU 负载、发热、活跃 MCP 进程与内存、NPX 缓存、断链孤儿明细；设置开关：每 30 分钟静默巡检、登录自启。

菜单栏图标：芯片框内嵌内存可用百分比，随内存变化实时刷新。

---

## 数据来源（档位与额度全部只读本地文件，查不到就标"无数据"，不猜）

| 平台 | 档位 | 额度 | 新鲜度 |
|------|------|------|--------|
| Claude | `~/.claude.json` → `oauthAccount.organizationRateLimitTier`（`default_claude_max_5x` → Max 5x / `max_20x` → Max 20x / pro / team） | `~/.claude/claude-usage.json`（statusline 截获 Claude Code 下发的整个 `rate_limits`：`five_hour` / `seven_day` 的 `used_percentage` + `resets_at`）。Claude Code 目前**不下发按模型的窗口**（无 Fable/Opus 独立桶）；若将来出现如 `seven_day_fable` 键，自动当副池显示 | `_captured_at` |
| Codex | `~/.codex/auth.json` id_token JWT → `chatgpt_plan_type`（`prolite` → Pro Lite / plus / pro / team） | 会话 jsonl 的 `rate_limits` **按 `limit_id` 分桶**：只显示主桶 `codex`（新版 CLI 另报的 `codex_bengalfox`/Spark 等桶解析但不显示，免得被误当主桶）→ 取采集时间最新的一条。来源 = 本机 `~/.codex/sessions`（近 7 天目录、48h 内改过）**+ 可选远程主机 ssh 拉取**（默认关闭；`defaults write com.haifeng.vibeclean codexRemoteHost <ssh-host>` 开启，60s 一次，需免密 ssh），两边按采集时间合并 | 该行 `timestamp` |
| Gemini（Antigravity） | 本地没有套餐字段；新版 agy 连 token 文件也不落盘 → 有 token 文件显示鉴权方式，否则能拉到额度即 "已登录" | `~/.cache/agy-hud/quota_cache.json`（`gemini` 池 + `3p` 三方池，`remaining_fraction` + `reset_at`） | 每个池各自的 `recorded_at`，脚注分别标 |
| Grok | `~/.grok/settings_cache.json` → `subscription_tier_display` 原值 | `~/.grok/logs/unified.jsonl` 最后一条 `billing: fetched credits config`（`creditUsagePercent` = 周额度已用 %，`currentPeriod.end` = 重置点；grok 跑着时每几分钟记一次） | 该行 `ts` |
| Ollama / LM Studio / Cursor | 只探测进程在线 | 无 | — |

各家额度的**更新时机**（都不是本工具能控制的，没有不花额度的查询接口）：

| 平台 | 什么时候写出新的额度数字 |
|------|------------------------|
| Claude | 每轮对话（Claude Code 状态栏每次渲染都带服务端下发的 `rate_limits`）→ 最快 |
| Codex | **只在真的发出请求时**（会话 jsonl 的 `token_count` 事件）。开着 TUI 不产生任何额度记录。额度打满后请求被拒，此时 `rate_limits` 的百分比全是 `null`，真信号在 `task_complete` 的 `usage_limit_exceeded` 错误里 → 本工具据此显示 100% 耗尽，重置时刻从错误文案（`try again at Sep 19th, 2026 5:03 PM`）解析 |
| Gemini | agy 跑起来时由 agy-hud 刷 `quota_cache.json` |
| Grok | grok 自己在跑时不定期拉一次 billing 配置，不必产生对话 |

所以卡片脚注的"记录于 Nh前"是**数据源的年龄**，不是本工具没刷新。

额度规则：
- 已过 `resets_at` 的缓存值视为 **0%**（"已重置"），不再显示过期高值。
- 采集时间超过 5 分钟 → 卡片脚注橙色标出"记录于 Nh前"（主池、副池分别标）。Claude 额度只在 Claude Code 状态栏渲染时更新，Codex 额度只在某台机器的 Codex 会话产生 token 事件时更新，这两处"旧"是数据源本身的限制。

Token 统计规则：
- Claude Code 的 jsonl 里同一个 `requestId` 会写多行（每个 content block 一行），`usage` 相同 → **按 requestId 去重**后才算一次调用。
- "今日" 按每条记录的 `timestamp` 归本地日历日，不按文件 mtime。
- jsonl 为 append-only：只增量解析新增字节（记 offset），菜单打开时每秒刷新一次只需约 100ms。

---

## API Key 调用记账（国内外 API / coding plan）

CLI 会话日志只覆盖 Claude Code / Codex / agy / grok 自己的调用。任何程序拿 **API key** 直接打 API（Claude Code 接国内模型、脚本、Hermes…）要看到模型 / 上下文 / token，走内置的**记账代理**：

- 代理 = `Resources/vibeclean-proxy.py`（纯 stdlib Python，`/usr/bin/python3` 即可，零依赖）。菜单「安装 API 记账代理」→ 拷到 `~/.config/vibeclean/`，注册 LaunchAgent `com.haifeng.vibeclean.proxy`（登录自启、崩溃自拉，不依赖 VibeClean 存活），监听 `127.0.0.1:18790`。命令行等价：`VibeClean --install-proxy` / `--uninstall-proxy`。
- **零配置**：上游写在路径里。别名里的 BASE_URL 前面加代理前缀即可：
  ```bash
  ANTHROPIC_BASE_URL=http://127.0.0.1:18790/https://open.bigmodel.cn/api/anthropic   # GLM
  OPENAI_BASE_URL=http://127.0.0.1:18790/https://api.deepseek.com/v1                 # DeepSeek
  # 一键给 ~/.zshrc 里所有 ANTHROPIC_BASE_URL 加前缀（幂等，备份 .bak）：
  perl -pi.bak -e 's#(ANTHROPIC_BASE_URL=["\x27]?)(?!http://127\.0\.0\.1:18790/)(https?://)#$1http://127.0.0.1:18790/$2#' ~/.zshrc
  ```
  订阅版 Claude Code（`cc`，无 BASE_URL）不要走它——它的用量已在会话日志里，而且它用 HTTPS_PROXY 出网，代理不转发这个环境变量。
- **记账**：每次 POST 一行 `~/.config/vibeclean/api-calls.jsonl`（`ts/host/provider/model/ctx/cache_read/cache_write/out/think/status/ms`）。**不落 key**：只记 key 的 SHA-256 前 8 位指纹用于区分多个 key，请求路径的 query string 一律抹掉（Gemini 那种 `?key=` 在 URL 里的写法不会进文件）。流式也解析：Anthropic `message_start`+`message_delta`、OpenAI 最后一个带 `usage` 的 chunk、Gemini `usageMetadata`、Ollama 原生。响应原样流式透传，客户端无感。
- **额度 / 余额**：代理从请求头看到各上游的 key（只在内存，不落盘），每 5 分钟查一次厂商用量接口，写 `api-quota.json`：

  | 厂商 | 接口 | 状态 |
  |------|------|------|
  | GLM Coding Plan | `GET open.bigmodel.cn/api/monitor/usage/quota/limit`（5h + 周，`level` 档位） | 实测存在；无套餐时返回"当前用户不存在coding plan" |
  | OpenRouter | `/api/v1/auth/key` + `/api/v1/credits`（余额 = credits − usage） | 实测通 |
  | DeepSeek | `/user/balance` | 官方文档 |
  | Kimi 按量 | `api.moonshot.cn/v1/users/me/balance` | 官方文档 |
  | Kimi Code 订阅 | `api.kimi.com/coding/v1/usages` | 社区接口，未实测 |
  | MiniMax Token Plan | `api.minimaxi.com/v1/token_plan/remains` | 社区接口，未实测 |
  | 火山方舟 coding / 小米 MiMo / xAI 推理 key | 无公开接口（实测 404 / 需云账号 AK/SK 或管理 key） | 只记调用 |

- 面板「API Key 调用」：每个上游一张卡，档位显示套餐（如 `Coding Lite`）或 `API Key`，5H/W 额度条或余额，今日调用次数 + 模型 + 上下文/输出/缓存命中。
- 自测：`/usr/bin/python3 Resources/vibeclean-proxy.py --selftest`（本地假上游，验证流式/非流式解析）。

## 编译与启动

```bash
git clone https://github.com/MaxHaiCom/vibe-clean.git
cd vibe-clean
./build.sh                     # swiftc 直接编译 + 打包 + ad-hoc 签名，无需 Xcode 工程
open VibeClean.app

# 不起 UI，校验纯函数并打印一次完整扫描（档位/额度/Token/API 代理）
./VibeClean.app/Contents/MacOS/VibeClean --selftest
./VibeClean.app/Contents/MacOS/VibeClean --install-proxy     # 装/起 API 记账代理（LaunchAgent）
```

> 若安装了 Bartender 等菜单栏管理工具，新图标可能默认被收进折叠区。

---

## 许可

MIT，见 [LICENSE](LICENSE)。

### 安全边界

- 一切额度与用量数据都来自本机文件或厂商自家的用量接口，不上传任何地方。
- 记账代理只监听 `127.0.0.1`，把请求原样转发到你在 URL 里指定的上游；它看到的 API key 只保留在进程内存里，用于定时查询该上游的额度，**不落盘、不外发**。记账文件里只有 key 的 8 位指纹，路径的 query string 已抹除。
- 代理会转发到任意由调用方指定的上游主机，所以它是个本机开发工具：别把端口暴露到局域网，也别在多用户机器上跑。
- 本工具只读取 CLI 自己写在本机的会话日志与缓存，不碰任何 OAuth token、不代替你登录、不修改任何 CLI 的凭据文件。
