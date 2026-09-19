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
    os.makedirs(DIR, exist_ok=True)


def append_call(rec: Dict[str, Any]) -> None:
    ensure_dir()
    line = json.dumps(rec, ensure_ascii=False)
    with _lock:
        with open(CALLS, "a", encoding="utf-8") as f:
            f.write(line + "\n")


def key_fingerprint(v: str) -> str:
    return hashlib.sha256(v.encode()).hexdigest()[:8]


def redact_path(path: str) -> str:
    """记账只留路径，抹掉 query string —— Gemini 等把 API key 放在 ?key=... 里，写进文件就是泄露"""
    head = path.split("?", 1)[0]
    return head[:120] + ("?…" if "?" in path else "")


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

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "VibeGaugeProxy/1"

    def log_message(self, fmt, *args):  # 安静
        pass

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
        conn = conn_cls(hostport, timeout=600)
        rec: Dict[str, Any] = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime()) + "Z", "epoch": round(t0, 3),
                               "host": hostport, "provider": provider_of(hostport, rest), "path": redact_path(rest),
                               "model": req_model, "stream": stream, "key": key_fp}
        try:
            conn.request(self.command, rest, body=body, headers=hdrs)
            resp = conn.getresponse()
        except Exception as e:
            conn.close()
            rec.update({"status": 502, "ms": int((time.time() - t0) * 1000), "error": str(e)[:200], "parsed": False,
                        "ctx": 0, "cache_read": 0, "cache_write": 0, "out": 0, "think": 0})
            if record:
                with _lock:
                    _stats["calls"] += 1
                    _stats["errors"] += 1
                append_call(rec)
            return self._json(502, {"error": "vibegauge-proxy upstream error: %s" % e})

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
# 每个探针：(host 子串, 函数)。函数拿到该 host 的请求头 dict，返回 dict；查不到就 {"error": ...}。
# 只放有公开文档 / 已实测的接口，没有的厂商不猜。

def _get_json(host: str, path: str, headers: Dict[str, str], timeout: int = 15) -> Any:
    conn = http.client.HTTPSConnection(host, timeout=timeout)
    try:
        conn.request("GET", path, headers=dict(headers, **{"Accept": "application/json", "User-Agent": "VibeGauge/1"}))
        r = conn.getresponse()
        raw = r.read()
        if r.status >= 400:
            raise RuntimeError("HTTP %d %s" % (r.status, raw[:120].decode("utf-8", "replace")))
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
        return {"kind": "quota", "error": str(j.get("msg") or j)[:120]}
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
        return {"kind": "quota", "error": str(j.get("message") or j)[:120]}
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
        return {"kind": "quota", "error": str(j)[:120]}
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
        out["credits_error"] = str(e)[:120]
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
                if sub not in host:
                    continue
                entry = {"provider": provider_of(host), "captured_at": time.time()}
                try:
                    entry.update(fn(hdrs))
                except Exception as e:
                    entry["error"] = str(e)[:160]
                result[host] = entry
                changed = True
        if changed:
            ensure_dir()
            tmp = QUOTA + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(result, f, ensure_ascii=False, indent=1)
            os.replace(tmp, QUOTA)


# ---------------------------------------------------------------- 自测

def selftest() -> None:
    import socketserver
    import tempfile
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
    proxy = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
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
    assert c.getresponse().status == 400

    assert redact_path("/v1beta/models/gemini-3-pro:generateContent?key=AIzaSECRET") == "/v1beta/models/gemini-3-pro:generateContent?…"
    assert redact_path("/v1/messages") == "/v1/messages"

    recs = [json.loads(l) for l in open(CALLS, encoding="utf-8")]
    a, o = recs[0], recs[1]
    assert a["provider"] == "本地" and a["model"] == "glm-4.7" and a["stream"] is True
    assert a["ctx"] == 17 and a["cache_read"] == 5 and a["cache_write"] == 2 and a["out"] == 7 and a["parsed"], a
    assert o["ctx"] == 100 and o["cache_read"] == 60 and o["out"] == 20 and o["think"] == 4 and o["parsed"], o
    assert o.get("rl") == {"x-ratelimit-limit-requests": "500", "x-ratelimit-remaining-requests": "125",
                           "x-ratelimit-reset-requests": "6m0s"}, o.get("rl")     # 只收限流头，别的头不收
    assert "rl" not in a, "上游没给限流头就不该有这个字段"
    assert _keys.get("127.0.0.1:%d" % mport, {}).get("authorization") == "Bearer test"   # 同一 host 后到的 key 覆盖
    print("selftest OK: 流式 Anthropic + 非流式 OpenAI 解析正确 + 限流头被动抓取, 记录", CALLS)
    # 先停服务线程再退出：否则守护线程在解释器收尾时还握着 stderr 锁，
    # 会报 "Fatal Python error: _enter_buffered_busy"、退出码 134，CI 就红了（断言其实全过）
    proxy.shutdown(); mock.shutdown()
    proxy.server_close(); mock.server_close()
    sys.stdout.flush(); sys.stderr.flush()


def main() -> None:
    if "--selftest" in sys.argv:
        selftest()
        return
    ensure_dir()
    threading.Thread(target=quota_loop, daemon=True).start()
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    srv.daemon_threads = True
    print("vibegauge-proxy listening on 127.0.0.1:%d, dir=%s" % (PORT, DIR), flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
