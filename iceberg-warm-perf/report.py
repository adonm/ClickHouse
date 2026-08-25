#!/usr/bin/env python3
"""
Turn clickhouse-benchmark text output into a markdown table.

Usage:
    report.py <result-dir>                  # single run
    report.py --compare <dir-before> <dir-after>
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

QUERY_NAMES = [
    "point lookup",
    "partition scan",
    "full count",
]

QPS_RE = re.compile(r"QPS:\s*([0-9.]+)")
PCT_RE = re.compile(r"^\s*([0-9.]+)%\s+([0-9.]+)\s*sec")


def load_run(result_dir: Path) -> dict:
    run = {"queries": {}, "events": {}}
    for i, name in enumerate(QUERY_NAMES, start=1):
        path = result_dir / f"query_{i}.txt"
        if not path.exists():
            continue
        text = path.read_text()
        stats = {"qps": None, "percentiles": {}}
        m = QPS_RE.search(text)
        if m:
            stats["qps"] = float(m.group(1))
        for line in text.splitlines():
            m = PCT_RE.match(line)
            if m:
                stats["percentiles"][float(m.group(1))] = float(m.group(2))
        run["queries"][name] = stats
    events_path = result_dir / "events.jsonl"
    if events_path.exists():
        for line in events_path.read_text().splitlines():
            row = json.loads(line)
            run["events"][row["event"]] = row["value"]
    return run


def pct(stats: dict, wanted: float):
    percentiles = stats.get("percentiles", {})
    if wanted in percentiles:
        return percentiles[wanted]
    if not percentiles:
        return None
    # nearest available percentile
    return min(percentiles.items(), key=lambda kv: abs(kv[0] - wanted))[1]


def fmt_ms(value) -> str:
    if value is None:
        return "-"
    return f"{float(value) * 1000:.2f} ms"


def print_run(label: str, run: dict) -> None:
    print(f"## {label}")
    print()
    print("| Query | QPS | p50 | p95 |")
    print("|---|---|---|---|")
    for name, stats in run["queries"].items():
        qps = stats.get("qps")
        print(
            f"| {name} | {qps if qps is None else f'{qps:.2f}'} "
            f"| {fmt_ms(pct(stats, 50.0))} "
            f"| {fmt_ms(pct(stats, 95.0))} |"
        )
    print()
    if run["events"]:
        print("| Event | Value |")
        print("|---|---|")
        for event, value in sorted(run["events"].items()):
            print(f"| `{event}` | {value} |")
        print()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dir", nargs="+", help="result directories")
    parser.add_argument("--compare", action="store_true", help="compare two directories")
    args = parser.parse_args()

    if args.compare:
        if len(args.dir) != 2:
            parser.error("--compare needs exactly two directories")
        before = load_run(Path(args.dir[0]))
        after = load_run(Path(args.dir[1]))
        print("# Warm-perf comparison")
        print()
        print("| Query | before p50 | after p50 | delta | before QPS | after QPS |")
        print("|---|---|---|---|---|---|")
        for name in QUERY_NAMES:
            b = before["queries"].get(name, {})
            a = after["queries"].get(name, {})
            b_p50 = pct(b, 50.0)
            a_p50 = pct(a, 50.0)
            b_qps = b.get("qps")
            a_qps = a.get("qps")
            delta = "-"
            if b_p50 and a_p50:
                delta = f"{(a_p50 / b_p50 - 1) * 100:+.1f}%"
            print(
                f"| {name} | {fmt_ms(b_p50)} | {fmt_ms(a_p50)} | {delta} "
                f"| {b_qps if b_qps is None else f'{b_qps:.2f}'} "
                f"| {a_qps if a_qps is None else f'{a_qps:.2f}'} |"
            )
        print()
        print("| Event | before | after |")
        print("|---|---|---|")
        for event in sorted(set(before["events"]) | set(after["events"])):
            print(f"| `{event}` | {before['events'].get(event, 0)} | {after['events'].get(event, 0)} |")
    else:
        for directory in args.dir:
            print_run(directory, load_run(Path(directory)))


if __name__ == "__main__":
    main()
