#!/usr/bin/env python3
"""
VibeGauge API 记账代理 —— 纯 stdlib，Python ≥ 3.9（/usr/bin/python3 即可），零依赖。

用法（上游写在路径里，零配置）：
  ANTHROPIC_BASE_URL=http://127.0.0.1:18790/https://open.bigmodel.cn/api/anthropic
  OPENAI_BASE_URL=http://127.0.0.1:18790/https://api.deepseek.com/v1
  → 请求 /https://HOST/任意路径 原样转发到 HOST，响应流式透传，同时从响应里抠 model + usage 记账。

产物（目录 ~/.config/vibegauge/）：
  api-calls.jsonl   每次调用一行：ts/host/provider/model/ctx/cache_read/cache_write/out/think/status/ms
  api-quota.json    各上游的额度/余额（代理从请求头看到 key，只放内存，定时查厂商用量接口）
  GET /_vibegauge/health   运行状态

自测：python3 vibegauge-proxy.py --selftest（本地起假上游，验证流式/非流式解析）
"""
import gzip
import hashlib
import http.client
import json
import os
import re
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, Optional

PORT = int(os.environ.get("VIBEGAUGE_PROXY_PORT", "18790"))
DIR = os.path.expanduser(os.environ.get("VIBEGAUGE_DIR", "~/.config/vibegauge"))
CALLS = os.path.join(DIR, "api-calls.jsonl")
QUOTA = os.path.join(DIR, "api-quota.json")
QUOTA_INTERVAL = int(os.environ.get("VIBEGAUGE_QUOTA_INTERVAL", "300"))
START = time.time()

# host 子串 → 展示名
PROVIDERS = [
    ("api.anthropic.com", "Anthropic"), ("api.openai.com", "OpenAI"), ("api.x.ai", "xAI"),
    ("generativelanguage.googleapis.com", "Gemini"), ("openrouter.ai", "OpenRouter"),
    ("open.bigmodel.cn", "GLM"), ("api.z.ai", "GLM"), ("volces.com", "火山豆包"),
    ("xiaomimimo.com", "MiMo"), ("moonshot.cn", "Kimi"), ("moonshot.ai", "Kimi"),
    ("minimaxi.com", "MiniMax"), ("minimax.io", "MiniMax"), ("deepseek.com", "DeepSeek"),
    ("dashscope.aliyuncs.com", "通义"), ("hunyuan", "混元"), ("siliconflow", "硅基流动"),
    ("localhost", "本地"), ("127.0.0.1", "本地"),
]

# 客户端 → 上游 不该透传的头；Accept-Encoding 去掉是为了拿到明文好解析
DROP_REQ = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "te", "trailer",
            "transfer-encoding", "upgrade", "host", "content-length", "accept-encoding"}
DROP_RESP = {"transfer-encoding", "content-length", "connection", "keep-alive"}

_lock = threading.Lock()
_keys: Dict[str, Dict[str, str]] = {}      # host → {header: value}，只在内存
_stats = {"calls": 0, "parsed": 0, "errors": 0}
_hosts_seen: Dict[str, float] = {}


# 额度类响应头（Anthropic 用 anthropic-ratelimit-*，OpenAI 用 x-ratelimit-*）。
# 被动抓：厂商愿意在真实调用里给的额度，我们顺手记下来，绝不为了查额度去多发请求。
def quota_headers(resp) -> Dict[str, str]:
    out = {}
    for k, v in resp.getheaders():
        kl = k.lower()
        if "ratelimit" in kl or "rate-limit" in kl or "quota" in kl:
            out[kl] = v[:80]
    return out


def provider_of(host: str, path: str = "") -> str:
    # 火山方舟 Coding Plan 与按量付费是两个 Base URL：/api/coding/* 才吃套餐额度，
    # /api/v3/* 是后付费。分成两张卡，免得把两种账混在一起。
    if "volces.com" in host.lower():
        return "火山方舟 Coding" if path.startswith("/api/coding") else "火山豆包(按量)"
    h = host.lower()
    for sub, name in PROVIDERS:
        if sub in h:
            return name
    return h.split(":")[0]


def ensure_dir() -> None:
    os.makedirs(DIR, mode=0o700, exist_ok=True)
    os.chmod(DIR, 0o700)


def private_opener(path, flags):
    fd = os.open(path, flags, 0o600)
    try:
        os.fchmod(fd, 0o600)  # 旧文件也可能由宽松 umask 创建，写入前一起收紧
        return fd
    except Exception:
        os.close(fd)
        raise


def append_call(rec: Dict[str, Any]) -> None:
    ensure_dir()
    line = json.dumps(rec, ensure_ascii=False)
    with _lock:
        with open(CALLS, "a", encoding="utf-8", opener=private_opener) as f:
            f.write(line + "\n")


def key_fingerprint(v: str) -> str:
    return hashlib.sha256(v.encode()).hexdigest()[:8]


def redact_path(path: str) -> str:
    """记账只留路径，抹掉 query string —— Gemini 等把 API key 放在 ?key=... 里，写进文件就是泄露"""
    head = path.split("?", 1)[0]
    return head[:120] + ("?…" if "?" in path else "")


def redact_text(s: str) -> str:
    # 异常会夹带 URL、认证头或上游回显；必须先脱敏再截断，免得只截掉凭据的识别部分。
    s = re.sub(r"\?[^\s\"']*", "?…", s)
    s = re.sub(r"(\bBearer\s+|\b(?:key|token)\s*=\s*[\"']?)([^\s\"'&,;]+)",
               lambda m: m[1] + m[2][:4] + "…", s, flags=re.IGNORECASE)
    s = re.sub(r"(?<![A-Za-z0-9_-])(?:sk-(?:ant-|or-)?|ark-|AIza)[A-Za-z0-9_./+=-]+…?",
               lambda m: m[0][:4] + "…", s)
    return re.sub(r"(?<![A-Za-z0-9_+/-])[A-Za-z0-9_+/-]{32,}={0,2}",
                  lambda m: m[0][:4] + "…", s)


def log_exception(exc_type, exc, tb) -> None:
    print(redact_text("".join(traceback.format_exception(exc_type, exc, tb))), file=sys.stderr, end="", flush=True)


def host_matches(host: str, domain: str) -> bool:
    h = host.lower().split(":", 1)[0]
    return h == domain or h.endswith("." + domain)


def capture_key(host: str, headers) -> Optional[str]:
    found = {}
    for name in ("x-api-key", "authorization", "x-goog-api-key"):
        v = headers.get(name)
        if v:
            found[name] = v
    if not found:
        return None
    with _lock:
        _keys[host] = found
        _hosts_seen[host] = time.time()
    v = next(iter(found.values()))
    return key_fingerprint(v)


# ---------------------------------------------------------------- usage 解析

def _set(u: Dict[str, Any], k: str, v: Any) -> None:
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        u[k] = int(v)
        u["parsed"] = True


def apply_anthropic_usage(u: Dict[str, Any], us: Dict[str, Any]) -> None:
    _set(u, "_in", us.get("input_tokens"))
    _set(u, "cache_read", us.get("cache_read_input_tokens"))
    _set(u, "cache_write", us.get("cache_creation_input_tokens"))
    _set(u, "out", us.get("output_tokens"))
    u["ctx"] = u.get("_in", 0) + u.get("cache_read", 0) + u.get("cache_write", 0)


def apply_json(u: Dict[str, Any], j: Any) -> None:
    if not isinstance(j, dict):
        return
    t = j.get("type")
    # Anthropic：非流式整包 / 流式 message_start + message_delta
    msg = j.get("message") if t == "message_start" else (j if t == "message" else None)
    if isinstance(msg, dict):
        if isinstance(msg.get("usage"), dict):
            apply_anthropic_usage(u, msg["usage"])
        if msg.get("model"):
            u["model"] = msg["model"]
    if t == "message_delta" and isinstance(j.get("usage"), dict):
        apply_anthropic_usage(u, j["usage"])
    # OpenAI 兼容：usage.prompt_tokens / completion_tokens（流式在最后一个 chunk）
    us = j.get("usage")
    if isinstance(us, dict) and ("prompt_tokens" in us or "completion_tokens" in us):
        _set(u, "ctx", us.get("prompt_tokens"))
        _set(u, "out", us.get("completion_tokens"))
        _set(u, "cache_read", (us.get("prompt_tokens_details") or {}).get("cached_tokens"))
        _set(u, "think", (us.get("completion_tokens_details") or {}).get("reasoning_tokens"))
        if j.get("model"):
            u["model"] = j["model"]
    # Gemini
    um = j.get("usageMetadata")
    if isinstance(um, dict):
        _set(u, "ctx", um.get("promptTokenCount"))
        _set(u, "out", um.get("candidatesTokenCount"))
        _set(u, "cache_read", um.get("cachedContentTokenCount"))
        _set(u, "think", um.get("thoughtsTokenCount"))
        if j.get("modelVersion"):
            u["model"] = j["modelVersion"]
    # Ollama 原生
    if "eval_count" in j or "prompt_eval_count" in j:
        _set(u, "ctx", j.get("prompt_eval_count"))
        _set(u, "out", j.get("eval_count"))
        if j.get("model"):
            u["model"] = j["model"]


def parse_usage(req_model: Optional[str], content_type: str, body: bytes, encoding: str) -> Dict[str, Any]:
    u: Dict[str, Any] = {"model": req_model, "ctx": 0, "cache_read": 0, "cache_write": 0, "out": 0, "think": 0, "parsed": False}
    if encoding and "gzip" in encoding:
        try:
            body = gzip.decompress(body)
        except Exception:
            return u
    text = body.decode("utf-8", "replace")
    stripped = text.lstrip()
    if "text/event-stream" in content_type or stripped.startswith("event:") or stripped.startswith("data:"):
        for line in text.split("\n"):
            if not line.startswith("data:"):
                continue
            payload = line[5:].strip()
            if not payload or payload == "[DONE]":
                continue
            try:
                apply_json(u, json.loads(payload))
            except ValueError:
                continue
    else:
        try:
            apply_json(u, json.loads(text))
        except ValueError:
            pass
    u.pop("_in", None)
    return u


# ---------------------------------------------------------------- 代理

class ProxyServer(ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        # stdlib 默认会把未捕获异常直接打进 stderr（LaunchAgent 的 proxy.log）。
        log_exception(*sys.exc_info())


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "VibeGaugeProxy/1"

    def log_message(self, fmt, *args):  # 安静
        pass

    def parse_request(self):
        if not super().parse_request():
            return False
        port = self.server.server_address[1]
        hosts = self.headers.get_all("Host", [])
        # 只拦浏览器专属的头：Origin、Sec-Fetch-Site、Sec-Fetch-Dest。
        # 不能拦整个 Sec-Fetch-*：Node 自带的 fetch（undici）默认会发 sec-fetch-mode，
        # 拦了就会把 Gemini CLI 这类 Node 工具经代理的请求全部 403（2026-09-19 实测）。
        browser = {"origin", "sec-fetch-site", "sec-fetch-dest"}
        if (any(k.lower() in browser for k in self.headers)
                or len(hosts) != 1 or hosts[0] not in ("127.0.0.1:%d" % port, "localhost:%d" % port)):
            # 拒绝后关连接，未读取的请求体不能被当成下一条请求。
            self.close_connection = True
            self._json(403, {"error": "vibegauge-proxy requires a local CLI request"})
            return False
        return True

    def do_GET(self): self._proxy()
    def do_POST(self): self._proxy()
    def do_PUT(self): self._proxy()
    def do_DELETE(self): self._proxy()
    def do_PATCH(self): self._proxy()
    def do_OPTIONS(self): self._proxy()

    def _json(self, status: int, obj: Dict[str, Any]) -> None:
        data = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self) -> bytes:
        if (self.headers.get("Transfer-Encoding") or "").lower() == "chunked":
            out = bytearray()
            while True:
                size_line = self.rfile.readline().strip()
                size = int(size_line.split(b";")[0] or b"0", 16)
                if size == 0:
                    self.rfile.readline()
                    break
                out += self.rfile.read(size)
                self.rfile.readline()
            return bytes(out)
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _proxy(self) -> None:
        if self.path.startswith("/_vibegauge/health"):
            with _lock:
                return self._json(200, {"ok": True, "port": PORT, "uptime_s": int(time.time() - START),
                                        "calls": _stats["calls"], "parsed": _stats["parsed"], "errors": _stats["errors"],
                                        "hosts": sorted(_hosts_seen.keys()), "dir": DIR})
        m = re.match(r"^/(https?)://([^/]+)(/.*)?$", self.path)
        if not m:
            return self._json(400, {"error": "path must be /https://HOST/...  e.g. ANTHROPIC_BASE_URL=http://127.0.0.1:%d/https://api.anthropic.com" % PORT})
        scheme, hostport, rest = m.group(1), m.group(2), m.group(3) or "/"
        body = self._read_body()
        req_model = None
        stream = False
        if body:
            try:
                rj = json.loads(body)
                if isinstance(rj, dict):
                    req_model = rj.get("model")
                    stream = bool(rj.get("stream"))
            except ValueError:
                pass
        if req_model is None:
            mm = re.search(r"/models/([^:/?]+)", rest)   # Gemini 模型在路径里
            if mm:
                req_model = mm.group(1)
                stream = "stream" in rest.lower()
        hdrs = {k: v for k, v in self.headers.items() if k.lower() not in DROP_REQ}
        hdrs["Host"] = hostport
        hdrs["Accept-Encoding"] = "identity"
        if body:
            hdrs["Content-Length"] = str(len(body))
        key_fp = capture_key(hostport, self.headers)
        record = self.command == "POST"          # GET /models、/auth/key 之类只转发不记账

        t0 = time.time()
        conn_cls = http.client.HTTPSConnection if scheme == "https" else http.client.HTTPConnection
        conn = None
        rec: Dict[str, Any] = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + "Z", "epoch": round(t0, 3),
                               "host": hostport, "provider": provider_of(hostport, rest), "path": redact_path(rest),
                               "model": req_model, "stream": stream, "key": key_fp}
        try:
            conn = conn_cls(hostport, timeout=600)
            conn.request(self.command, rest, body=body, headers=hdrs)
            resp = conn.getresponse()
        except Exception as e:
            if conn is not None:
                conn.close()
            rec.update({"status": 502, "ms": int((time.time() - t0) * 1000), "error": redact_text(str(e))[:200], "parsed": False,
                        "ctx": 0, "cache_read": 0, "cache_write": 0, "out": 0, "think": 0})
            if record:
                with _lock:
                    _stats["calls"] += 1
                    _stats["errors"] += 1
                append_call(rec)
            return self._json(502, {"error": "vibegauge-proxy upstream error: %s" % type(e).__name__})

        clen = resp.getheader("Content-Length")
        chunked = clen is None
        content_type = resp.getheader("Content-Type") or ""
        encoding = resp.getheader("Content-Encoding") or ""
        self.send_response(resp.status, resp.reason)
        for k, v in resp.getheaders():
            if k.lower() in DROP_RESP:
                continue
            self.send_header(k, v)
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        else:
            self.send_header("Content-Length", clen)
        self.send_header("Connection", "keep-alive")
        self.end_headers()

        buf = bytearray()
        client_gone = False
        try:
            while True:
                data = resp.read1(65536)          # 有多少给多少，SSE 不等满块
                if not data:
                    break
                if len(buf) < 8 * 1024 * 1024:
                    buf += data
                try:
                    if chunked:
                        self.wfile.write(b"%x\r\n" % len(data) + data + b"\r\n")
                    else:
                        self.wfile.write(data)
                    self.wfile.flush()
                except (BrokenPipeError, ConnectionResetError, OSError):
                    client_gone = True
                    break
            if chunked and not client_gone:
                self.wfile.write(b"0\r\n\r\n")
                self.wfile.flush()
        finally:
            conn.close()
        if client_gone:
            self.close_connection = True

        u = parse_usage(req_model, content_type, bytes(buf), encoding)
        rec.update({"status": resp.status, "ms": int((time.time() - t0) * 1000), "model": u.get("model") or req_model,
                    "ctx": u.get("ctx", 0), "cache_read": u.get("cache_read", 0), "cache_write": u.get("cache_write", 0),
                    "out": u.get("out", 0), "think": u.get("think", 0), "parsed": bool(u.get("parsed")),
                    "bytes": len(buf)})
        rl = quota_headers(resp)
        if rl:
            rec["rl"] = rl
        if not record:
            return
        with _lock:
            _stats["calls"] += 1
            if rec["parsed"]:
                _stats["parsed"] += 1
            if resp.status >= 400:
                _stats["errors"] += 1
        append_call(rec)


# ---------------------------------------------------------------- 额度 / 余额探针
# 每个探针：(域名, 函数)。只匹配该域名及其子域，避免把中转站的 key 发给官方。
# 只放有公开文档 / 已实测的接口，没有的厂商不猜。

def _get_json(host: str, path: str, headers: Dict[str, str], timeout: int = 15) -> Any:
    conn = http.client.HTTPSConnection(host, timeout=timeout)
    try:
        conn.request("GET", path, headers=dict(headers, **{"Accept": "application/json", "User-Agent": "VibeGauge/1"}))
        r = conn.getresponse()
        raw = r.read()
        if r.status >= 400:
            raise RuntimeError("HTTP %d %s" % (r.status, redact_text(raw.decode("utf-8", "replace"))[:120]))
        return json.loads(raw)
    finally:
        conn.close()


def _bearer(hdrs: Dict[str, str]) -> Dict[str, str]:
    a = hdrs.get("authorization")
    if a:
        return {"Authorization": a}
    k = hdrs.get("x-api-key") or hdrs.get("x-goog-api-key") or ""
    return {"Authorization": "Bearer " + k}


def _ms_to_s(v: Any) -> Optional[float]:
    try:
        f = float(v)
    except (TypeError, ValueError):
        return None
    return f / 1000.0 if f > 1e11 else f


def _iso_to_s(v: Any) -> Optional[float]:
    if not isinstance(v, str):
        return None
    s = re.sub(r"\.\d+", "", v).replace("Z", "+0000")
    s = re.sub(r"([+-]\d\d):(\d\d)$", r"\1\2", s)
    for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%d %H:%M:%S%z"):
        try:
            return time.mktime(time.strptime(s, fmt)) - time.timezone + (0 if "%z" in fmt else 0)
        except ValueError:
            continue
    return None


def probe_glm(hdrs):
    """智谱 GLM Coding Plan：/api/monitor/usage/quota/limit（社区标准接口，2026-09-18 实测存在；
    无套餐时返回 code 500 "当前用户不存在coding plan"）。limits[] 按 nextResetTime 早的当 5h、晚的当周。"""
    host = "open.bigmodel.cn"
    j = _get_json(host, "/api/monitor/usage/quota/limit", _bearer(hdrs))
    if j.get("code") != 200 or not isinstance(j.get("data"), dict):
        return {"kind": "quota", "error": redact_text(str(j.get("msg") or j))[:120]}
    d = j["data"]
    limits = [l for l in (d.get("limits") or []) if isinstance(l, dict) and l.get("percentage") is not None]
    limits.sort(key=lambda l: l.get("nextResetTime") or 0)
    windows: Dict[str, Any] = {}
    if limits:
        windows["5h" if len(limits) > 1 else "weekly"] = {"used_pct": limits[0]["percentage"], "resets_at": _ms_to_s(limits[0].get("nextResetTime"))}
    if len(limits) > 1:
        windows["weekly"] = {"used_pct": limits[-1]["percentage"], "resets_at": _ms_to_s(limits[-1].get("nextResetTime"))}
    level = str(d.get("level") or "")
    return {"kind": "quota", "plan": ("Coding " + level.capitalize()) if level else "Coding Plan", "windows": windows}


def probe_minimax(hdrs):
    """MiniMax Token Plan：/v1/token_plan/remains（社区接口，未实测；按量 key 会 401/403）"""
    j = _get_json("api.minimaxi.com", "/v1/token_plan/remains", _bearer(hdrs))
    d = j.get("data") or {}
    if not d:
        return {"kind": "quota", "error": redact_text(str(j.get("message") or j))[:120]}
    now = time.time()
    windows: Dict[str, Any] = {}
    tot, used = d.get("current_interval_total_count"), d.get("current_interval_usage_count")
    if tot:
        windows["5h"] = {"used_pct": round(100.0 * float(used or 0) / float(tot)), "resets_at": now + float(d.get("remains_time") or 0) / 1000.0}
    wtot, wused = d.get("current_weekly_total_count"), d.get("current_weekly_usage_count")
    if wtot:
        windows["weekly"] = {"used_pct": round(100.0 * float(wused or 0) / float(wtot)), "resets_at": _ms_to_s(d.get("weekly_end_time"))}
    return {"kind": "quota", "plan": "Token Plan", "windows": windows}


def probe_kimi_code(hdrs):
    """Kimi Code 订阅：api.kimi.com/coding/v1/usages（社区接口，未实测）"""
    j = _get_json("api.kimi.com", "/coding/v1/usages", _bearer(hdrs))
    u = j.get("usage") or {}
    if not u:
        return {"kind": "quota", "error": redact_text(str(j))[:120]}
    limit, used = float(u.get("limit") or 0), float(u.get("used") or 0)
    windows: Dict[str, Any] = {}
    if limit > 0:
        windows["5h"] = {"used_pct": round(100.0 * used / limit), "resets_at": _iso_to_s(u.get("resetTime"))}
    return {"kind": "quota", "plan": "Kimi Code", "windows": windows}


def probe_deepseek(hdrs):
    j = _get_json("api.deepseek.com", "/user/balance", _bearer(hdrs))
    infos = j.get("balance_infos") or []
    if not infos:
        return {"kind": "balance", "available": j.get("is_available"), "balance": None}
    b = infos[0]
    return {"kind": "balance", "balance": float(b.get("total_balance", 0)), "currency": b.get("currency", "CNY"),
            "available": j.get("is_available")}


def probe_openrouter(hdrs):
    k = _get_json("openrouter.ai", "/api/v1/auth/key", _bearer(hdrs)).get("data") or {}
    out = {"kind": "balance", "usage": k.get("usage"), "limit": k.get("limit"), "limit_remaining": k.get("limit_remaining"),
           "currency": "USD"}
    try:
        c = _get_json("openrouter.ai", "/api/v1/credits", _bearer(hdrs)).get("data") or {}
        total, used = c.get("total_credits"), c.get("total_usage")
        if total is not None and used is not None:
            out["balance"] = round(float(total) - float(used), 4)
    except Exception as e:  # /credits 需要管理 key，拿不到就只报 usage
        out["credits_error"] = redact_text(str(e))[:120]
    return out


def probe_moonshot(hdrs):
    j = _get_json("api.moonshot.cn", "/v1/users/me/balance", _bearer(hdrs))
    d = j.get("data") or {}
    return {"kind": "balance", "balance": d.get("available_balance"), "cash": d.get("cash_balance"),
            "voucher": d.get("voucher_balance"), "currency": "CNY"}


PROBES = [
    ("open.bigmodel.cn", probe_glm),
    ("api.z.ai", probe_glm),
    ("minimaxi.com", probe_minimax),
    ("api.kimi.com", probe_kimi_code),
    ("deepseek.com", probe_deepseek),
    ("openrouter.ai", probe_openrouter),
    ("moonshot.cn", probe_moonshot),
    # 实测/调研无公开接口：火山方舟 coding、小米 MiMo、xAI（推理 key）—— 卡片只记调用
]


def quota_loop() -> None:
    while True:
        time.sleep(30 if time.time() - START < 60 else QUOTA_INTERVAL)
        with _lock:
            snapshot = dict(_keys)
        if not snapshot:
            continue
        result: Dict[str, Any] = {}
        try:
            if os.path.exists(QUOTA):
                result = json.load(open(QUOTA, encoding="utf-8"))
        except Exception:
            result = {}
        changed = False
        for host, hdrs in snapshot.items():
            for sub, fn in PROBES:
                if not host_matches(host, sub):
                    continue
                entry = {"provider": provider_of(host), "captured_at": time.time()}
                try:
                    entry.update(fn(hdrs))
                except Exception as e:
                    entry["error"] = redact_text(str(e))[:160]
                result[host] = entry
                changed = True
        if changed:
            ensure_dir()
            tmp = QUOTA + ".tmp"
            with open(tmp, "w", encoding="utf-8", opener=private_opener) as f:
                json.dump(result, f, ensure_ascii=False, indent=1)
            os.replace(tmp, QUOTA)


# ---------------------------------------------------------------- 自测

def selftest() -> None:
    import contextlib
    import io
    import socket
    import tempfile
    from unittest.mock import patch
    global DIR, CALLS, QUOTA
    DIR = tempfile.mkdtemp(prefix="vibegauge-selftest-")
    CALLS, QUOTA = os.path.join(DIR, "api-calls.jsonl"), os.path.join(DIR, "api-quota.json")

    class Mock(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"
        def log_message(self, *a): pass
        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
            j = json.loads(body)
            if self.path == "/api/anthropic/v1/messages" and j.get("stream"):
                events = [
                    'event: message_start\ndata: {"type":"message_start","message":{"model":"glm-4.7","usage":{"input_tokens":10,"cache_read_input_tokens":5,"cache_creation_input_tokens":2,"output_tokens":1}}}\n\n',
                    'event: content_block_delta\ndata: {"type":"content_block_delta","delta":{"type":"text_delta","text":"hi"}}\n\n',
                    'event: message_delta\ndata: {"type":"message_delta","usage":{"output_tokens":7}}\n\n',
                ]
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Transfer-Encoding", "chunked")
                self.end_headers()
                for e in events:
                    d = e.encode()
                    self.wfile.write(b"%x\r\n" % len(d) + d + b"\r\n")
                    self.wfile.flush()
                    time.sleep(0.05)
                self.wfile.write(b"0\r\n\r\n")
            else:
                data = json.dumps({"id": "x", "model": "deepseek-chat", "choices": [],
                                   "usage": {"prompt_tokens": 100, "completion_tokens": 20,
                                             "prompt_tokens_details": {"cached_tokens": 60},
                                             "completion_tokens_details": {"reasoning_tokens": 4}}}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                # 限流头：被动记账要能把它们抓下来（各家写法不同，这里用 OpenAI 那种）
                self.send_header("x-ratelimit-limit-requests", "500")
                self.send_header("x-ratelimit-remaining-requests", "125")
                self.send_header("x-ratelimit-reset-requests", "6m0s")
                self.send_header("x-request-id", "should-not-be-captured")
                self.end_headers()
                self.wfile.write(data)

    mock = ThreadingHTTPServer(("127.0.0.1", 0), Mock)
    mport = mock.server_address[1]
    threading.Thread(target=mock.serve_forever, daemon=True).start()
    proxy = ProxyServer(("127.0.0.1", 0), Handler)
    pport = proxy.server_address[1]
    threading.Thread(target=proxy.serve_forever, daemon=True).start()

    c = http.client.HTTPConnection("127.0.0.1", pport, timeout=10)
    c.request("POST", "/http://127.0.0.1:%d/api/anthropic/v1/messages" % mport,
              body=json.dumps({"model": "glm-4.7", "stream": True, "messages": []}),
              headers={"Content-Type": "application/json", "x-api-key": "test-key"})
    r = c.getresponse()
    sse = r.read().decode()
    assert r.status == 200 and "message_delta" in sse, sse
    c.request("POST", "/http://127.0.0.1:%d/v1/chat/completions" % mport,
              body=json.dumps({"model": "deepseek-chat", "messages": []}),
              headers={"Content-Type": "application/json", "Authorization": "Bearer test"})
    r = c.getresponse()
    assert r.status == 200 and json.loads(r.read())["usage"]["prompt_tokens"] == 100
    c.request("GET", "/_vibegauge/health")
    h = json.loads(c.getresponse().read())
    assert h["ok"] and h["calls"] == 2 and h["parsed"] == 2, h
    c.request("GET", "/nonsense")
    r = c.getresponse()
    assert r.status == 400
    r.read()

    # Node fetch 只带 sec-fetch-mode：必须放行，否则 Node 系 CLI 经代理全挂
    # 用不记账的健康检查测放行，免得多出一次调用把后面的计数断言弄坏
    c.request("GET", "/_vibegauge/health", headers={"sec-fetch-mode": "cors"})
    r = c.getresponse()
    assert r.status == 200, "Node fetch 的 sec-fetch-mode 被误拦: %d" % r.status
    r.read()
    c.close()
    for headers in ({"Origin": "https://example.test"}, {"Origin": ""}, {"sEc-FeTcH-SiTe": "cross-site"},
                    {"Sec-Fetch-Dest": "empty"},
                    {"Host": "example.test:%d" % pport}, {"Host": "127.0.0.1:1"}):
        c.request("POST", "/http://127.0.0.1:%d/v1/chat/completions" % mport, body="{}", headers=headers)
        r = c.getresponse()
        assert r.status == 403, headers
        r.read()
        c.close()
    for hosts in ([], ["127.0.0.1:%d" % pport, "example.test:%d" % pport]):
        c.putrequest("GET", "/_vibegauge/health", skip_host=True)
        for host in hosts:
            c.putheader("Host", host)
        c.endheaders()
        r = c.getresponse()
        assert r.status == 403
        r.read()
        c.close()
    c.request("GET", "/_vibegauge/health", headers={"Host": "localhost:%d" % pport})
    r = c.getresponse()
    assert r.status == 200 and json.loads(r.read())["calls"] == 2
    c.close()

    fake_key = "AIzaFAKE" + "x" * 32
    # 原始 socket 才能把控制字符送到代理，http.client 自己会先拦住这条回归用例。
    with socket.create_connection(("127.0.0.1", pport), timeout=10) as sock:
        path = "/http://127.0.0.1:%d/v1/messages?key=%s\x01" % (mport, fake_key)
        sock.sendall(("POST %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" % (path, pport)).encode())
        r = http.client.HTTPResponse(sock)
        r.begin()
        error_body = r.read().decode()
        assert r.status == 502 and json.loads(error_body)["error"] == "vibegauge-proxy upstream error: InvalidURL", error_body
        assert "AIzaFAKE" not in error_body

    assert redact_path("/v1beta/models/gemini-3-pro:generateContent?key=AIzaSECRET") == "/v1beta/models/gemini-3-pro:generateContent?…"
    assert redact_path("/v1/messages") == "/v1/messages"
    assert redact_text("bad '/v1/messages?key=%s' suffix" % fake_key) == "bad '/v1/messages?…' suffix"
    for token in ("sk-FAKEabcdef", "sk-ant-FAKEabcdef", "sk-or-FAKEabcdef", "ark-FAKEabcdef", fake_key,
                  "0123456789abcdef" * 2, "Ab9+/cdE" * 4, "Ab9_-cdE" * 4):
        assert redact_text(token) == token[:4] + "…", token
    for label in ("Bearer ", "key=", "token=", "TOKEN='", "Key=\""):
        assert redact_text(label + "FAKEabcdef") == label + "FAKE…", label
    assert host_matches("deepseek.com", "deepseek.com")
    assert host_matches("API.DeepSeek.com:443", "deepseek.com")
    assert not host_matches("deepseek.com.gateway.example:443", "deepseek.com")
    assert not host_matches("notdeepseek.com", "deepseek.com")
    with patch.object(http.client, "HTTPSConnection") as connection:
        response = connection.return_value.getresponse.return_value
        response.status = 401
        response.read.return_value = ("bad key=" + fake_key).encode()
        try:
            _get_json("example.test", "/quota", {})
            assert False, "上游错误必须抛出异常"
        except RuntimeError as e:
            assert "AIzaFAKE" not in str(e) and "HTTP 401" in str(e)
    with contextlib.redirect_stderr(io.StringIO()) as captured:
        try:
            raise ValueError("bad token=" + fake_key)
        except ValueError:
            proxy.handle_error(None, None)
    assert "ValueError" in captured.getvalue() and "AIzaFAKE" not in captured.getvalue()

    # 既验证新建权限，也验证下次写入会修复旧文件的宽松权限。
    os.chmod(DIR, 0o755)
    os.chmod(CALLS, 0o644)
    append_call({"selftest": True})
    assert os.stat(DIR).st_mode & 0o777 == 0o700
    assert os.stat(CALLS).st_mode & 0o777 == 0o600
    for path in (QUOTA + ".tmp", os.path.join(DIR, "proxy.log")):
        with open(path, "w", encoding="utf-8", opener=private_opener) as f:
            f.write("{}")
        assert os.stat(path).st_mode & 0o777 == 0o600
        os.chmod(path, 0o644)
        with open(path, "a", encoding="utf-8", opener=private_opener):
            pass
        assert os.stat(path).st_mode & 0o777 == 0o600
    with open(QUOTA, "w", encoding="utf-8") as f:
        f.write("{}")
    os.chmod(QUOTA, 0o644)
    os.replace(QUOTA + ".tmp", QUOTA)
    assert os.stat(QUOTA).st_mode & 0o777 == 0o600

    recs = [json.loads(l) for l in open(CALLS, encoding="utf-8")]
    a, o = recs[0], recs[1]
    assert len(recs) == 4 and recs[2]["status"] == 502, recs
    assert "AIzaFAKE" not in recs[2]["error"] and "?…" in recs[2]["error"], recs[2]
    assert a["provider"] == "本地" and a["model"] == "glm-4.7" and a["stream"] is True
    assert a["ctx"] == 17 and a["cache_read"] == 5 and a["cache_write"] == 2 and a["out"] == 7 and a["parsed"], a
    assert o["ctx"] == 100 and o["cache_read"] == 60 and o["out"] == 20 and o["think"] == 4 and o["parsed"], o
    assert o.get("rl") == {"x-ratelimit-limit-requests": "500", "x-ratelimit-remaining-requests": "125",
                           "x-ratelimit-reset-requests": "6m0s"}, o.get("rl")     # 只收限流头，别的头不收
    assert "rl" not in a, "上游没给限流头就不该有这个字段"
    assert _keys.get("127.0.0.1:%d" % mport, {}).get("authorization") == "Bearer test"   # 同一 host 后到的 key 覆盖
    print("selftest OK: 流式/非流式 + 限流头 + 异常脱敏 + 来源/Host 校验 + 探针域名 + 文件权限, 记录", CALLS)
    # 先停服务线程再退出：否则守护线程在解释器收尾时还握着 stderr 锁，
    # 会报 "Fatal Python error: _enter_buffered_busy"、退出码 134，CI 就红了（断言其实全过）
    proxy.shutdown(); mock.shutdown()
    proxy.server_close(); mock.server_close()
    sys.stdout.flush(); sys.stderr.flush()


def main() -> None:
    sys.excepthook = log_exception
    threading.excepthook = lambda args: log_exception(args.exc_type, args.exc_value, args.exc_traceback)
    if "--selftest" in sys.argv:
        selftest()
        return
    ensure_dir()
    with open(os.path.join(DIR, "proxy.log"), "a", encoding="utf-8", opener=private_opener):
        pass
    threading.Thread(target=quota_loop, daemon=True).start()
    srv = ProxyServer(("127.0.0.1", PORT), Handler)
    srv.daemon_threads = True
    print("vibegauge-proxy listening on 127.0.0.1:%d, dir=%s" % (PORT, DIR), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
