#!/usr/bin/env python3
"""Map a raw benchmark run into the dashboard's canonical data files.

A benchmark run (the C++ client or the siege sweep) writes a raw, siege-compatible
JSON results file under `benchmark_results/`. The dashboard, however, renders from
the canonical `webapp/data/cpp_data.json` (C++ client) and `webapp/data/configs.json`
(siege, four deployment configurations). This script bridges the two: it reads a raw
results file, maps each row into the dashboard's point schema, replaces only the
`data` array of the matching target (preserving name/color/comment), and then runs
`sync_dashboard_data.py` so the inline `CONFIGS` / `CPP_RESULTS` in `benchmark.html`
are regenerated.

It never fabricates or mixes cross-engine numbers: one raw run updates exactly one
target (the C++ dataset, or a single named entry in configs.json).

Field mapping (raw -> dashboard point):
    concurrency        -> concurrency
    transactions       -> requests
    elapsed_time       -> elapsed
    transaction_rate   -> qps
    p50_latency_ms     -> p50            (C++ only)
    p95_latency_ms     -> p95            (C++ only)
    p99_latency_ms     -> p99            (C++ only)
    availability       -> availability   (C++ only)

Usage:
    python3 update_dashboard_from_run.py benchmark_results/cpp_results.json
    python3 update_dashboard_from_run.py benchmark_results/siege_results.json
    python3 update_dashboard_from_run.py siege_results.json --tool siege --config-name "Standalone"
    python3 update_dashboard_from_run.py cpp_results.json --dry-run
    python3 update_dashboard_from_run.py siege_results.json --no-sync
"""

import argparse
import json
import os
import subprocess
import sys

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
DATA_DIR = os.path.normpath(os.path.join(SCRIPT_DIR, "..", "webapp", "data"))
CONFIGS_JSON = os.path.join(DATA_DIR, "configs.json")
CPP_JSON = os.path.join(DATA_DIR, "cpp_data.json")
SYNC_SCRIPT = os.path.join(SCRIPT_DIR, "sync_dashboard_data.py")

# Raw fields every run must carry to produce a dashboard point.
REQUIRED_RAW_FIELDS = ("concurrency", "transactions", "elapsed_time", "transaction_rate")
# Extra raw fields the C++ client emits (latency percentiles + availability).
CPP_RAW_FIELDS = ("p50_latency_ms", "p95_latency_ms", "p99_latency_ms", "availability")


def fail(message):
    print(f"Error: {message}", file=sys.stderr)
    sys.exit(1)


def load_raw_results(path):
    """Load the raw run file and return its non-empty `results` list."""
    if not os.path.isfile(path):
        fail(f"raw results file not found: {path}")
    try:
        with open(path) as f:
            doc = json.load(f)
    except (json.JSONDecodeError, OSError) as exc:
        fail(f"could not read JSON from {path}: {exc}")

    results = doc.get("results")
    if not isinstance(results, list) or not results:
        fail(f"{path} has no 'results' array, or it is empty.")
    return doc, results


def detect_tool(doc, results):
    """Auto-detect the producing tool from a raw run.

    The C++ client tags the file with `benchmark_tool: cpp_*` and emits latency
    percentiles per row; siege does neither.
    """
    tool = str(doc.get("benchmark_tool", "")).lower()
    if "cpp" in tool or "p50_latency_ms" in results[0]:
        return "cpp"
    return "siege"


def map_points(results, include_cpp_fields):
    """Map raw rows to dashboard points, sorted ascending by measured concurrency."""
    points = []
    for i, r in enumerate(results):
        missing = [k for k in REQUIRED_RAW_FIELDS if k not in r]
        if missing:
            fail(f"results[{i}] is missing required field(s): {', '.join(missing)}")
        point = {
            "concurrency": r["concurrency"],
            "requests": r["transactions"],
            "elapsed": r["elapsed_time"],
            "qps": r["transaction_rate"],
        }
        if include_cpp_fields:
            missing_cpp = [k for k in CPP_RAW_FIELDS if k not in r]
            if missing_cpp:
                fail(
                    f"results[{i}] is missing C++ field(s): {', '.join(missing_cpp)}. "
                    f"Pass --tool siege if this is a siege run."
                )
            point["p50"] = r["p50_latency_ms"]
            point["p95"] = r["p95_latency_ms"]
            point["p99"] = r["p99_latency_ms"]
            point["availability"] = r["availability"]
        points.append(point)
    points.sort(key=lambda p: p["concurrency"])
    return points


def load_json_file(path, label):
    if not os.path.isfile(path):
        fail(f"canonical {label} not found: {path}")
    try:
        with open(path) as f:
            return json.load(f)
    except (json.JSONDecodeError, OSError) as exc:
        fail(f"could not read {path}: {exc}")


def write_json_file(path, payload):
    with open(path, "w") as f:
        json.dump(payload, f, indent=2)
        f.write("\n")


def peak_qps(points):
    best = max(points, key=lambda p: p["qps"])
    return best["qps"], best["concurrency"]


def update_cpp(points, dry_run):
    """Replace the `data` array in cpp_data.json, preserving all other fields."""
    data = load_json_file(CPP_JSON, "cpp_data.json")
    target_desc = f"{os.path.relpath(CPP_JSON, SCRIPT_DIR)} (name: {data.get('name')!r})"
    if dry_run:
        return target_desc
    data["data"] = points
    write_json_file(CPP_JSON, data)
    return target_desc


def update_siege(points, config_name, dry_run):
    """Replace the `data` array of one named entry in configs.json."""
    data = load_json_file(CONFIGS_JSON, "configs.json")
    configs = data.get("configs")
    if not isinstance(configs, list) or not configs:
        fail(f"{CONFIGS_JSON} has no 'configs' array.")

    names = [c.get("name") for c in configs]
    match = next((c for c in configs if c.get("name") == config_name), None)
    if match is None:
        fail(
            f"config name {config_name!r} not found in configs.json. "
            f"Available: {', '.join(repr(n) for n in names)}"
        )

    target_desc = f"{os.path.relpath(CONFIGS_JSON, SCRIPT_DIR)} (config: {config_name!r})"
    if dry_run:
        return target_desc
    match["data"] = points
    write_json_file(CONFIGS_JSON, data)
    return target_desc


def run_sync():
    """Regenerate the dashboard's inline data from the canonical files."""
    if not os.path.isfile(SYNC_SCRIPT):
        fail(f"sync script not found: {SYNC_SCRIPT}")
    result = subprocess.run(
        [sys.executable, SYNC_SCRIPT],
        cwd=SCRIPT_DIR,
        capture_output=True,
        text=True,
    )
    if result.stdout:
        print(result.stdout.rstrip())
    if result.returncode != 0:
        if result.stderr:
            print(result.stderr.rstrip(), file=sys.stderr)
        fail("sync_dashboard_data.py failed; benchmark.html was not updated.")


def parse_args():
    parser = argparse.ArgumentParser(
        description="Map a raw benchmark run into the dashboard's canonical data files."
    )
    parser.add_argument("raw_results", help="Path to a raw benchmark_results/*.json file.")
    parser.add_argument(
        "--tool",
        choices=["auto", "siege", "cpp"],
        default="auto",
        help="Producing tool (default: auto-detect from the file).",
    )
    parser.add_argument(
        "--config-name",
        default="Standalone",
        help="siege only: which configs.json entry to update (default: 'Standalone').",
    )
    parser.add_argument(
        "--no-sync",
        action="store_true",
        help="Update the data file(s) but skip running sync_dashboard_data.py.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the mapped points and target, but write nothing.",
    )
    return parser.parse_args()


def main():
    args = parse_args()

    doc, results = load_raw_results(args.raw_results)
    tool = detect_tool(doc, results) if args.tool == "auto" else args.tool
    points = map_points(results, include_cpp_fields=(tool == "cpp"))

    if tool == "cpp":
        target_desc = update_cpp(points, args.dry_run)
    else:
        target_desc = update_siege(points, args.config_name, args.dry_run)

    qps, conc = peak_qps(points)
    print(f"Tool:    {tool}{' (auto-detected)' if args.tool == 'auto' else ''}")
    print(f"Source:  {os.path.relpath(args.raw_results)}")
    print(f"Target:  {target_desc}")
    print(f"Points:  {len(points)}  |  peak {qps:.2f} QPS @ concurrency {conc:.2f}")

    if args.dry_run:
        print("\n--dry-run: no files written. Mapped points:")
        print(json.dumps(points, indent=2))
        return

    if args.no_sync:
        print("\n--no-sync: data file updated; run sync_dashboard_data.py to refresh benchmark.html.")
        return

    print()
    run_sync()
    print("\nDone. Reload benchmark.html to see the updated dashboard.")


if __name__ == "__main__":
    main()
