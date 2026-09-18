# VibeGauge 🧠

<p align="center">
  <img src="Resources/AppIcon_1024.png" width="100" height="100" alt="VibeGauge Icon" />
</p>

<h3 align="center">The Native macOS Menu Bar Dashboard for Vibe Coders</h3>

<p align="center">
  <b>Reap orphaned MCP zombie processes · Monitor AI quotas & 5h/weekly reset countdowns · Track Token costs & Prompt Cache hit rates in real time.</b>
</p>

<p align="center">
  <a href="https://github.com/MaxHaiCom/vibe-gauge/releases"><img src="https://img.shields.io/github/v/release/MaxHaiCom/vibe-gauge?style=flat-square&color=blue" alt="Release"></a>
  <img src="https://img.shields.io/badge/Platform-macOS%2014%2B-lightgrey?style=flat-square&logo=apple" alt="macOS 14+">
  <img src="https://img.shields.io/badge/Language-Swift%20%2F%20SwiftUI-orange?style=flat-square&logo=swift" alt="Swift Native">
  <img src="https://img.shields.io/badge/Dependencies-Zero%20(Pure%20Native)-success?style=flat-square" alt="Zero Dependencies">
  <img src="https://img.shields.io/badge/Privacy-100%25%20Local-blueviolet?style=flat-square" alt="100% Local">
  <a href="./LICENSE"><img src="https://img.shields.io/badge/License-MIT-green?style=flat-square" alt="License"></a>
</p>

<p align="center">
  <b>🇺🇸 English</b> •
  <a href="README_zh.md">🇨🇳 简体中文</a>
</p>

---

<p align="center">
  <img src="assets/dashboard_subscription.png" width="48%" alt="Subscription & Quota Dashboard" />
  &nbsp;
  <img src="assets/dashboard_system.png" width="48%" alt="System & MCP Process Cleaner" />
</p>

---

## 💡 Why VibeGauge?

When using autonomous coding agents like **Claude Code**, **OpenAI Codex**, **Google Antigravity (agy)**, or **Grok CLI**, developers encounter three recurring frustrations:

1. **🧟‍♂️ Memory Leaks from Orphaned MCP Servers**:
   Every time an agent spins up or aborts, headless `node` or `python` Model Context Protocol (MCP) server processes are left behind (`PPID == 1`). Over days of coding, dozens or hundreds of these zombie processes quietly hoard **5 GB to 10 GB of RAM**, triggering heavy swap and system thermal throttling.
2. **⏳ Quota Blind Spots & "Reset Anxiety"**:
   Each vendor uses a different quota model — Claude's dynamic 5-hour rolling window and 7-day limits, Codex's weekly quotas, Gemini's credit pools. Wondering if your quota has reset or when you can code again usually requires hitting rate limits in the terminal or opening vendor dashboards.
3. **📊 Token Costs & Prompt Cache Black Hole**:
   How many tokens did you burn today? Is Prompt Caching actually hitting 95%+ to save your budget? How much thinking/reasoning token overhead was generated?

**VibeGauge** is built entirely with native **Swift + AppKit + SwiftUI**. It is lightweight (~15MB RAM), has **zero third-party dependencies, zero cloud uploads, and performs 100% local, read-only inspection**.

---

## ✨ Features

- 🧹 **One-Click Orphaned MCP Reaper**:
  - Automatically identifies headless MCP servers (`PPID == 1`, no listening ports, not on system whitelist, matches MCP signatures).
  - Multi-tier safety guards prevent accidental kills of legitimate dev tasks.
  - One-click clearing of `~/.npm/_npx` cache bloat.
  - Optional silent background sweep every 30 minutes.
- ⏱️ **Unified AI Quota & Reset Timers**:
  - **Claude**: Captures subscription tier (Max 5x / Max 20x / Pro / Team), 5-hour percentage, 7-day quota, and exact countdown to reset.
  - **Codex**: Detects primary `codex` bucket usage, identifies `usage_limit_exceeded` exact unlock timestamps, and supports optional passwordless SSH synchronization from remote dev machines.
  - **Gemini / Antigravity**: Tracks official and 3rd-party quota pools with respective reset dates.
  - **Grok**: Reads weekly credit usage and billing cycle reset boundaries.
  - **Local Model Probing**: Detects running Ollama / LM Studio instances and active models.
- 📈 **Today's Token Analytics & Prompt Cache ROI**:
  - Aggregated daily stats: hundreds of millions in context tokens, output tokens, and thinking/reasoning tokens.
  - Real-time Prompt Cache hit rate calculations (e.g. 97.4% hit rate).
  - Live inspector capturing the latest 3 interaction rounds (model name, latency, cache hit %, tokens).
- 🔌 **Built-in Transparent API Key Proxy (Optional)**:
  - For direct API calls (e.g. routing Claude Code or scripts to GLM, DeepSeek, Kimi, MiniMax, OpenRouter).
  - Runs a local proxy daemon on `127.0.0.1:18790` with zero configuration needed.
  - Fetches plan tiers & remaining balances automatically while keeping keys strictly in memory.
- 🖥️ **macOS Native Craftsmanship**:
  - Pure Swift native app — starts instantly and sips minimal system resources.
  - Menu bar icon shows live available memory percentage.
  - Adaptive panel height with **two-finger trackpad swipe** to switch tabs smoothly.

---

## 🚀 Quick Start

### Method 1: Download Pre-built Binary (Recommended)

1. Download the latest `VibeGauge.zip` from [GitHub Releases](https://github.com/MaxHaiCom/vibe-gauge/releases).
2. Unzip and drag `VibeGauge.app` into your `/Applications` folder.
3. Launch it. The icon will appear in your top menu bar.

> **Tip**: On first launch, if prompted by macOS Gatekeeper, click "Open Anyway" in `System Settings → Privacy & Security`. If you use menu-bar management utilities like Bartender or Ice, make sure VibeGauge isn't hidden in a collapsed drawer.

---

### Method 2: Build from Source in 3 Seconds (Zero Dependencies)

No heavy Xcode installation required — only macOS standard command line tools (`swiftc`):

```bash
# 1. Clone the repository
git clone https://github.com/MaxHaiCom/vibe-gauge.git
cd vibe-gauge

# 2. Build and bundle
./build.sh

# 3. Launch
open VibeGauge.app
```

#### Headless & CLI Flags

```bash
# Verify parsing logic and output a single terminal snapshot (no UI launched)
./VibeGauge.app/Contents/MacOS/VibeGauge --selftest

# Install / Uninstall the background API accounting proxy daemon
./VibeGauge.app/Contents/MacOS/VibeGauge --install-proxy
./VibeGauge.app/Contents/MacOS/VibeGauge --uninstall-proxy
```

---

## 🔍 Data Sources & Freshness

All subscription tiers, quotas, and token metrics are read strictly from local session logs or vendor cache files:

| Provider | Plan Detection | Quotas & Reset Timestamps | Update Frequency |
|:---|:---|:---|:---|
| **Claude** | `~/.claude.json`<br>(e.g. `max_5x`, `max_20x`, `pro`) | `~/.claude/claude-usage.json`<br>(Statusline-intercepted 5h / 7d rates & reset points) | Automatically updates on every dialogue round |
| **Codex** | `~/.codex/auth.json`<br>(JWT `chatgpt_plan_type`) | Session jsonl `rate_limits`<br>(Extracts exact unlock time from `task_complete` errors) | Updates only when requests are actively sent |
| **Gemini** | Local auth token verification | `~/.cache/agy-hud/quota_cache.json`<br>(Split by primary & 3rd-party model pools) | Refreshed by background helper while agy runs |
| **Grok** | `~/.grok/settings_cache.json` | `~/.grok/logs/unified.jsonl`<br>(Latest billing credits config & period end) | Periodically flushed by Grok CLI |
| **Ollama** | Local socket & process probe | Non-quota based (monitors active on-device models) | Instant live status |

> 📌 *Note*: Footnotes such as "Recorded 1h ago" represent the **timestamp when the vendor CLI last refreshed its local log**, not a lag in VibeGauge. VibeGauge's incremental delta-scanner runs in ~100ms when the panel is open.

---

## 🛠️ API Key Accounting Proxy (Optional)

When routing terminal tools or scripts directly to AI provider endpoints, route requests through the local proxy to capture token analytics and credit balances:

1. **Install Proxy Daemon**:
   Click "Install API Proxy" in the API tab, or run:
   ```bash
   ./VibeGauge.app/Contents/MacOS/VibeGauge --install-proxy
   ```
   The proxy listens on `127.0.0.1:18790`.

2. **Zero-Config Routing**:
   Simply prefix your existing endpoint URL:
   ```bash
   # GLM (Zhipu AI)
   export ANTHROPIC_BASE_URL=http://127.0.0.1:18790/https://open.bigmodel.cn/api/anthropic
   
   # DeepSeek
   export OPENAI_BASE_URL=http://127.0.0.1:18790/https://api.deepseek.com/v1
   ```
   *(One-liner to prepend the proxy to all ANTHROPIC_BASE_URL declarations in `~/.zshrc`:)*
   ```bash
   perl -pi.bak -e 's#(ANTHROPIC_BASE_URL=["\x27]?)(?!http://127\.0\.0\.1:18790/)(https?://)#$1http://127.0.0.1:18790/$2#' ~/.zshrc
   ```

3. **Supported Providers**:
   - **GLM Coding Plan**: Automatic tier & 5h/weekly quota tracking
   - **OpenRouter**: Real-time remaining balance & credits calculation
   - **DeepSeek**: Balance endpoint integration
   - **Kimi / MiniMax / Volcano Ark / MiMo**: Streaming token usage accounting

---

## 🛡️ Privacy & Security

- 🔒 **100% Local Execution**: No analytics, no telemetry, no remote servers. Your token counts and usage data never leave your Mac.
- 🔑 **Zero Key Disk Logging**: API keys processed by the local proxy remain strictly in volatile process memory for upstream balance checks. Recorded logs only store an 8-character SHA-256 fingerprint; URL query parameters are stripped.
- ⚙️ **Non-Intrusive**: VibeGauge only reads local logs. It does not tamper with OAuth credentials, proxy your login sessions, or modify vendor configurations.
- 🛡️ **Whitelisted Safe Reaping**: The process cleaner strictly enforces multi-criteria verification before terminating orphaned processes.

---

## 🤝 Contributing

Contributions, feature requests, and bug reports are warmly welcomed!
- Discover a new MCP process pattern? Please open a PR to update the signature filters.
- Vendor changed their log format or introduced a new quota tier? Feel free to submit an issue.

---

## 📄 License

Released under the [MIT License](LICENSE).
