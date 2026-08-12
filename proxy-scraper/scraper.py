"""
scraper.py — scrapes 50+ sources, validates with raw sockets

A-Shell safe: uses ThreadPoolExecutor (fixed pool, never spawns more
threads than --threads). Default is 40 — raise carefully on A-Shell.

Usage:
    python scraper.py                   # 40 threads, 4s timeout
    python scraper.py --threads 20      # if A-Shell still crashes
    python scraper.py --threads 60      # if you want more speed
    python scraper.py --timeout 6       # more lenient
    python scraper.py --out out.txt     # custom output
    python scraper.py --test-url URL    # validate against custom URL

Pure stdlib. Zero installs.
"""

import sys
import re
import time
import socket
import threading
import urllib.request
import urllib.parse
import argparse
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor, as_completed

# ── Colours ───────────────────────────────────────────────────────────────
def _c(code, t): return f"\033[{code}m{t}\033[0m"
GRN = lambda t: _c("32;1", t)
RED = lambda t: _c("31",   t)
CYN = lambda t: _c("36",   t)
DIM = lambda t: _c("2",    t)
BLD = lambda t: _c("1",    t)

# ── 53 sources ────────────────────────────────────────────────────────────
SOURCES = [
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

_PROXY_RE   = re.compile(r"\b(\d{1,3}(?:\.\d{1,3}){3}):(\d{2,5})\b")
_GOOD_CODES = {b"200", b"204", b"301", b"302", b"403"}


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


def scrape_all(sources, pool_size):
    collected = []
    done      = [0]
    lock      = threading.Lock()
    n         = len(sources)

    # Cap scrape pool at pool_size but never more than source count
    workers = min(pool_size, n)

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futs = {pool.submit(_fetch_source, u): u for u in sources}
        for fut in as_completed(futs):
            found = fut.result()
            with lock:
                collected.extend(found)
                done[0] += 1
                print(
                    f"\r  {CYN('scraping')}  {done[0]:>2}/{n}  "
                    f"{GRN(str(len(collected)))} raw  ",
                    end="", flush=True,
                )

    print()
    return set(collected)


# ── Validate — raw socket (fast path) ────────────────────────────────────
def _validate_socket(proxy, timeout):
    """
    Direct TCP + minimal HTTP GET through the proxy.
    Only reads the first 48 bytes — just enough to check the status code.
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
        sock.sendall(
            b"GET http://www.google.com/ HTTP/1.0\r\n"
            b"Host: www.google.com\r\n"
            b"User-Agent: Mozilla/5.0\r\n"
            b"Connection: close\r\n\r\n"
        )
        buf = b""
        while len(buf) < 48:
            chunk = sock.recv(48 - len(buf))
            if not chunk:
                break
            buf += chunk

        if not buf.startswith(b"HTTP/"):
            return False
        parts = buf.split()
        return len(parts) >= 2 and parts[1] in _GOOD_CODES

    except Exception:
        return False
    finally:
        if sock:
            try: sock.close()
            except Exception: pass


# ── Validate — urllib (custom URL path) ──────────────────────────────────
def _validate_urllib(proxy, test_url, timeout):
    proxy_url = f"http://{proxy}"
    handler   = urllib.request.ProxyHandler({"http": proxy_url, "https": proxy_url})
    opener    = urllib.request.build_opener(handler)
    try:
        req = urllib.request.Request(
            test_url,
            headers={"User-Agent": "Mozilla/5.0"}
        )
        with opener.open(req, timeout=timeout) as r:
            # any response (even error codes) means the proxy routed traffic
            return r.status < 600
    except urllib.error.HTTPError as e:
        # proxy worked, target returned an HTTP error — still a live proxy
        return e.code < 600
    except Exception:
        return False


def _validate(proxy, timeout, test_url):
    if test_url:
        return _validate_urllib(proxy, test_url, timeout)
    return _validate_socket(proxy, timeout)


# ── Validate pool ─────────────────────────────────────────────────────────
def validate_all(proxies, timeout, pool_size, out_file, test_url):
    proxy_list = list(proxies)
    total      = len(proxy_list)
    working    = []
    checked    = [0]
    lock       = threading.Lock()
    start_t    = time.time()
    out_fh     = open(out_file, "w")

    pad = len(str(total))

    with ThreadPoolExecutor(max_workers=min(pool_size, total or 1)) as pool:
        futs = {pool.submit(_validate, p, timeout, test_url): p for p in proxy_list}
        for fut in as_completed(futs):
            proxy = futs[fut]
            ok    = fut.result()
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
                    f"{checked[0]:>{pad}}/{total}  "
                    f"{DIM(f'{pct:5.1f}%')}  "
                    f"{GRN(str(len(working)))} working  "
                    f"{DIM(f'{cps:6.1f}/s')}  ",
                    end="", flush=True,
                )

    print()
    out_fh.close()
    return working


# ── Main ──────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description="Axiom proxy scraper — A-Shell safe")
    ap.add_argument("--threads",  type=int,   default=40,
                    help="Thread pool size for both scrape+validate (default 40)")
    ap.add_argument("--timeout",  type=float, default=4,
                    help="Socket timeout per proxy in seconds (default 4)")
    ap.add_argument("--out",      type=str,   default="proxies.txt",
                    help="Output file (default proxies.txt)")
    ap.add_argument("--test-url", type=str,   default=None,
                    help="Custom URL to test through each proxy (optional)")
    args = ap.parse_args()

    print()
    print(BLD("  AXIOM PROXY SCRAPER"))
    print(DIM(
        f"  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}  "
        f"{len(SOURCES)} sources  "
        f"{args.threads} threads  "
        f"{args.timeout}s timeout"
    ))
    print()

    # 1. Scrape — cap at threads so we never exceed A-Shell limit
    scrape_workers = min(args.threads, len(SOURCES))
    print(f"  {BLD('[1/2]')} Scraping {len(SOURCES)} sources  "
          f"{DIM(f'({scrape_workers} threads)')}")
    raw = scrape_all(SOURCES, scrape_workers)
    print(f"  {GRN('→')} {len(raw):,} unique proxies")
    print()

    if not raw:
        print(RED("  ✗ Nothing scraped — check internet."))
        sys.exit(1)

    # ETA estimate
    eta = len(raw) / max(args.threads, 1) * args.timeout
    mode = f"urllib → {args.test_url}" if args.test_url else "raw socket → google.com"
    print(f"  {BLD('[2/2]')} Validating  {DIM(f'{mode}  ~{eta:.0f}s ETA')}")

    working = validate_all(raw, args.timeout, args.threads, args.out, args.test_url)

    # 3. Results
    print()
    if working:
        rate = len(working) / len(raw) * 100
        print(f"  {GRN('✓')} {BLD(str(len(working)))} working  "
              f"{DIM(f'({rate:.1f}% · saved to {args.out})')}")
        print()
        cap = min(15, len(working))
        print(DIM(f"  first {cap}:"))
        for p in working[:cap]:
            print(f"    {CYN(p)}")
        if len(working) > cap:
            print(DIM(f"    … and {len(working) - cap} more in {args.out}"))
    else:
        print(RED("  ✗ No working proxies found."))
        print(DIM("    Try --timeout 8 or --threads 20"))
    print()


if __name__ == "__main__":
    main()
