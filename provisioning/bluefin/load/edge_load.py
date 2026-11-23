#!/usr/bin/env python3
"""Load generator for the Bluefin pilot edge (#179 Phase 4, step 5).

Standard library only. Connects to a given IP while sending the real
hostname as SNI and Host, so the same run works against the rehearsal's
loopback forward and the public edge, before or after DNS exists.

  requests  fixed rate and concurrency against https://<host>/hostname;
            one CSV row per request: start, host, status, latency_ms, error
  transfer  repeated downloads of /data/blob-1g, each checked against
            /data/blob-1g.sha256; one CSV row per download

Run through `mise bluefin:pilot:edge-load`, which fills in the hostnames.
"""
import argparse
import csv
import hashlib
import http.client
import queue
import socket
import ssl
import sys
import threading
import time


class PinnedHTTPSConnection(http.client.HTTPSConnection):
    """HTTPS to a fixed IP, with SNI and certificate name from `sni`."""

    def __init__(self, ip, port, sni, context, timeout):
        super().__init__(sni, port, context=context, timeout=timeout)
        self._ip = ip
        self._sni = sni
        self._ctx = context

    def connect(self):
        sock = socket.create_connection((self._ip, self.port), self.timeout)
        self.sock = self._ctx.wrap_socket(sock, server_hostname=self._sni)


def context(insecure):
    ctx = ssl.create_default_context()
    if insecure:
        # Staging and the rehearsal's self-signed certificates do not chain
        # to a public root; the probes judge reachability, not trust.
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


def run_requests(a, writer):
    ctx = context(a.insecure)
    slots = queue.Queue()
    lock = threading.Lock()
    stop = time.monotonic() + a.duration
    counts = {"ok": 0, "5xx": 0, "conn": 0, "other": 0}
    latencies = []

    def worker(i):
        host = a.hosts[i % len(a.hosts)]
        conn = None
        while True:
            due = slots.get()
            if due is None:
                return
            delay = due - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            start = time.time()
            t0 = time.monotonic()
            status, err = "", ""
            try:
                if conn is None:
                    conn = PinnedHTTPSConnection(a.ip, a.port, host, ctx, a.timeout)
                conn.request("GET", "/hostname", headers={"Host": host})
                resp = conn.getresponse()
                resp.read()
                status = resp.status
                if resp.will_close:
                    conn.close()
                    conn = None
            except (OSError, http.client.HTTPException) as e:
                err = type(e).__name__
                if conn is not None:
                    conn.close()
                conn = None
            ms = (time.monotonic() - t0) * 1000
            with lock:
                writer.writerow([f"{start:.3f}", host, status, f"{ms:.1f}", err])
                if err:
                    counts["conn"] += 1
                elif 200 <= status < 400:
                    counts["ok"] += 1
                    latencies.append(ms)
                elif status >= 500:
                    counts["5xx"] += 1
                else:
                    counts["other"] += 1

    threads = [threading.Thread(target=worker, args=(i,), daemon=True) for i in range(a.concurrency)]
    for t in threads:
        t.start()
    interval = 1.0 / a.rate
    due = time.monotonic()
    while due < stop:
        # Bounded backlog: if every worker is stuck, the schedule is not
        # allowed to pile up thousands of overdue requests.
        while slots.qsize() > a.concurrency * 4:
            time.sleep(interval)
        slots.put(due)
        due += interval
    for _ in threads:
        slots.put(None)
    for t in threads:
        t.join()
    total = sum(counts.values())
    bad = counts["5xx"] + counts["conn"]
    latencies.sort()
    pct = lambda p: latencies[min(len(latencies) - 1, int(len(latencies) * p))] if latencies else float("nan")
    print(f"requests: {total}, ok {counts['ok']}, 5xx {counts['5xx']}, connection errors {counts['conn']}, "
          f"other {counts['other']}; error rate {100.0 * bad / max(total, 1):.3f}% (gate: < 0.1%); "
          f"latency p50 {pct(0.5):.0f} ms, p95 {pct(0.95):.0f} ms")
    return 0 if total and bad * 1000 < total else 1


def run_transfer(a, writer):
    ctx = context(a.insecure)
    host = a.hosts[0]
    stop = time.monotonic() + a.duration
    ok = bad = 0
    while time.monotonic() < stop:
        start = time.time()
        t0 = time.monotonic()
        got, n, err, match = "", 0, "", False
        try:
            conn = PinnedHTTPSConnection(a.ip, a.port, host, ctx, a.timeout)
            conn.request("GET", "/data/blob-1g.sha256", headers={"Host": host})
            want = conn.getresponse().read().decode().strip()
            conn.request("GET", "/data/blob-1g", headers={"Host": host})
            resp = conn.getresponse()
            h = hashlib.sha256()
            while True:
                chunk = resp.read(1 << 20)
                if not chunk:
                    break
                h.update(chunk)
                n += len(chunk)
            got = h.hexdigest()
            match = resp.status == 200 and got == want and len(want) == 64
            conn.close()
        except (OSError, http.client.HTTPException) as e:
            err = type(e).__name__
        secs = time.monotonic() - t0
        mbit = n * 8 / secs / 1e6 if secs > 0 else 0.0
        writer.writerow([f"{start:.3f}", host, n, f"{secs:.1f}", f"{mbit:.1f}", "yes" if match else "no", err])
        ok, bad = (ok + 1, bad) if match else (ok, bad + 1)
        print(f"download: {n} bytes in {secs:.0f} s, {mbit:.1f} Mbit/s, checksum {'match' if match else 'MISMATCH'} {err}",
              flush=True)
    print(f"transfers: {ok} good, {bad} bad")
    return 0 if ok and not bad else 1


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("mode", choices=["requests", "transfer"])
    p.add_argument("--ip", required=True, help="address to connect to")
    p.add_argument("--port", type=int, default=443)
    p.add_argument("--hosts", required=True, help="comma-separated hostnames (SNI and Host)")
    p.add_argument("--rate", type=float, default=1.0, help="requests: requests per second, total")
    p.add_argument("--concurrency", type=int, default=1, help="requests: parallel connections")
    p.add_argument("--duration", type=float, required=True, help="seconds")
    p.add_argument("--timeout", type=float, default=10.0, help="per request, seconds (transfer: per socket read)")
    p.add_argument("--insecure", action="store_true", help="do not verify the certificate (staging, self-signed)")
    p.add_argument("--csv", required=True, help="output CSV path")
    a = p.parse_args()
    a.hosts = [h for h in a.hosts.split(",") if h]
    if a.mode == "requests" and (a.rate <= 0 or a.concurrency < 1):
        p.error("--rate must be > 0 and --concurrency >= 1")
    with open(a.csv, "w", newline="") as f:
        w = csv.writer(f)
        if a.mode == "requests":
            w.writerow(["start", "host", "status", "latency_ms", "error"])
            rc = run_requests(a, w)
        else:
            w.writerow(["start", "host", "bytes", "seconds", "mbit_s", "checksum_ok", "error"])
            rc = run_transfer(a, w)
    sys.exit(rc)


if __name__ == "__main__":
    main()
