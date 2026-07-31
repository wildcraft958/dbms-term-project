#!/bin/bash
# finalize-benchmark.sh - Run a full siege benchmark and assemble a report.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/env.sh"

RESULTS_DIR="${RESULTS_DIR:-$SCRIPT_DIR/benchmark/results}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
REPORT_DIR="$RESULTS_DIR/report_${TIMESTAMP}"

mkdir -p "$REPORT_DIR"

echo "===================================================="
echo "   SOLR SEARCH ENGINE PERFORMANCE BENCHMARK REPORT  "
echo "===================================================="
echo "Timestamp:    $(date)"
echo "Benchmark ID: ${TIMESTAMP}"
echo "Target:       ${SOLR_URL}"
echo

# Check if Solr is running.
echo "Checking Solr status..."
if ! curl -s "${SOLR_BASE_URL}/" > /dev/null; then
    echo "Error: Solr is not running. Please start Solr using start-services.sh." >&2
    exit 1
fi

# Collect system information.
echo "Collecting system information..."
SYS_INFO="$REPORT_DIR/system_info.txt"
{
    echo "==== System Information ===="
    echo "OS:     $(uname -s)"
    echo "Kernel: $(uname -r)"
    echo "CPU:    $(grep 'model name' /proc/cpuinfo | head -1 | cut -d ':' -f2 | sed 's/^ *//')"
    echo "Cores:  $(nproc)"
    if command -v free >/dev/null 2>&1; then
        echo "Memory: $(free -h | awk '/^Mem:/ {print $2}')"
    fi
    echo "Solr:   ${SOLR_VERSION}"
    echo "ZK:     ${ZOOKEEPER_VERSION}"
} > "$SYS_INFO"
cat "$SYS_INFO"
echo

# Run the siege benchmark sweep (reuses the canonical sweep + post-processing).
echo "Running siege benchmark sweep..."
OUTPUT_DIR="$REPORT_DIR" "$SCRIPT_DIR/run-siege-benchmark.sh"

# Copy the raw results into the report directory for archival.
if [ -f "$REPORT_DIR/siege_results.json" ]; then
    echo
    echo "Report assembled in: $REPORT_DIR"
    echo "  - system_info.txt"
    echo "  - siege_results.json"
else
    echo "Warning: expected results file not found in $REPORT_DIR" >&2
fi

echo "Benchmark report complete."
