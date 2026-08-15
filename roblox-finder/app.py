import os
import re
import json
import time
import queue
import random
import socket
import string
import asyncio
import threading
import itertools
import requests
import urllib.request
from concurrent.futures import ThreadPoolExecutor as _TPE
from flask import (
    Flask, jsonify, request,
    render_template, send_from_directory,
    Response, stream_with_context,
)

app   = Flask(__name__)
ALPHA = string.ascii_lowercase

ROBLOX_VALIDATE = "https://auth.roblox.com/v1/usernames/validate"
REQ_HEADERS     = {"User-Agent": "Mozilla/5.0 (compatible; RobloxCheck/1.0)"}

# ── 100 Proxies ───────────────────────────────────────────────────────────────
_RAW = [
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

def _build_pool(raw):
    pool = []
    for line in raw:
        p = line.strip().split(":")
        if len(p) == 4:
            ip, port, user, pw = p
            url = f"http://{user}:{pw}@{ip}:{port}"
            pool.append({"http": url, "https": url})
    return pool

PROXY_POOL = _build_pool(_RAW)


# ── Scan state ────────────────────────────────────────────────────────────────
class Scan:
    def __init__(self):
        self.active      = False
        self.combo_q     = queue.Queue(maxsize=800)
        self.event_q     = queue.Queue(maxsize=4000)
        self.lock        = threading.Lock()
        self.checked     = 0
        self.found       = 0
        self.alive       = 0   # proxies currently running
        self.start_time  = 0.0
        self.total       = 0

    def reset(self):
        self.active     = False
        self.checked    = 0
        self.found      = 0
        self.alive      = 0
        self.start_time = 0.0
        self.total      = 0
        for q in (self.combo_q, self.event_q):
            while not q.empty():
                try:   q.get_nowait()
                except queue.Empty: break

    def push(self, event: dict):
        try:   self.event_q.put_nowait(event)
        except queue.Full: pass

    @property
    def cps(self):
        el = time.time() - self.start_time
        return round(self.checked / el, 1) if el > 0 else 0.0

    @property
    def pct(self):
        return round(self.checked / self.total * 100, 2) if self.total > 0 else 0.0


scan = Scan()


# ── Producer ──────────────────────────────────────────────────────────────────
def _producer(length: int):
    total = 26 ** length
    if total <= 500_000:
        combos = ["".join(c) for c in itertools.product(ALPHA, repeat=length)]
        random.shuffle(combos)
        for name in combos:
            if not scan.active: return
            scan.combo_q.put(name)
    else:
        # stream with random offset so it doesn't always start at 'aaa'
        offset = random.randint(0, total - 1)
        def idx_to_name(i):
            s = []
            for _ in range(length):
                s.append(ALPHA[i % 26]); i //= 26
            return "".join(reversed(s))
        for i in range(total):
            if not scan.active: return
            scan.combo_q.put(idx_to_name((i + offset) % total))

    # poison pills — one per proxy worker
    for _ in PROXY_POOL:
        scan.combo_q.put(None)


# ── Per-proxy worker ──────────────────────────────────────────────────────────
def _proxy_worker(proxy_dict: dict, idx: int):
    """
    Sleeps idx * 0.2 s before starting (staggered ramp-up),
    then continuously pulls combos and validates through its dedicated proxy.
    """
    time.sleep(idx * 0.2)

    if not scan.active:
        return

    with scan.lock:
        scan.alive += 1
    scan.push({"type": "proxy_up", "idx": idx, "alive": scan.alive})

    sess = requests.Session()
    sess.proxies.update(proxy_dict)
    sess.headers.update(REQ_HEADERS)

    params_base = {"birthday": "2000-01-01", "context": "signup"}

    while scan.active:
        try:
            username = scan.combo_q.get(timeout=3)
        except queue.Empty:
            continue

        if username is None:          # poison pill
            scan.combo_q.task_done()
            break

        try:
            r    = sess.get(ROBLOX_VALIDATE, params={**params_base, "username": username}, timeout=7)
            data = r.json()

            with scan.lock:
                scan.checked += 1

            if data.get("code") == 0:  # available!
                with scan.lock:
                    scan.found += 1
                scan.push({
                    "type":     "hit",
                    "username": username,
                    "checked":  scan.checked,
                    "found":    scan.found,
                    "cps":      scan.cps,
                })

            elif r.status_code == 429:
                # rate-limited on this proxy — re-queue & back off
                scan.combo_q.put(username)
                scan.combo_q.task_done()
                time.sleep(2)
                continue

        except (requests.exceptions.ProxyError,
                requests.exceptions.ConnectionError):
            # proxy is dead — re-queue username and bail
            try: scan.combo_q.put(username)
            except Exception: pass
            scan.combo_q.task_done()
            break

        except Exception:
            try: scan.combo_q.put(username)
            except Exception: pass
            scan.combo_q.task_done()
            time.sleep(0.3)
            continue

        scan.combo_q.task_done()

    with scan.lock:
        scan.alive -= 1

    scan.push({"type": "proxy_down", "idx": idx, "alive": scan.alive})


# ── Stats pusher (background ticker) ─────────────────────────────────────────
def _stats_ticker():
    while scan.active:
        scan.push({
            "type":    "stat",
            "checked": scan.checked,
            "found":   scan.found,
            "cps":     scan.cps,
            "pct":     scan.pct,
            "alive":   scan.alive,
        })
        time.sleep(0.5)


# ── Routes ────────────────────────────────────────────────────────────────────
@app.route("/")
def index():
    return render_template("index.html")


@app.route("/api/scan/start", methods=["POST"])
def start_scan():
    if scan.active:
        return jsonify({"error": "already running"}), 400

    body   = request.get_json(silent=True) or {}
    length = max(2, min(6, int(body.get("length", 4))))

    scan.reset()
    scan.active     = True
    scan.start_time = time.time()
    scan.total      = 26 ** length

    # Producer thread
    threading.Thread(target=_producer, args=(length,), daemon=True).start()

    # 100 proxy workers — staggered 0.2 s each
    for i, proxy in enumerate(PROXY_POOL):
        threading.Thread(target=_proxy_worker, args=(proxy, i), daemon=True).start()

    # Stats ticker
    threading.Thread(target=_stats_ticker, daemon=True).start()

    return jsonify({
        "status":  "started",
        "length":  length,
        "total":   scan.total,
        "proxies": len(PROXY_POOL),
        "ramp_s":  round(len(PROXY_POOL) * 0.2, 1),
    })


@app.route("/api/scan/stop", methods=["POST"])
def stop_scan():
    scan.active = False
    return jsonify({"status": "stopped", "checked": scan.checked, "found": scan.found})


@app.route("/api/scan/stream")
def scan_stream():
    """SSE — pushes stat, hit, proxy_up/down events in real-time."""
    def generate():
        yield f"data: {json.dumps({'type': 'connected', 'proxies': len(PROXY_POOL)})}\n\n"
        while True:
            try:
                ev = scan.event_q.get(timeout=1.5)
                yield f"data: {json.dumps(ev)}\n\n"
            except queue.Empty:
                # heartbeat keeps connection alive
                yield f"data: {json.dumps({'type': 'ping', 'active': scan.active, 'checked': scan.checked})}\n\n"

    return Response(
        stream_with_context(generate()),
        content_type="text/event-stream",
        headers={
            "Cache-Control":    "no-cache",
            "X-Accel-Buffering":"no",
            "Connection":       "keep-alive",
        },
    )


@app.route("/api/scan/status")
def scan_status():
    return jsonify({
        "active":  scan.active,
        "checked": scan.checked,
        "found":   scan.found,
        "cps":     scan.cps,
        "pct":     scan.pct,
        "alive":   scan.alive,
        "total":   scan.total,
        "proxies": len(PROXY_POOL),
    })


@app.route("/static/<path:filename>")
def static_files(filename):
    return send_from_directory("static", filename)


# ── Proxy Scraper ──────────────────────────────────────────────────────────
_SCRAPE_SOURCES = [
    "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt",
    "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt",
    "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies_anonymous/http.txt",
    "https://raw.githubusercontent.com/ShiftyTR/Proxy-List/master/http.txt",
    "https://raw.githubusercontent.com/ShiftyTR/Proxy-List/master/https.txt",
    "https://raw.githubusercontent.com/clarketm/proxy-list/master/proxy-list-raw.txt",
    "https://raw.githubusercontent.com/mmpx12/proxy-list/master/http.txt",
    "https://raw.githubusercontent.com/prxchk/proxy-list/main/http.txt",
    "https://raw.githubusercontent.com/roosterkid/openproxylist/main/HTTP_RAW.txt",
    "https://raw.githubusercontent.com/officialputuid/KangProxy/KangProxy/http/http.txt",
    "https://raw.githubusercontent.com/zevtyardt/proxy-list/main/http.txt",
    "https://raw.githubusercontent.com/MuRongPIG/Proxy-Master/main/http.txt",
    "https://raw.githubusercontent.com/B4RC0DE-TM/proxy-list/main/HTTP.txt",
    "https://raw.githubusercontent.com/ALIILAPRO/Proxy/main/http.txt",
    "https://raw.githubusercontent.com/casals-ar/proxy-list/main/http.txt",
    "https://raw.githubusercontent.com/caliphdev/Proxy-List/master/http.txt",
    "https://raw.githubusercontent.com/zloi-user/hideip.me/main/http.txt",
    "https://raw.githubusercontent.com/saschazesiger/Free-Proxies/master/proxies/http.txt",
    "https://raw.githubusercontent.com/proxifly/free-proxy-list/main/proxies/protocols/http/data.txt",
    "https://raw.githubusercontent.com/Zaeem20/FREE_PROXIES_LIST/master/http.txt",
    "https://raw.githubusercontent.com/ErcinDedeoglu/proxies/main/proxies/http.txt",
    "https://raw.githubusercontent.com/HyperBeats/proxy-list/main/http.txt",
    "https://raw.githubusercontent.com/sunny9577/proxy-scraper/master/proxies.txt",
    "https://api.proxyscrape.com/v2/?request=displayproxies&protocol=http&timeout=5000&country=all",
    "https://api.proxyscrape.com/v2/?request=displayproxies&protocol=https&timeout=5000&country=all",
    "https://www.proxy-list.download/api/v1/get?type=http",
    "https://api.openproxylist.xyz/http.txt",
    "https://multiproxy.org/txt_all/proxy.txt",
    "https://spys.me/proxy.txt",
    "https://proxylist.geonode.com/api/proxy-list?limit=500&page=1&sort_by=lastChecked&sort_type=desc&protocols=http",
    "https://proxylist.geonode.com/api/proxy-list?limit=500&page=2&sort_by=lastChecked&sort_type=desc&protocols=http",
]

_SCRAPE_RE     = re.compile(r"\b(\d{1,3}(?:\.\d{1,3}){3}):(\d{2,5})\b")

# Mode: "connect" — CONNECT tunnel to roblox.com:443 (fast TCP reachability check)
_CHECK_CONNECT = (
    b"CONNECT auth.roblox.com:443 HTTP/1.0\r\n"
    b"Host: auth.roblox.com:443\r\n"
    b"User-Agent: Mozilla/5.0\r\n"
    b"\r\n"
)

# Mode: "roblox" — plain HTTP GET through the proxy; actually hits Roblox servers
# Roblox replies 301→https (or 200/403); any of these proves the proxy routes traffic there
_ROBLOX_REQ  = (
    b"GET http://www.roblox.com/ HTTP/1.0\r\n"
    b"Host: www.roblox.com\r\n"
    b"User-Agent: Mozilla/5.0 (compatible; RobloxCheck/1.0)\r\n"
    b"Connection: close\r\n"
    b"\r\n"
)
_ROBLOX_GOOD = {b"200", b"301", b"302", b"403"}


class ProxyScrape:
    def __init__(self):
        self.active   = False
        self.phase    = "idle"   # idle / scraping / validating / done
        self.event_q  = queue.Queue(maxsize=3000)
        self.lock     = threading.Lock()
        self.raw      = 0
        self.checked  = 0
        self.found    = 0
        self.total    = 0
        self.start_t  = 0.0
        self.proxies  = []       # working ip:port strings

    def reset(self):
        self.active  = False
        self.phase   = "idle"
        self.raw     = 0
        self.checked = 0
        self.found   = 0
        self.total   = 0
        self.start_t = 0.0
        self.proxies = []
        while not self.event_q.empty():
            try:   self.event_q.get_nowait()
            except queue.Empty: break

    def push(self, ev):
        try:   self.event_q.put_nowait(ev)
        except queue.Full: pass

    @property
    def cps(self):
        el = time.time() - self.start_t
        return round(self.checked / el, 1) if el > 0 and self.checked else 0.0


pscrape = ProxyScrape()


# ── async raw-socket check ────────────────────────────────────────────────
async def _check_async(ip: str, port: int, timeout: float,
                        mode: str = "connect") -> bool:
    writer = None
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(ip, port), timeout=timeout
        )
        if mode == "roblox":
            # Plain HTTP GET through proxy → actually reaches Roblox servers
            writer.write(_ROBLOX_REQ)
            await writer.drain()
            buf = await asyncio.wait_for(reader.read(48), timeout=timeout)
            if not buf.startswith(b"HTTP/"):
                return False
            parts = buf.split()
            return len(parts) >= 2 and parts[1] in _ROBLOX_GOOD
        else:
            # CONNECT tunnel — fast TCP reachability to roblox.com:443
            writer.write(_CHECK_CONNECT)
            await writer.drain()
            buf = await asyncio.wait_for(reader.read(64), timeout=timeout)
            if not buf.startswith(b"HTTP/"):
                return False
            parts = buf.split()
            return len(parts) >= 2 and parts[1] == b"200"
    except Exception:
        return False
    finally:
        if writer:
            try: writer.close()
            except Exception: pass


async def _validate_proxies_async(proxies: list, timeout: float = 2.0,
                                   concurrency: int = 200, mode: str = "connect"):
    """Chunked validation — processes CHUNK proxies at a time so memory stays
    bounded on Render's free tier (512 MB) regardless of total proxy count."""
    CHUNK   = 2000
    sem     = asyncio.Semaphore(concurrency)
    total   = len(proxies)
    start_t = time.time()

    async def do_one(proxy: str):
        try:
            ip, port_s = proxy.rsplit(":", 1)
            port = int(port_s)
            if not (1 <= port <= 65535):
                raise ValueError
        except Exception:
            with pscrape.lock:
                pscrape.checked += 1
            return

        async with sem:
            ok = await _check_async(ip, port, timeout, mode)

        with pscrape.lock:
            pscrape.checked += 1
            c = pscrape.checked
            if ok:
                pscrape.found  += 1
                pscrape.proxies.append(proxy)

        if ok:
            pscrape.push({
                "type":    "proxy_found",
                "proxy":   proxy,
                "found":   pscrape.found,
                "checked": pscrape.checked,
            })

        if c % 200 == 0 or ok:
            elapsed = max(time.time() - start_t, 0.001)
            pscrape.push({
                "type":    "validate_stat",
                "checked": c,
                "total":   total,
                "found":   pscrape.found,
                "cps":     round(c / elapsed, 1),
                "pct":     round(c / total * 100, 2),
            })

    # Process in chunks — each chunk's coroutines are GC'd before the next starts
    for i in range(0, total, CHUNK):
        if not pscrape.active:
            break
        chunk = proxies[i:i + CHUNK]
        await asyncio.gather(*[do_one(p) for p in chunk])


# ── background runner ─────────────────────────────────────────────────────
def _proxy_scrape_runner(mode="connect"):
    import concurrent.futures as _cf
    try:
        _proxy_scrape_runner_inner(_cf, mode)
    except Exception as exc:
        # Crash guard — always push done so the frontend can recover
        pscrape.push({"type": "log",
                      "msg":   f"✗ runner crashed: {type(exc).__name__}: {exc}",
                      "level": "err"})
        pscrape.push({"type": "done", "found": pscrape.found, "checked": pscrape.checked})
        pscrape.phase  = "done"
        pscrape.active = False


def _proxy_scrape_runner_inner(_cf, mode="connect"):
    # Phase 1 — scrape sources with a bounded thread pool
    all_raw   = set()
    done_c    = [0]
    raw_lock  = threading.Lock()
    n         = len(_SCRAPE_SOURCES)

    def fetch_one(url):
        src = url.split("/")[2]  # domain only for display
        try:
            req = urllib.request.Request(
                url, headers={"User-Agent": "Mozilla/5.0 (ProxyScraper)"}
            )
            with urllib.request.urlopen(req, timeout=10) as r:
                text = r.read().decode("utf-8", errors="ignore")
            found = [f"{ip}:{port}" for ip, port in _SCRAPE_RE.findall(text)]
            level = "ok" if found else ""
            pscrape.push({"type": "log",
                          "msg":   f"✓ {src} — {len(found)} proxies",
                          "level": level})
        except Exception as exc:
            found = []
            pscrape.push({"type": "log",
                          "msg":   f"✗ {src} — {type(exc).__name__}",
                          "level": "err"})
        with raw_lock:
            all_raw.update(found)
            done_c[0] += 1
            pscrape.raw = len(all_raw)
        pscrape.push({
            "type":  "scrape_progress",
            "done":  done_c[0],
            "total": n,
            "raw":   len(all_raw),
        })

    # socket.setdefaulttimeout cuts OS-level TCP hangs that urlopen(timeout=) can miss
    old_sock_timeout = socket.getdefaulttimeout()
    socket.setdefaulttimeout(12)
    pool = _TPE(max_workers=20)
    try:
        futs = [pool.submit(fetch_one, url) for url in _SCRAPE_SOURCES]
        for fut in _cf.as_completed(futs, timeout=90):
            try:
                fut.result()  # already completed, no extra timeout needed
            except Exception:
                pass
    except _cf.TimeoutError:
        pscrape.push({"type": "log", "msg": "⚠ scraping timed out — continuing with partial results", "level": "err"})
    finally:
        pool.shutdown(wait=False)  # don't hang on any stuck futures
        socket.setdefaulttimeout(old_sock_timeout)

    if not pscrape.active:
        return

    if not all_raw:
        pscrape.push({"type": "log", "msg": "✗ scraped 0 proxies — check server network", "level": "err"})
        pscrape.push({"type": "done", "found": 0, "checked": 0})
        pscrape.phase  = "done"
        pscrape.active = False
        return

    # Cap to keep validation inside Render's limits (~3-4 min for 20k)
    # random.sample works directly on a set (reservoir sampling) — no need to
    # build a full list first, saving peak memory when all_raw is huge.
    CAP = 20_000
    total_scraped = len(all_raw)
    if total_scraped > CAP:
        proxies = random.sample(list(all_raw), CAP)
        cap_note = f" (capped from {total_scraped:,} scraped)"
    else:
        proxies = list(all_raw)
        cap_note = ""

    mode_label = "Roblox HTTP" if mode == "roblox" else "CONNECT tunnel"
    pscrape.push({"type": "log",
                  "msg":   f"→ {len(proxies):,} proxies{cap_note} → {mode_label} validation",
                  "level": "info"})

    pscrape.total = len(proxies)
    pscrape.phase = "validating"
    pscrape.push({"type": "phase", "phase": "validating", "total": len(proxies)})

    # Phase 2 — async validation (own event loop in this thread)
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        loop.run_until_complete(_validate_proxies_async(proxies, mode=mode))
    finally:
        loop.close()

    pscrape.push({"type": "done", "found": pscrape.found, "checked": pscrape.checked})
    pscrape.phase  = "done"
    pscrape.active = False


# ── proxy scraper routes ──────────────────────────────────────────────────
@app.route("/api/proxies/start", methods=["POST"])
def proxies_start():
    if pscrape.active:
        return jsonify({"error": "already running"}), 400
    data = request.get_json(silent=True) or {}
    mode = data.get("mode", "connect")
    if mode not in ("connect", "roblox"):
        mode = "connect"
    pscrape.reset()
    pscrape.active  = True
    pscrape.phase   = "scraping"
    pscrape.start_t = time.time()
    threading.Thread(target=_proxy_scrape_runner, args=(mode,), daemon=True).start()
    return jsonify({"status": "started", "sources": len(_SCRAPE_SOURCES), "mode": mode})


@app.route("/api/proxies/stop", methods=["POST"])
def proxies_stop():
    pscrape.active = False
    pscrape.phase  = "idle"
    return jsonify({"status": "stopped"})


@app.route("/api/proxies/stream")
def proxies_stream():
    def generate():
        yield f"data: {json.dumps({'type': 'connected'})}\n\n"
        while True:
            try:
                ev = pscrape.event_q.get(timeout=1.5)
                yield f"data: {json.dumps(ev)}\n\n"
                if ev.get("type") == "done":
                    return
            except queue.Empty:
                yield f"data: {json.dumps({'type':'ping','phase':pscrape.phase,'active':pscrape.active})}\n\n"

    return Response(
        stream_with_context(generate()),
        content_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no",
                 "Connection": "keep-alive"},
    )


@app.route("/api/proxies/activate", methods=["POST"])
def proxies_activate():
    if scan.active:
        return jsonify({"error": "stop the scanner first"}), 400
    if not pscrape.proxies:
        return jsonify({"error": "no working proxies found yet"}), 400
    new_pool = [{"http": f"http://{p}", "https": f"http://{p}"}
                for p in pscrape.proxies]
    PROXY_POOL.clear()
    PROXY_POOL.extend(new_pool)
    return jsonify({"status": "loaded", "count": len(new_pool)})


@app.route("/api/proxies/status")
def proxies_status():
    return jsonify({
        "active":   pscrape.active,
        "phase":    pscrape.phase,
        "raw":      pscrape.raw,
        "checked":  pscrape.checked,
        "found":    pscrape.found,
        "total":    pscrape.total,
        "cps":      pscrape.cps,
        "loaded":   len(PROXY_POOL),
    })


@app.route("/api/proxies/results")
def proxies_results():
    """Returns the working proxy list so the frontend can recover it after a
    SSE disconnect — client-side pProxyResults is repopulated from here."""
    return jsonify({
        "proxies": pscrape.proxies,
        "found":   pscrape.found,
        "phase":   pscrape.phase,
    })


if __name__ == "__main__":
    port = int(os.environ.get("PORT", 10000))
    app.run(host="0.0.0.0", port=port, threaded=True)
