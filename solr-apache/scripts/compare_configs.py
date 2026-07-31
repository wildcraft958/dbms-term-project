#!/usr/bin/env python3
"""
compare_configs.py — Multi-Configuration Benchmark Comparison
Generates comparison charts from the benchmark data across all 4 Solr configurations.
"""

import os
import json
import matplotlib.pyplot as plt
import matplotlib
matplotlib.use('Agg')
import numpy as np
from datetime import datetime

# Benchmark data is loaded from the canonical dataset (single source of truth),
# shared with the dashboard. Regenerate that file's consumers via sync_dashboard_data.py.
def load_configs():
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.normpath(os.path.join(here, "..", "webapp", "data", "configs.json"))
    try:
        with open(path) as f:
            data = json.load(f)["configs"]
    except FileNotFoundError:
        raise SystemExit(f"Error: canonical dataset not found at {path}")
    configs = {}
    for c in data:
        configs[c["name"]] = {
            "color": c["color"],
            "data": [(r["concurrency"], r["requests"], r["elapsed"], r["qps"]) for r in c["data"]],
        }
    return configs


CONFIGS = load_configs()

def create_all_charts(output_dir):
    os.makedirs(output_dir, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

    # Use dark background
    plt.style.use('dark_background')
    plt.rcParams.update({
        'font.family': 'sans-serif',
        'font.size': 11,
        'axes.facecolor': '#1a1a2e',
        'figure.facecolor': '#0f0f1a',
        'grid.color': (1.0, 1.0, 1.0, 0.06),
    })

    # 1. Combined QPS vs Concurrency
    fig, ax = plt.subplots(figsize=(12, 7))
    for name, config in CONFIGS.items():
        concurrency = [d[0] for d in config["data"]]
        qps = [d[3] for d in config["data"]]
        ax.plot(concurrency, qps, 'o-', color=config["color"],
                linewidth=2, markersize=5, label=name.replace('\n', ' '), alpha=0.9)
    ax.set_xlabel('Measured Concurrency', fontsize=13)
    ax.set_ylabel('Queries Per Second (QPS)', fontsize=13)
    ax.set_title('QPS vs Concurrency — All Configurations', fontsize=16, fontweight='bold', pad=15)
    ax.legend(loc='upper right', framealpha=0.8)
    ax.grid(True, alpha=0.15)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/comparison_qps_{timestamp}.png", dpi=150, bbox_inches='tight')
    plt.close()
    print(f"  Saved: comparison_qps_{timestamp}.png")

    # 2. Peak QPS bar comparison
    fig, ax = plt.subplots(figsize=(10, 6))
    names = [n.replace('\n', ' ') for n in CONFIGS.keys()]
    colors = [c["color"] for c in CONFIGS.values()]
    peaks = [max(d[3] for d in c["data"]) for c in CONFIGS.values()]

    bars = ax.bar(range(len(names)), peaks, color=colors, alpha=0.8,
                  edgecolor=colors, linewidth=2, width=0.6)
    for bar, peak in zip(bars, peaks):
        ax.text(bar.get_x() + bar.get_width()/2., bar.get_height() + 50,
                f'{peak:,.0f}', ha='center', va='bottom', fontweight='bold', fontsize=12, color='white')

    ax.set_xticks(range(len(names)))
    ax.set_xticklabels(names, fontsize=10)
    ax.set_ylabel('Peak QPS', fontsize=13)
    ax.set_title('Peak QPS by Configuration', fontsize=16, fontweight='bold', pad=15)
    ax.grid(True, axis='y', alpha=0.15)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/comparison_peak_{timestamp}.png", dpi=150, bbox_inches='tight')
    plt.close()
    print(f"  Saved: comparison_peak_{timestamp}.png")

    # 3. Standalone detailed scaling curve
    sa_name = next((n for n in CONFIGS if n.startswith("Standalone")), None)
    if sa_name is None:
        raise SystemExit("Error: no 'Standalone' configuration found in canonical dataset")
    sa = CONFIGS[sa_name]
    concurrency = [d[0] for d in sa["data"]]
    qps = [d[3] for d in sa["data"]]

    fig, ax = plt.subplots(figsize=(12, 6))
    ax.fill_between(concurrency, qps, alpha=0.15, color='#22c55e')
    ax.plot(concurrency, qps, 'o-', color='#22c55e', linewidth=2.5, markersize=5)

    # Annotate peak
    peak_idx = qps.index(max(qps))
    ax.annotate(f'Peak: {qps[peak_idx]:,.0f} QPS',
                xy=(concurrency[peak_idx], qps[peak_idx]),
                xytext=(concurrency[peak_idx]+10, qps[peak_idx]+200),
                fontsize=11, fontweight='bold', color='#22c55e',
                arrowprops=dict(arrowstyle='->', color='#22c55e', lw=1.5))

    ax.set_xlabel('Measured Concurrency', fontsize=13)
    ax.set_ylabel('Queries Per Second', fontsize=13)
    ax.set_title('Standalone Solr — QPS Scaling Curve', fontsize=16, fontweight='bold', pad=15)
    ax.grid(True, alpha=0.15)
    plt.tight_layout()
    plt.savefig(f"{output_dir}/standalone_scaling_{timestamp}.png", dpi=150, bbox_inches='tight')
    plt.close()
    print(f"  Saved: standalone_scaling_{timestamp}.png")

    # 4. Summary markdown
    with open(f"{output_dir}/comparison_summary_{timestamp}.md", 'w') as f:
        f.write(f"# Multi-Configuration Benchmark Comparison\n\n")
        f.write(f"Generated: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n\n")
        f.write("## Peak Performance\n\n")
        f.write("| Configuration | Peak QPS | At Concurrency | Total Data Points |\n")
        f.write("|---------------|----------|----------------|-------------------|\n")
        for name, config in CONFIGS.items():
            peak = max(config["data"], key=lambda d: d[3])
            f.write(f"| {name.replace(chr(10), ' ')} | {peak[3]:,.2f} | {peak[0]:.2f} | {len(config['data'])} |\n")
        f.write("\n## Key Findings\n\n")
        f.write("- Standalone mode achieves the highest QPS (~4,708) on a single host\n")
        f.write("- SolrCloud overhead is significant when all nodes share hardware\n")
        f.write("- Adding ZooKeeper nodes on the same host reduces performance\n")
        f.write("- True distributed advantages require separate physical machines\n")

    print(f"  Saved: comparison_summary_{timestamp}.md")

    # Copy latest to webapp/images
    webapp_img_dir = os.path.join(os.path.dirname(output_dir), '..', 'webapp', 'images')
    os.makedirs(webapp_img_dir, exist_ok=True)

    import shutil
    for fname in [f"comparison_qps_{timestamp}.png", f"comparison_peak_{timestamp}.png", f"standalone_scaling_{timestamp}.png"]:
        src = os.path.join(output_dir, fname)
        # Also save as the "latest" version
        base = fname.rsplit('_', 1)[0]  # Remove timestamp
        dst = os.path.join(webapp_img_dir, f"{base}_latest.png")
        shutil.copy2(src, dst)
        print(f"  Copied → {dst}")

    print(f"\nAll comparison charts saved to {output_dir}")

if __name__ == "__main__":
    output_dir = os.path.join(os.path.dirname(__file__), 'visualizations')
    print("Generating multi-configuration comparison charts...")
    create_all_charts(output_dir)
    print("Done!")
