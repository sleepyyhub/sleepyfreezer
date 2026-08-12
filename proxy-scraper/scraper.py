"""
scraper.py — async socket validation (30x+ faster than threading)

Scraping:  ThreadPoolExecutor  (bounded, A-Shell safe)
Validate:  asyncio             (hundreds of concurrent sockets, no thread overhead)

Usage:
    python scraper.py                      # 40 scrape threads, 150 async, 3s timeout
    python scraper.py --concurrency 300    # more async connections (if OS allows)
    python scraper.py --threads 20         # fewer scrape threads (if A-Shell struggles)
    python scraper.py --timeout 4          # longer timeout
    python scraper.py --out proxies.txt    # output file

Pure stdlib. Zero installs. Python 3.10+
"""

import sys
import re
import time
import socket
import asyncio
import threading
import urllib.request
import argparse
from datetime import datetime
from concurrent.futures import ThreadPoolExecutor

# ── Colours ───────────────────────────────────────────────────────────────
def _c(code, t): return f"\033[{code}m{t}\033[0m"
GRN = lambda t: _c("32;1", t)
RED = lambda t: _c("31",   t)
CYN = lambda t: _c("36",   t)
DIM = lambda t: _c("2",    t)
BLD = lambda t: _c("1",    t)

# ── Sources ───────────────────────────────────────────────────────────────
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
    "https://raw.githubusercontent.com/saschazesiger/Free-Proxies/master/proxies/http.txt",
    "https://raw.githubusercontent.com/im-razvan/proxy_list/main/http.txt",
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

_PROXY_RE      = re.compile(r"\b(\d{1,3}(?:\.\d{1,3}){3}):(\d{2,5})\b")
# CONNECT tunnel to Roblox validates the proxy can actually reach roblox.com:443
_CONNECT_REQ   = (
    b"CONNECT auth.roblox.com:443 HTTP/1.0\r\n"
    b"Host: auth.roblox.com:443\r\n"
    b"User-Agent: Mozilla/5.0\r\n"
    b"\r\n"
)


# ── Scrape (thread pool, bounded) ─────────────────────────────────────────
def _fetch_one(url):
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

    def task(url):
        found = _fetch_one(url)
        with lock:
            collected.extend(found)
            done[0] += 1
            print(
                f"\r  {CYN('scraping')}  {done[0]:>2}/{n}  "
                f"{GRN(str(len(collected)))} raw  ",
                end="", flush=True,
            )

    # setdefaulttimeout ensures TCP-level hangs are killed even if urlopen timeout misses them
    old_timeout = socket.getdefaulttimeout()
    socket.setdefaulttimeout(12)
    try:
        with ThreadPoolExecutor(max_workers=min(pool_size, n)) as pool:
            list(pool.map(task, sources, timeout=n * 2 + 30))
    except Exception:
        pass  # partial results are fine — continue to validation
    finally:
        socket.setdefaulttimeout(old_timeout)

    print()
    return set(collected)


# ── Async validation (raw sockets, no threads) ────────────────────────────
async def _check(ip, port, timeout):
    """CONNECT tunnel to auth.roblox.com:443 — proxy is usable if it returns 200."""
    writer = None
    try:
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(ip, port), timeout=timeout
        )
        writer.write(_CONNECT_REQ)
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


async def validate_async(proxies, timeout, concurrency, out_file):
    sem     = asyncio.Semaphore(concurrency)
    total   = len(proxies)
    start_t = time.time()
    working = []
    checked = [0]
    out_fh  = open(out_file, "w")
    pad     = len(str(total))
    # lock for checked/working mutation (gather runs concurrently)
    alock   = asyncio.Lock()

    async def do_one(proxy):
        try:
            ip, port_s = proxy.rsplit(":", 1)
            port = int(port_s)
            if not (1 <= port <= 65535):
                raise ValueError
        except Exception:
            async with alock:
                checked[0] += 1
            return

        async with sem:
            ok = await _check(ip, port, timeout)

        async with alock:
            checked[0] += 1
            c = checked[0]
            if ok:
                working.append(proxy)
                out_fh.write(proxy + "\n")
                out_fh.flush()

        # print on every hit or every 100 checks
        if ok or c % 100 == 0:
            elapsed = max(time.time() - start_t, 0.001)
            cps     = c / elapsed
            pct     = c / total * 100
            print(
                f"\r  {CYN('validating')}  "
                f"{c:>{pad}}/{total}  "
                f"{DIM(f'{pct:5.1f}%')}  "
                f"{GRN(str(len(working)))} working  "
                f"{DIM(f'{cps:6.0f}/s')}  ",
                end="", flush=True,
            )

    await asyncio.gather(*[do_one(p) for p in proxies])
    print()
    out_fh.close()
    return working


# ── Main ──────────────────────────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser(description="Axiom proxy scraper — async validator")
    ap.add_argument("--threads",     type=int,   default=40,
                    help="Thread pool size for scraping (default 40)")
    ap.add_argument("--concurrency", type=int,   default=150,
                    help="Async socket concurrency for validation (default 150)")
    ap.add_argument("--timeout",     type=float, default=3,
                    help="Socket timeout in seconds (default 3)")
    ap.add_argument("--out",         type=str,   default="proxies.txt",
                    help="Output file (default proxies.txt)")
    args = ap.parse_args()

    print()
    print(BLD("  AXIOM PROXY SCRAPER"))
    print(DIM(
        f"  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}  "
        f"{len(SOURCES)} sources  "
        f"scrape:{args.threads}t  "
        f"validate:{args.concurrency} async  "
        f"{args.timeout}s timeout"
    ))
    print()

    # 1. Scrape
    print(f"  {BLD('[1/2]')} Scraping {len(SOURCES)} sources…")
    raw = scrape_all(SOURCES, args.threads)
    print(f"  {GRN('→')} {len(raw):,} unique proxies")
    print()

    if not raw:
        print(RED("  ✗ Nothing scraped — check internet."))
        sys.exit(1)

    # 2. Validate (asyncio) — Ctrl+C stops cleanly and shows partial results
    eta = len(raw) / max(args.concurrency, 1) * args.timeout
    print(f"  {BLD('[2/2]')} Async validation  "
          f"{DIM(f'{args.concurrency} concurrent · {args.timeout}s timeout · ~{eta:.0f}s ETA')}")
    print(DIM("  (Ctrl+C to stop early and keep what was found)"))
    working = []
    try:
        working = asyncio.run(
            validate_async(list(raw), args.timeout, args.concurrency, args.out)
        )
    except KeyboardInterrupt:
        print(f"\n  {RED('⚡')} Stopped early — reading results from {args.out}…")
        try:
            with open(args.out) as fh:
                working = [ln.strip() for ln in fh if ln.strip()]
        except FileNotFoundError:
            working = []

    # 3. Results
    print()
    if working:
        rate = len(working) / len(raw) * 100 if raw else 0
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
        print(RED("  ✗ No working proxies."))
        print(DIM("    Try --timeout 6 or --concurrency 200"))
    print()


if __name__ == "__main__":
    main()
