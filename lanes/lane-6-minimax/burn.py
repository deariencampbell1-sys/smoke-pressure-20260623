#!/usr/bin/env python3
"""Sustained SHA-256 burn-in: keeps CPUs hot for BURN_SEC seconds across BURN_WORKERS threads.

Each worker gets its OWN 1 MiB buffer (bytearray) so the buffer-protocol lock
isn't shared. Worker loop: hash, fold digest back into buffer, repeat. On exit,
writes a JSON summary to BURN_OUT with per-worker iteration counts and a
representative digest prefix. Pure CPU + a small amount of allocation; no IO.
"""
import os
import sys
import json
import time
import hashlib
import threading

BURN_SEC = int(os.environ.get("BURN_SEC", "300"))
BURN_WORKERS = int(os.environ.get("BURN_WORKERS", "8"))
BURN_OUT = os.environ.get("BURN_OUT", "/tmp/burnin.json")

# 1 MiB zero buffer — each thread mutates its own copy so the GIL + buffer
# protocol don't fight across workers.
def make_buf() -> bytearray:
    return bytearray(1024 * 1024)


def worker(idx: int, stop_at: float, counters: list) -> None:
    """Run until stop_at wall clock, hashing a per-thread buffer over and over."""
    n = 0
    digest = b""
    h = hashlib.sha256
    buf = make_buf()
    while True:
        if time.perf_counter() >= stop_at:
            break
        digest = h(buf).digest()
        # Mix the digest back into the buffer so each iteration is real work
        for j in range(0, 64, 8):
            buf[j: j + 8] = digest[j: j + 8]
        n += 1
    counters[idx] = (n, digest[:8].hex())


def main() -> int:
    started = time.perf_counter()
    stop_at = started + BURN_SEC
    counters: list = [None] * BURN_WORKERS
    threads = [
        threading.Thread(target=worker, args=(i, stop_at, counters), name=f"burn-{i}")
        for i in range(BURN_WORKERS)
    ]
    for t in threads:
        t.start()
    last_print = started
    while any(t.is_alive() for t in threads):
        time.sleep(0.5)
        now = time.perf_counter()
        if now - last_print >= 15.0:
            print(f"[burn] t={now - started:.1f}s/{BURN_SEC}s iters_so_far=0", flush=True)
            last_print = now
    for t in threads:
        t.join()
    elapsed = time.perf_counter() - started
    total = sum(c[0] for c in counters)
    rate = total / elapsed / 1_000_000.0
    summary = {
        "target_sec": BURN_SEC,
        "workers": BURN_WORKERS,
        "elapsed_sec": round(elapsed, 3),
        "total_iterations": total,
        "rate_m_per_sec": round(rate, 2),
        "per_worker": [
            {"worker": i, "iterations": c[0], "digest_prefix": c[1]}
            for i, c in enumerate(counters)
        ],
    }
    with open(BURN_OUT, "w") as f:
        json.dump(summary, f, indent=2)
    print(f"burn-in done {elapsed:.1f}s, {rate:.1f}M sha256/sec aggregate across {BURN_WORKERS} threads", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
