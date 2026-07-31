#!/bin/bash
# run-siege-benchmark.sh - Sweep siege across concurrency levels and emit JSON.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/env.sh"

CORE_URL="$SOLR_URL"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/benchmark_results}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
OUTPUT_FILE="${OUTPUT_DIR}/siege_results.json"
QUERY_ENDPOINT="${QUERY_ENDPOINT:-/select?q=TCP}"

# Test duration in seconds per level. Matches the documented ~10s methodology.
DURATION="${DURATION:-10}"
# Concurrency levels (prime numbers avoid synchronization/aliasing artifacts).
read -r -a CONCURRENT_USERS <<< "${CONCURRENT_USERS:-2 3 5 7 11 13 17 19 23 29 79 83}"

mkdir -p "$OUTPUT_DIR"

if ! command -v siege >/dev/null 2>&1; then
  echo "Error: 'siege' is not installed." >&2
  exit 1
fi
if [ ! -f "$SIEGERC" ]; then
  echo "Error: siege resource file not found at $SIEGERC" >&2
  exit 1
fi

echo "Starting benchmark tests against $CORE_URL"
echo "Results will be saved to $OUTPUT_FILE"

TEMP_FILE="${OUTPUT_DIR}/temp_results_${TIMESTAMP}.json"

{
  echo "{"
  echo "  \"benchmark_timestamp\": \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\","
  echo "  \"solr_url\": \"$CORE_URL\","
  echo "  \"results\": ["
} > "$TEMP_FILE"

first_entry=true

# Extract a numeric JSON field from siege's JSON stats; empty if absent.
# siege pads values with tabs/spaces, so strip all whitespace and commas.
# `|| true` keeps a no-match (grep exit 1) from aborting the script under
# `set -o pipefail`, so the validation loop below can emit its diagnostic.
extract_metric() {
  echo "$1" | grep -i "\"$2\":" | awk -F: '{print $2}' | tr -d '[:space:],' || true
}

for USERS in "${CONCURRENT_USERS[@]}"; do
  echo "Running test with $USERS concurrent users for $DURATION seconds..."

  # -R points siege at the repo-local rc (json_output=true) so the parser below
  # always receives JSON, regardless of the user's personal ~/.siege/siege.conf.
  SIEGE_OUTPUT=$(siege -R "$SIEGERC" -c "$USERS" -t"${DURATION}S" -b "${CORE_URL}${QUERY_ENDPOINT}" 2>&1 || true)

  TRANSACTIONS=$(extract_metric "$SIEGE_OUTPUT" transactions)
  AVAILABILITY=$(extract_metric "$SIEGE_OUTPUT" availability)
  ELAPSED_TIME=$(extract_metric "$SIEGE_OUTPUT" elapsed_time)
  RESPONSE_TIME=$(extract_metric "$SIEGE_OUTPUT" response_time)
  TRANSACTION_RATE=$(extract_metric "$SIEGE_OUTPUT" transaction_rate)
  THROUGHPUT=$(extract_metric "$SIEGE_OUTPUT" throughput)
  CONCURRENCY=$(extract_metric "$SIEGE_OUTPUT" concurrency)
  SUCCESSFUL_TRANSACTIONS=$(extract_metric "$SIEGE_OUTPUT" successful_transactions)
  FAILED_TRANSACTIONS=$(extract_metric "$SIEGE_OUTPUT" failed_transactions)

  # Fail loudly instead of silently writing zeros: an empty parse means siege
  # produced no JSON (wrong rc, siege error, or Solr unreachable).
  for metric in TRANSACTIONS AVAILABILITY ELAPSED_TIME RESPONSE_TIME \
                TRANSACTION_RATE THROUGHPUT CONCURRENCY \
                SUCCESSFUL_TRANSACTIONS FAILED_TRANSACTIONS; do
    if [ -z "${!metric}" ]; then
      echo "Error: could not parse '$metric' from siege output at concurrency $USERS." >&2
      echo "Ensure Solr is reachable and siege JSON output is enabled (json_output=true in $SIEGERC)." >&2
      echo "----- raw siege output -----" >&2
      echo "$SIEGE_OUTPUT" >&2
      exit 1
    fi
  done

  if [ "$first_entry" = true ]; then
    first_entry=false
  else
    echo "    ," >> "$TEMP_FILE"
  fi

  cat << EOF >> "$TEMP_FILE"
    {
      "concurrent_users": $USERS,
      "duration_seconds": $DURATION,
      "transactions": $TRANSACTIONS,
      "availability": $AVAILABILITY,
      "elapsed_time": $ELAPSED_TIME,
      "response_time": $RESPONSE_TIME,
      "transaction_rate": $TRANSACTION_RATE,
      "throughput": $THROUGHPUT,
      "concurrency": $CONCURRENCY,
      "successful_transactions": $SUCCESSFUL_TRANSACTIONS,
      "failed_transactions": $FAILED_TRANSACTIONS
    }
EOF

  sleep 2
done

{
  echo "  ]"
  echo "}"
} >> "$TEMP_FILE"

# Validate JSON before finalizing (python3 is always available; jq is optional).
if command -v jq >/dev/null 2>&1; then
  jq . "$TEMP_FILE" > "$OUTPUT_FILE"
else
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TEMP_FILE"
  mv "$TEMP_FILE" "$OUTPUT_FILE"
fi
rm -f "$TEMP_FILE"

echo "Benchmark complete. Results saved to $OUTPUT_FILE"

# Post-process from the script directory so relative paths resolve correctly.
# Activate a virtualenv only if VENV is provided; otherwise use python3 on PATH.
if [ -n "${VENV:-}" ] && [ -f "${VENV}/bin/activate" ]; then
  # shellcheck source=/dev/null
  source "${VENV}/bin/activate"
fi

cd "$SCRIPT_DIR"
echo "Running visualization script..."
python3 visualize.py "$OUTPUT_FILE"

echo "All tasks completed successfully."
