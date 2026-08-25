#!/usr/bin/env python3
"""
Turn clickhouse-benchmark JSON results into a markdown table.

Usage:
    report.py <result-dir>                  # single run
    report.py --compare <dir-before> <dir-after>
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path

QUERY_NAMES = [
    "point lookup",
    "partition scan",
    "full count",
]


def load_run(result_dir: Path) -> dict:
    run = {"queries": {}, "events": {}}
    for i, name in enumerate(QUERY_NAMES, start=1):
        path = result_dir / f"query_{i}.json"
        if not path.exists():
            continue
        data = json.loads(path.read_text())
        # clickhouse-benchmark emits one JSON object per line, last one is the summary.
        rows = [line for line in data.splitlines()] if isinstance(data, str) else []
        stats = json.loads(rows[-1]) if rows else {}
        run["queries"][name] = stats
    events_path = result_dir / "events.jsonl"
    if events_path.exists():
        for line in events_path.read_text().splitlines():
            row = json.loads(line)
            run["events"][row["event"]] = row["value"]
    return run


def fmt_ms(value) -> str:
    if value is None:
        return "-"
    return f"{float(value):.2f} ms"


def print_run(label: str, run: dict) -> None:
    print(f"## {label}")
    print()
    print("| Query | QPS | p50 | p95 |")
    print("|---|---|---|---|")
    for name, stats in run["queries"].items():
        print(
            f"| {name} | {stats.get('queries_per_second', '-'):.2f} "
            f"| {fmt_ms(stats.get('quantiles', {}).get('0.50'))} "
            f"| {fmt_ms(stats.get('quantiles', {}).get('0.95'))} |"
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
            b_p50 = b.get("quantiles", {}).get("0.50")
            a_p50 = a.get("quantiles", {}).get("0.50")
            b_qps = b.get("queries_per_second")
            a_qps = a.get("queries_per_second")
            delta = "-"
            if b_p50 is not None and a_p50 is not None and float(b_p50) > 0:
                delta = f"{(float(a_p50) / float(b_p50) - 1) * 100:+.1f}%"
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
