#!/usr/bin/env python3
"""Ask the platform-sync daemons for a run and wait for the result.

Runs inside the GitHub runner container, which can do exactly two things on
the host: drop a request file and read status files. Standard library only.
"""
import argparse
import json
import os
import sys
import time

GB = 1e9


def fmt_bytes(n):
    return "–" if n is None else (f"{n / GB:.2f} GB" if n >= 1e8 else f"{n / 1e6:.1f} MB")


def fmt_duration(s):
    return "–" if s is None else f"{int(s) // 3600}h {int(s) % 3600 // 60:02d}m"


def read(path):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def progress_line(net, st):
    if not st:
        return f"{net}: no status yet"
    run = st.get("run") or {}
    bits = [f"{net}: {st.get('phase')}"]
    if st.get("height") is not None and st.get("referenceHeight"):
        bits.append(f"{st['height']:,}/{st['referenceHeight']:,}")
    if st.get("blocksPerSecond"):
        bits.append(f"{st['blocksPerSecond']} blocks/s")
    if st.get("etaSeconds") is not None:
        bits.append(f"about {fmt_duration(st['etaSeconds'])} left")
    if (run.get("bytes") or {}).get("platformRx") is not None:
        bits.append(f"{fmt_bytes(run['bytes']['platformRx'])} received")
    return ", ".join(bits)


def summary_row(net, r):
    img = r.get("image") or {}
    b = r.get("bytes") or {}
    rev = (img.get("revision") or "")[:10]
    total = sum(v for k, v in b.items() if k in ("platformRx", "coreRx", "image")) if b else None
    return (f"| {net} | **{r.get('result')}** | `{rev or img.get('ref') or r.get('requestedImage')}` | "
            f"{r.get('height') or '–'} | {fmt_duration(r.get('durationSeconds'))} | {fmt_bytes(total)} | "
            f"{r.get('reason') or ''} |")


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--spool", default="/spool")
    p.add_argument("--network", action="append", required=True, choices=("testnet", "mainnet"))
    p.add_argument("--image", default="auto")
    p.add_argument("--tenderdash-image", default="")
    p.add_argument("--force", action="store_true")
    p.add_argument("--run-id", default=os.environ.get("GITHUB_RUN_ID", "local") + "-"
                   + os.environ.get("GITHUB_RUN_ATTEMPT", "1"))
    p.add_argument("--timeout-hours", type=float, default=21.5)
    p.add_argument("--report-minutes", type=float, default=10)
    a = p.parse_args()

    ids = {}
    for net in dict.fromkeys(a.network):
        rid = f"gh-{a.run_id}-{net}"
        req = {"id": rid, "network": net, "image": a.image or "auto", "force": a.force}
        if a.tenderdash_image:
            req["tenderdash_image"] = a.tenderdash_image
        tmp = os.path.join(a.spool, "requests", f".{rid}.tmp")
        with open(tmp, "w") as f:
            json.dump(req, f)
        os.replace(tmp, os.path.join(a.spool, "requests", f"{rid}.json"))
        ids[net] = rid
        print(f"requested {net}: {rid} (image {req['image']})", flush=True)

    results, deadline, last_report = {}, time.time() + a.timeout_hours * 3600, 0
    while len(results) < len(ids) and time.time() < deadline:
        for net, rid in ids.items():
            if net not in results:
                r = read(os.path.join(a.spool, "status", "results", f"{rid}.json"))
                if r and r.get("result"):
                    results[net] = r
                    print(f"{net}: {r['result']}" + (f" ({r['reason']})" if r.get("reason") else ""), flush=True)
        if time.time() - last_report > a.report_minutes * 60:
            last_report = time.time()
            for net in ids:
                if net not in results:
                    print(progress_line(net, read(os.path.join(a.spool, "status", f"{net}.json"))), flush=True)
        time.sleep(20)

    lines = ["| Network | Result | Revision | Height | Replay time | Data received | Note |",
             "|---|---|---|---|---|---|---|"]
    for net in ids:
        lines.append(summary_row(net, results.get(net) or {"result": "no result", "reason": "timed out waiting"}))
    text = "\n".join(lines)
    print(text)
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            f.write("## Platform sync\n\n" + text + "\n")
    ok = all((results.get(n) or {}).get("result") in ("passed", "skipped") for n in ids)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
