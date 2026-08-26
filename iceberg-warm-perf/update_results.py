#!/usr/bin/env python3
"""
Append dated sections to iceberg-warm-perf/RESULTS.md from result dirs
produced by run_benchmark_rest.sh / run_benchmark.sh.

Usage:
    update_results.py <results-dir>...     # one section per directory
    update_results.py --all <base-dir>     # pairs before-*/after-* under <base-dir>
"""

from __future__ import annotations

import argparse
import datetime
import subprocess
from pathlib import Path

from report import QUERY_NAMES, load_run, pct


def git_sha() -> str:
    try:
        return subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()[:8]
    except Exception:
        return "unknown"


def fmt_qps(value) -> str:
    return "-" if value is None else f"{value:.2f}"


def section(label: str, run: dict) -> str:
    lines = [f"### {label} ({datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%d %H:%M')} UTC, `{git_sha()}`)", ""]
    lines.append("| Query | QPS | p50 | p95 |")
    lines.append("|---|---|---|---|")
    for name in QUERY_NAMES:
        stats = run["queries"].get(name, {})
        lines.append(
            f"| {name} | {fmt_qps(stats.get('qps'))} "
            f"| {('-' if pct(stats, 50.0) is None else f'{pct(stats, 50.0) * 1000:.2f} ms')} "
            f"| {('-' if pct(stats, 95.0) is None else f'{pct(stats, 95.0) * 1000:.2f} ms')} |"
        )
    if run.get("stress") is not None:
        lines.append("")
        lines.append(
            f"Stress (point lookup, sustained): {run['stress']:.2f} QPS"
            + ("" if run.get("stress_failures") is None else f", {run['stress_failures']} failed queries")
        )
    lines.append("")
    return "\n".join(lines)


def append_section(results_file: Path, text: str) -> None:
    results_file.parent.mkdir(parents=True, exist_ok=True)
    with open(results_file, "a", encoding="utf-8") as f:
        f.write(text)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dirs", nargs="*", help="result directories")
    parser.add_argument("--all", metavar="BASE", help="append a section per before-*/after-* pair under BASE")
    parser.add_argument("--output", default="iceberg-warm-perf/RESULTS.md", help="results file (appended)")
    args = parser.parse_args()

    results_file = Path(args.output)
    if args.all:
        base = Path(args.all)
        for before in sorted(base.glob("before-*")):
            suffix = before.name.removeprefix("before-")
            after = base / f"after-{suffix}"
            if not after.exists():
                continue
            text = f"## Comparison (concurrency {suffix})\n\n"
            text += "### Before (master)\n\n"
            text += section(f"before", load_run(before))
            text += "### After (validation)\n\n"
            text += section(f"after", load_run(after))
            append_section(results_file, text)
        print(f"appended to {results_file}")
        return

    for directory in args.dirs:
        append_section(results_file, section(directory, load_run(Path(directory))))
    print(f"appended to {results_file}")


if __name__ == "__main__":
    main()
