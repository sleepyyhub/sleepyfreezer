"""
proxy_scraper.py — scrapes free HTTP proxies from multiple sources,
validates them concurrently, and writes working ones to proxies.txt

Usage:
    python scraper.py                    # scrape + validate, save to proxies.txt
    python scraper.py --timeout 6        # custom timeout (default 7s)
    python scraper.py --threads 200      # parallel validation workers (default 150)
    python scraper.py --test-url URL     # custom validation target
    python scraper.py --out my_file.txt  # custom output file

No external deps — pure stdlib.
"""

import sys
import time
import queue
import threading
import urllib.request
import urllib.error
import urllib.parse
import argparse
import re
from datetime import datetime

# ── Colour helpers (no deps) ───────────────────────────────────────────────
def _c(code, text): return f"\033[{code}m{text}\033[0m"
GREEN  = lambda t: _c("32;1", t)
RED    = lambda t: _c("31",   t)
YELLOW = lambda t: _c("33",   t)
CYAN   = lambda t: _c("36",   t)
DIM    = lambda t: _c("2",    t)
BOLD   = lambda t: _c("1",    t)

# ── Proxy sources ──────────────────────────────────────────────────────────
SOURCES = [
    # GitHub raw lists
    "https://raw.githubusercontent.com/TheSpeedX/PROXY-List/master/http.txt",
    "https://raw.githubusercontent.com/clarketm/proxy-list/master/proxy-list-raw.txt",
    "https://raw.githubusercontent.com/monosans/proxy-list/main/proxies/http.txt",
    "https://raw.githubusercontent.com/ShiftyTR/Proxy-List/master/http.txt",
    "https://raw.githubusercontent.com/sunny9577/proxy-scraper/master/proxies.txt",
    "https://raw.githubusercontent.com/roosterkid/openproxylist/main/HTTPS_RAW.txt",
    "https://raw.githubusercontent.com/mmpx12/proxy-list/master/http.txt",
    "https://raw.githubusercontent.com/mmpx12/proxy-list/master/https.txt",
    "https://raw.githubusercontent.com/prxchk/proxy-list/main/http.txt",
    "https://raw.githubusercontent.com/saisuiu/Lionkings-Http-Proxys-Lists/main/cnfree.txt",
    "https://raw.githubusercontent.com/andigwandi/free-proxy/main/proxy_list.txt",
    "https://raw.githubusercontent.com/Anonym0usWork1221/Free-Proxies/main/proxy_files/http_proxies.txt",
    "https://raw.githubusercontent.com/Anonym0usWork1221/Free-Proxies/main/proxy_files/https_proxies.txt",
    "https://raw.githubusercontent.com/officialputuid/KangProxy/KangProxy/http/http.txt",
    "https://raw.githubusercontent.com/officialputuid/KangProxy/KangProxy/https/https.txt",
    # API endpoints
    "https://api.proxyscrape.com/v2/?request=displayproxies&protocol=http&timeout=5000&country=all&ssl=all&anonymity=all",
    "https://api.proxyscrape.com/v2/?request=displayproxies&protocol=https&timeout=5000&country=all&ssl=all&anonymity=all",
    "https://www.proxy-list.download/api/v1/get?type=http",
    "https://www.proxy-list.download/api/v1/get?type=https",
    "https://hidemy.name/en/proxy-list/?type=h&anon=1234",
]

# ── Regex to pull ip:port from any text ───────────────────────────────────
_PROXY_RE = re.compile(r"\b(\d{1,3}(?:\.\d{1,3}){3}):(\d{2,5})\b")

def _fetch(url: str, timeout: int = 10) -> list[str]:
    """Fetch one source URL, return list of 'ip:port' strings."""
    try:
        req = urllib.request.Request(
            url,
            headers={"User-Agent": "Mozilla/5.0 (compatible; ProxyScraper/2.0)"}
        )
        with urllib.request.urlopen(req, timeout=timeout) as r:
            text = r.read().decode("utf-8", errors="ignore")
        found = _PROXY_RE.findall(text)
        return [f"{ip}:{port}" for ip, port in found]
    except Exception:
        return []


def scrape_all(sources: list[str]) -> set[str]:
    """Fetch all sources concurrently, return deduplicated set of ip:port."""
    results: list[str] = []
    lock = threading.Lock()
    done = [0]

    def fetch_one(url):
        proxies = _fetch(url)
        with lock:
            results.extend(proxies)
            done[0] += 1
            print(f"\r  {CYAN('scraping')}  {done[0]:>3}/{len(sources)} sources  "
                  f"{GREEN(str(len(results)))} raw collected   ",
                  end="", flush=True)

    threads = [threading.Thread(target=fetch_one, args=(u,), daemon=True) for u in sources]
    for t in threads: t.start()
    for t in threads: t.join()
    print()

    unique = set(results)
    return unique


# ── Validation ────────────────────────────────────────────────────────────
def _validate(proxy: str, test_url: str, timeout: int) -> bool:
    """Return True if proxy can reach test_url within timeout seconds."""
    ip_port = proxy.strip()
    proxy_url = f"http://{ip_port}"
    handler  = urllib.request.ProxyHandler({
        "http":  proxy_url,
        "https": proxy_url,
    })
    opener = urllib.request.build_opener(handler)
    try:
        req = urllib.request.Request(
            test_url,
            headers={"User-Agent": "Mozilla/5.0 (compatible; ProxyCheck/1.0)"}
        )
        with opener.open(req, timeout=timeout) as r:
            return r.status == 200
    except Exception:
        return False


def validate_all(
    proxies:   set[str],
    test_url:  str,
    timeout:   int,
    workers:   int,
    out_file:  str,
) -> list[str]:
    """
    Validate all proxies concurrently.
    Prints a live progress line; writes working proxies to out_file as found.
    Returns list of working proxies.
    """
    proxy_list = list(proxies)
    total      = len(proxy_list)
    work_q     = queue.Queue()
    for p in proxy_list:
        work_q.put(p)

    working: list[str] = []
    checked  = [0]
    lock     = threading.Lock()
    start_t  = time.time()
    stop_evt = threading.Event()

    # open output file for streaming writes
    out_fh = open(out_file, "w")

    def worker():
        while not stop_evt.is_set():
            try:
                proxy = work_q.get(timeout=1)
            except queue.Empty:
                break
            ok = _validate(proxy, test_url, timeout)
            with lock:
                checked[0] += 1
                elapsed = time.time() - start_t
                cps     = checked[0] / elapsed if elapsed > 0 else 0
                pct     = checked[0] / total * 100
                if ok:
                    working.append(proxy)
                    out_fh.write(proxy + "\n")
                    out_fh.flush()
                print(
                    f"\r  {CYAN('validating')}  "
                    f"{checked[0]:>{len(str(total))}}/{total}  "
                    f"{DIM(f'{pct:5.1f}%')}  "
                    f"{GREEN(str(len(working)))} working  "
                    f"{DIM(f'{cps:.1f}/s')}   ",
                    end="", flush=True
                )
            work_q.task_done()

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(min(workers, total))]
    for t in threads: t.start()
    for t in threads: t.join()
    print()

    out_fh.close()
    return working


# ── Main ──────────────────────────────────────────────────────────────────
def main():
    parser = argparse.ArgumentParser(description="Proxy scraper + validator")
    parser.add_argument("--timeout",  type=int,   default=7,
                        help="Validation timeout per proxy in seconds (default 7)")
    parser.add_argument("--threads",  type=int,   default=150,
                        help="Parallel validation workers (default 150)")
    parser.add_argument("--test-url", type=str,
                        default="http://httpbin.org/ip",
                        help="URL to test each proxy against (default httpbin.org/ip)")
    parser.add_argument("--out",      type=str,   default="proxies.txt",
                        help="Output file (default proxies.txt)")
    args = parser.parse_args()

    print()
    print(BOLD("  AXIOM PROXY SCRAPER"))
    print(DIM(f"  {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"))
    print()

    # ── SCRAPE ──────────────────────────────────────────────────────────
    print(f"  {BOLD('[ 1/2 ]')} Scraping {len(SOURCES)} sources…")
    raw = scrape_all(SOURCES)
    print(f"  {GREEN('→')} {len(raw):,} unique proxies collected")
    print()

    if not raw:
        print(RED("  ✗ No proxies scraped — check your internet connection."))
        sys.exit(1)

    # ── VALIDATE ────────────────────────────────────────────────────────
    print(f"  {BOLD('[ 2/2 ]')} Validating against {args.test_url}")
    print(f"         {DIM(f'{args.threads} threads  {args.timeout}s timeout')}")
    working = validate_all(
        proxies  = raw,
        test_url = args.test_url,
        timeout  = args.timeout,
        workers  = args.threads,
        out_file = args.out,
    )

    # ── RESULTS ─────────────────────────────────────────────────────────
    print()
    if working:
        rate = len(working) / len(raw) * 100
        print(f"  {GREEN('✓')} {BOLD(str(len(working)))} working proxies  "
              f"{DIM(f'({rate:.1f}% success rate)')}")
        print(f"  {GREEN('✓')} saved to {BOLD(args.out)}")
        print()
        print(f"  {DIM('first 10:')}")
        for p in working[:10]:
            print(f"    {CYAN(p)}")
        if len(working) > 10:
            print(DIM(f"    …and {len(working) - 10} more"))
    else:
        print(RED("  ✗ No working proxies found."))
        print(DIM("    Try --timeout 10 or a different --test-url"))

    print()


if __name__ == "__main__":
    main()
