import os
import random
import threading
import requests
from flask import Flask, jsonify, request, render_template, send_from_directory

app = Flask(__name__)

ROBLOX_VALIDATE = "https://auth.roblox.com/v1/usernames/validate"
HEADERS = {"User-Agent": "Mozilla/5.0 (compatible; RobloxCheck/1.0)"}

# ── 100 Proxies ──────────────────────────────────────────────────────────────
_RAW_PROXIES = [
    "31.59.15.64:6331:cloverbots:delisigmaboy",
    "45.41.173.174:6541:cloverbots:delisigmaboy",
    "45.41.177.89:5739:cloverbots:delisigmaboy",
    "45.61.100.182:6450:cloverbots:delisigmaboy",
    "145.223.54.153:6118:cloverbots:delisigmaboy",
    "209.242.202.225:6625:cloverbots:delisigmaboy",
    "45.39.73.109:5524:cloverbots:delisigmaboy",
    "45.43.65.73:6587:cloverbots:delisigmaboy",
    "107.174.136.239:6181:cloverbots:delisigmaboy",
    "23.129.254.125:6107:cloverbots:delisigmaboy",
    "31.223.188.241:5918:cloverbots:delisigmaboy",
    "45.127.248.238:5239:cloverbots:delisigmaboy",
    "82.22.249.221:7058:cloverbots:delisigmaboy",
    "82.24.237.92:7444:cloverbots:delisigmaboy",
    "89.249.192.222:6621:cloverbots:delisigmaboy",
    "149.57.85.89:6057:cloverbots:delisigmaboy",
    "38.154.205.97:5365:cloverbots:delisigmaboy",
    "152.232.119.26:5534:cloverbots:delisigmaboy",
    "192.241.118.202:5456:cloverbots:delisigmaboy",
    "45.61.121.213:6812:cloverbots:delisigmaboy",
    "161.123.154.127:6657:cloverbots:delisigmaboy",
    "152.232.119.248:5756:cloverbots:delisigmaboy",
    "45.83.59.143:7159:cloverbots:delisigmaboy",
    "69.58.12.124:8129:cloverbots:delisigmaboy",
    "172.245.157.220:6805:cloverbots:delisigmaboy",
    "46.203.96.218:6342:cloverbots:delisigmaboy",
    "64.137.89.69:6142:cloverbots:delisigmaboy",
    "184.174.126.79:6371:cloverbots:delisigmaboy",
    "45.87.51.40:6600:cloverbots:delisigmaboy",
    "104.232.209.126:6084:cloverbots:delisigmaboy",
    "107.172.116.189:5645:cloverbots:delisigmaboy",
    "92.112.236.254:6686:cloverbots:delisigmaboy",
    "45.92.77.168:8215:cloverbots:delisigmaboy",
    "142.111.93.13:6574:cloverbots:delisigmaboy",
    "194.113.119.179:6853:cloverbots:delisigmaboy",
    "92.112.217.252:6024:cloverbots:delisigmaboy",
    "191.101.11.151:6549:cloverbots:delisigmaboy",
    "46.203.154.130:5573:cloverbots:delisigmaboy",
    "92.113.241.77:6162:cloverbots:delisigmaboy",
    "140.99.202.209:6087:cloverbots:delisigmaboy",
    "23.236.216.173:6203:cloverbots:delisigmaboy",
    "64.137.100.20:5075:cloverbots:delisigmaboy",
    "216.74.115.29:6623:cloverbots:delisigmaboy",
    "23.129.252.83:6351:cloverbots:delisigmaboy",
    "82.27.247.88:5422:cloverbots:delisigmaboy",
    "92.112.200.215:6798:cloverbots:delisigmaboy",
    "152.232.118.94:5348:cloverbots:delisigmaboy",
    "172.121.159.149:5309:cloverbots:delisigmaboy",
    "192.177.87.68:5914:cloverbots:delisigmaboy",
    "85.198.47.150:6418:cloverbots:delisigmaboy",
    "104.233.13.175:6170:cloverbots:delisigmaboy",
    "181.214.6.95:5280:cloverbots:delisigmaboy",
    "104.253.55.80:5510:cloverbots:delisigmaboy",
    "38.154.184.63:6831:cloverbots:delisigmaboy",
    "193.187.115.16:5531:cloverbots:delisigmaboy",
    "198.23.239.251:6657:cloverbots:delisigmaboy",
    "46.203.96.12:6136:cloverbots:delisigmaboy",
    "104.239.37.85:5737:cloverbots:delisigmaboy",
    "161.123.101.91:6717:cloverbots:delisigmaboy",
    "31.58.30.57:6639:cloverbots:delisigmaboy",
    "38.154.206.136:9627:cloverbots:delisigmaboy",
    "104.143.245.254:6494:cloverbots:delisigmaboy",
    "145.223.59.86:6120:cloverbots:delisigmaboy",
    "172.245.158.17:5970:cloverbots:delisigmaboy",
    "45.131.94.88:6075:cloverbots:delisigmaboy",
    "45.131.95.154:5818:cloverbots:delisigmaboy",
    "64.137.60.181:5245:cloverbots:delisigmaboy",
    "45.56.175.86:5760:cloverbots:delisigmaboy",
    "104.238.7.166:6093:cloverbots:delisigmaboy",
    "45.43.64.36:6294:cloverbots:delisigmaboy",
    "82.27.245.50:6373:cloverbots:delisigmaboy",
    "104.239.73.164:6707:cloverbots:delisigmaboy",
    "194.5.3.18:5530:cloverbots:delisigmaboy",
    "31.59.33.104:6680:cloverbots:delisigmaboy",
    "31.58.10.101:6069:cloverbots:delisigmaboy",
    "213.169.210.131:6772:cloverbots:delisigmaboy",
    "45.39.5.115:6553:cloverbots:delisigmaboy",
    "104.253.82.28:6449:cloverbots:delisigmaboy",
    "140.99.201.73:5952:cloverbots:delisigmaboy",
    "31.59.13.13:6283:cloverbots:delisigmaboy",
    "82.25.235.140:7491:cloverbots:delisigmaboy",
    "104.233.19.112:5784:cloverbots:delisigmaboy",
    "137.59.4.68:5937:cloverbots:delisigmaboy",
    "104.252.109.195:7128:cloverbots:delisigmaboy",
    "64.137.94.190:6413:cloverbots:delisigmaboy",
    "103.47.53.179:8477:cloverbots:delisigmaboy",
    "31.59.10.226:5797:cloverbots:delisigmaboy",
    "67.227.36.232:6274:cloverbots:delisigmaboy",
    "104.143.224.67:5928:cloverbots:delisigmaboy",
    "92.112.217.67:5839:cloverbots:delisigmaboy",
    "45.39.4.243:5668:cloverbots:delisigmaboy",
    "23.236.222.199:7230:cloverbots:delisigmaboy",
    "104.253.86.237:5671:cloverbots:delisigmaboy",
    "217.117.166.236:5878:cloverbots:delisigmaboy",
    "23.27.138.167:6268:cloverbots:delisigmaboy",
    "23.236.179.254:5885:cloverbots:delisigmaboy",
    "82.29.244.139:5962:cloverbots:delisigmaboy",
    "108.165.205.251:5488:cloverbots:delisigmaboy",
    "38.154.185.86:6359:cloverbots:delisigmaboy",
    "64.137.93.188:6645:cloverbots:delisigmaboy",
]


def _build_proxy_pool(raw: list[str]) -> list[dict]:
    """Convert ip:port:user:pass → requests proxy dict."""
    pool = []
    for line in raw:
        parts = line.strip().split(":")
        if len(parts) == 4:
            ip, port, user, pw = parts
            url = f"http://{user}:{pw}@{ip}:{port}"
            pool.append({"http": url, "https": url})
    return pool


PROXY_POOL = _build_proxy_pool(_RAW_PROXIES)

# ── Thread-safe round-robin counter ─────────────────────────────────────────
_lock    = threading.Lock()
_rr_idx  = 0
_bad     = set()   # indices of dead proxies

def _next_proxy() -> dict | None:
    """Return next proxy in round-robin, skipping known-bad ones."""
    global _rr_idx
    if not PROXY_POOL:
        return None
    with _lock:
        attempts = 0
        while attempts < len(PROXY_POOL):
            idx = _rr_idx % len(PROXY_POOL)
            _rr_idx += 1
            if idx not in _bad:
                return PROXY_POOL[idx], idx
            attempts += 1
    return None, -1   # all bad


def _mark_bad(idx: int):
    """Mark a proxy as dead so it gets skipped."""
    if idx >= 0:
        with _lock:
            _bad.add(idx)


# ── Roblox check with proxy rotation + retry ────────────────────────────────
def roblox_check(username: str) -> tuple[int, dict]:
    """
    Check Roblox username availability.
    Rotates through proxy pool; retries up to 3× on failure.
    Returns (http_status, body_dict).
    """
    params = {
        "birthday": "2000-01-01",
        "context":  "signup",
        "username": username,
    }

    for attempt in range(3):
        proxy, idx = _next_proxy()
        try:
            r = requests.get(
                ROBLOX_VALIDATE,
                params=params,
                headers=HEADERS,
                proxies=proxy,
                timeout=7,
            )
            return r.status_code, r.json()

        except requests.exceptions.ProxyError:
            _mark_bad(idx)
        except requests.Timeout:
            pass   # proxy alive, just slow — don't mark bad
        except Exception:
            _mark_bad(idx)

    # all attempts failed — fall back to direct (no proxy)
    try:
        r = requests.get(ROBLOX_VALIDATE, params=params, headers=HEADERS, timeout=8)
        return r.status_code, r.json()
    except Exception as e:
        return 500, {"code": -1, "error": str(e)}


# ── Routes ───────────────────────────────────────────────────────────────────
@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/check")
def check():
    username = request.args.get("username", "").strip()
    if not username or len(username) > 20:
        return jsonify({"code": -1, "error": "invalid"}), 400

    status, body = roblox_check(username)
    return jsonify(body), status


@app.route("/api/proxy-stats")
def proxy_stats():
    """Live proxy pool health for debugging."""
    return jsonify({
        "total":   len(PROXY_POOL),
        "dead":    len(_bad),
        "alive":   len(PROXY_POOL) - len(_bad),
        "rr_idx":  _rr_idx % len(PROXY_POOL) if PROXY_POOL else 0,
    })


@app.route("/static/<path:filename>")
def static_files(filename):
    return send_from_directory("static", filename)


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 10000))
    app.run(host="0.0.0.0", port=port)
