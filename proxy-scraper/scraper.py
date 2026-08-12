"""
scraper.py — scrapes 50+ sources, validates with raw sockets (no urllib overhead)

Usage:
    python scraper.py                  # default: 300 threads, 3s timeout
    python scraper.py --threads 100    # lower if A-Shell struggles
    python scraper.py --timeout 5      # more lenient timeout
    python scraper.py --out out.txt    # custom output file

Pure stdlib. Zero installs.
"""

import sys
import re
import time
import queue
import socket
import threading
import urllib.request
import argparse
from datetime import datetime

# ── Colours ───────────────────────────────────────────────────────────────
def _c(code, t): return f"\033[{code}m{t}\033[0m"
GRN  = lambda t: _c("32;1", t)
RED  = lambda t: _c("31",   t)
CYN  = lambda t: _c("36",   t)
DIM  = lambda t: _c("2",    t)
BLD  = lambda t: _c("1",    t)

# ── 50 sources ────────────────────────────────────────────────────────────
SOURCES = [
    # ── GitHub raw lists ──────────────────────────────────────────────────
    "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt",
    "https://raw.githubusercontent.com/TheSpeedX/SOCKS-List/master/http.txt",
    "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt",
    "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies_anonymous/http.txt",
    "https://raw.githubusercontent.com/ShiftyTR/Proxy-List/master/http.txt",
    "https://raw.githubusercontent.com/ShiftyTR/Proxy-List/master/https.txt",
    "https://raw.githubusercontent.com/clarketm/proxy-list/master/proxy-list-raw.txt",
    "https://raw.githubusercontent.com/sunny9577/proxy-scraper/master/proxies.txt",
    "https://raw.githubusercontent.com/mmpx12/proxy-list/master/http.txt",
    "https://raw.githubusercontent.com/mmpx12/proxy-list/master/https.txt",
    "https://raw.githubusercontent.com/prxchk/proxy-list/main/http.txt",
    "https://raw.githubusercontent.com/roosterkid/openproxylist/main/HTTPS_RAW.txt",
    "https://raw.githubusercontent.com/roosterkid/openproxylist/main/HTTP_RAW.txt",
    "https://raw.githubusercontent.com/officialputuid/KangProxy/KangProxy/http/http.txt",
    "https://raw.githubusercontent.com/officialputuid/KangProxy/KangProxy/https/https.txt",
    "https://raw.githubusercontent.com/andigwandi/free-proxy/main/proxy_list.txt",
    "https://raw.githubusercontent.com/Anonym0usWork1221/Free-Proxies/main/proxy_files/http_proxies.txt",
    "https://raw.githubusercontent.com/Anonym0usWork1221/Free-Proxies/main/proxy_files/https_proxies.txt",
    "https://raw.githubusercontent.com/zevtyardt/proxy-list/main/http.txt",
    "https://raw.githubusercontent.com/MuRongPIG/Proxy-Master/main/http.txt",
    "https://raw.githubusercontent.com/Zaeem20/FREE_PROXIES_LIST/master/http.txt",
    "https://raw.githubusercontent.com/ErcinDedeoglu/proxies/main/proxies/http.txt",
    "https://raw.githubusercontent.com/rdavydov/proxy-list/main/proxies/http.txt",
    "https://raw.githubusercontent.com/HyperBeats/proxy-list/main/http.txt",
    "https://raw.githubusercontent.com/B4RC0DE-TM/proxy-list/main/HTTP.txt",
    "https://raw.githubusercontent.com/ALIILAPRO/Proxy/main/http.txt",
    "https://raw.githubusercontent.com/casals-ar/proxy-list/main/http.txt",
    "https://raw.githubusercontent.com/caliphdev/Proxy-List/master/http.txt",
    "https://raw.githubusercontent.com/zloi-user/hideip.me/main/http.txt",
    "https://raw.githubusercontent.com/elliottophellia/yakumo/master/results/http/global/http_checked.txt",
    "https://raw.githubusercontent.com/saschazesiger/Free-Proxies/master/proxies/http.txt",
    "https://raw.githubusercontent.com/im-razvan/proxy_list/main/http.txt",
    "https://raw.githubusercontent.com/a2u/free-proxy-list/master/free-proxy-list.txt",
    "https://raw.githubusercontent.com/hendrikbgr/Free-Proxy-Repo/master/proxy_list.txt",
    "https://raw.githubusercontent.com/Volodichev/proxy-list/main/http.txt",
    "https://raw.githubusercontent.com/IIFEBien/proxy-list/master/http.txt",
    "https://raw.githubusercontent.com/yuceltoluyag/GoodProxy/main/raw.txt",
    "https://raw.githubusercontent.com/almroot/proxylist/master/list.txt",
    "https://raw.githubusercontent.com/ObcbO/getproxy/master/file/http.txt",
    "https://raw.githubusercontent.com/hookzof/socks5_list/master/proxy.txt",
    "https://raw.githubusercontent.com/saisuiu/Lionkings-Http-Proxys-Lists/main/cnfree.txt",
    "https://raw.githubusercontent.com/proxifly/free-proxy-list/main/proxies/protocols/http/data.txt",
    "https://raw.githubusercontent.com/proxifly/free-proxy-list/main/proxies/all/data.txt",
    # ── API endpoints ──────────────────────────────────────────────────────
    "https://api.proxyscrape.com/v2/?request=displayproxies&protocol=http&timeout=5000&country=all&ssl=all&anonymity=all",
    "https://api.proxyscrape.com/v2/?request=displayproxies&protocol=https&timeout=5000&country=all&ssl=all&anonymity=all",
    "https://www.proxy-list.download/api/v1/get?type=http",
    "https://www.proxy-list.download/api/v1/get?type=https",
    "https://api.openproxylist.xyz/http.txt",
    "https://multiproxy.org/txt_all/proxy.txt",
    "https://spys.me/proxy.txt",
    "https://proxylist.geonode.com/api/proxy-list?limit=500&page=1&sort_by=lastChecked&sort_type=desc&protocols=http",
    "https://proxylist.geonode.com/api/proxy-list?limit=500&page=2&sort_by=lastChecked&sort_type=desc&protocols=http",
    "https://proxylist.geonode.com/api/proxy-list?limit=500&page=3&sort_by=lastChecked&sort_type=desc&protocols=http",
]

_PROXY_RE = re.compile(r"\b(\d{1,3}(?:\.\d{1,3}){3}):(\d{2,5})\b")

# ── HTTP request bytes sent through each proxy ────────────────────────────
# google.com — globally reachable, fast CDN, proves traffic routes correctly
_HTTP_REQ = (
    b"GET http://www.google.com/ HTTP/1.0\r\n"
    b"Host: www.google.com\r\n"
    b"User-Agent: Mozilla/5.0\r\n"
    b"Connection: close\r\n\r\n"
)
# We accept any of these as "proxy works"
_GOOD_STATUS = {b"200", b"204", b"301", b"302", b"403"}


# ── Scrape ────────────────────────────────────────────────────────────────
def _fetch_source(url):
    try:
        req = urllib.request.Request(
            url, headers={"User-Agent": "Mozilla/5.0 (ProxyScraper)"}
        )
        with urllib.request.urlopen(req, timeout=12) as r:
            text = r.read().decode("utf-8", errors="ignore")
        return [f"{ip}:{port}" for ip, port in _PROXY_RE.findall(text)]
    except Exception:
        return []


def scrape_all(sources):
    collected = []
    done      = [0]
    lock      = threading.Lock()

    def task(url):
        found = _fetch_source(url)
        with lock:
            collected.extend(found)
            done[0] += 1
            print(
                f"\r  {CYN('scraping')}  "
                f"{done[0]:>2}/{len(sources)} sources  "
                f"{GRN(str(len(collected)))} raw   ",
                end="", flush=True,
            )

    threads = [threading.Thread(target=task, args=(u,), daemon=True) for u in sources]
    for t in threads: t.start()
    for t in threads: t.join()
    print()
    return set(collected)


# ── Validate (raw socket — no urllib overhead) ────────────────────────────
def _validate(proxy, timeout):
    """
    Open a raw TCP socket to the proxy, send an HTTP GET through it,
    read the first 48 bytes of the response, check the status code.
    Much faster than urllib: no handler/opener allocation, reads minimal bytes.
    """
    try:
        ip, port_s = proxy.rsplit(":", 1)
        port = int(port_s)
        if not (1 <= port <= 65535):
            return False
    except Exception:
        return False

    sock = None
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(timeout)
        sock.connect((ip, port))
        sock.sendall(_HTTP_REQ)

        # read just enough to see the status line
        buf = b""
        while len(buf) < 48:
            chunk = sock.recv(48 - len(buf))
            if not chunk:
                break
            buf += chunk

        # buf looks like: b"HTTP/1.0 200 OK\r\n..."
        if not buf.startswith(b"HTTP/"):
            return False
        parts = buf.split()
        return len(parts) >= 2 and parts[1] in _GOOD_STATUS

    except Exception:
        return False
    finally:
        if sock:
            try: sock.close()
            except Exception: pass


def validate_all(proxies, timeout, workers, out_file):
    proxy_list = list(proxies)
    total      = len(proxy_list)
    work_q     = queue.Queue()
    for p in proxy_list:
        work_q.put(p)

    working = []
    checked = [0]
    lock    = threading.Lock()
    start_t = time.time()
    out_fh  = open(out_file, "w")

    def worker():
        while True:
            try:
                proxy = work_q.get(timeout=0.5)
            except queue.Empty:
                break
            ok = _validate(proxy, timeout)
            with lock:
                checked[0] += 1
                elapsed = max(time.time() - start_t, 0.001)
                cps     = checked[0] / elapsed
                pct     = checked[0] / total * 100
                if ok:
                    working.append(proxy)
                    out_fh.write(proxy + "\n")
                    out_fh.flush()
                print(
                    f"\r  {CYN('validating')}  "
                    f"{checked[0]:>{len(str(total))}}/{total}  "
                    f"{DIM(f'{pct:5.1f}%')}  "
                    f"{GRN(str(len(working)))} working  "
                    f"{DIM(f'{cps:6.1f}/s')}  ",
                    end="", flush=True,
                )
            work_q.task_done()

    pool = [threading.Thread(target=worker, daemon=True)
            for _ in range(min(workers, total or 1))]
    for t in pool: t.start()
    for t in pool: t.join()
    print()

    out_fh.close()
    return working


# ── Entry point ───────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description="Axiom proxy scraper")
    ap.add_argument("--threads", type=int, default=300,
                    help="Validation threads (default 300; try 100 on A-Shell)")
    ap.add_argument("--timeout", type=float, default=3,
                    help="Socket timeout per proxy in seconds (default 3)")
    ap.add_argument("--out",     type=str,   default="proxies.txt",
                    help="Output file (default proxies.txt)")
    args = ap.parse_args()

    print()
    print(BLD("  AXIOM PROXY SCRAPER"))
    print(DIM(f"  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}  "
              f"{len(SOURCES)} sources  raw-socket validator"))
    print()

    # 1. Scrape
    print(f"  {BLD('[1/2]')} Scraping {len(SOURCES)} sources simultaneously…")
    raw = scrape_all(SOURCES)
    print(f"  {GRN('→')} {len(raw):,} unique proxies")
    print()

    if not raw:
        print(RED("  ✗ Nothing scraped — check internet."))
        sys.exit(1)

    # 2. Validate
    eta_s = len(raw) / args.threads * args.timeout
    print(f"  {BLD('[2/2]')} Validating  "
          f"{DIM(f'{args.threads} threads · {args.timeout}s timeout · ~{eta_s:.0f}s ETA')}")
    working = validate_all(raw, args.timeout, args.threads, args.out)

    # 3. Summary
    print()
    if working:
        rate = len(working) / len(raw) * 100
        print(f"  {GRN('✓')} {BLD(str(len(working)))} working  "
              f"{DIM(f'({rate:.1f}% hit rate · saved to {args.out})')}")
        print()
        cap = min(15, len(working))
        print(DIM(f"  first {cap}:"))
        for p in working[:cap]:
            print(f"    {CYN(p)}")
        if len(working) > cap:
            print(DIM(f"    … and {len(working) - cap} more in {args.out}"))
    else:
        print(RED("  ✗ No working proxies."))
        print(DIM("    Try --timeout 5 or --timeout 8"))
    print()


if __name__ == "__main__":
    main()
