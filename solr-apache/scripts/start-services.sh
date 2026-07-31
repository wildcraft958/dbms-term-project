#!/bin/bash
# start-services.sh - Start the ZooKeeper ensemble and Solr nodes.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/env.sh"

BASE_DIR="$SCRIPT_DIR"
CONFIG_DIR="$BASE_DIR/solr-config/searchcore/conf"

# Require a Solr-compatible JDK (env.sh resolves/exports JAVA_HOME).
require_compatible_java || exit 1

# Start ZooKeeper ensemble
echo "Starting ZooKeeper ensemble..."
for i in $(seq 1 "$NUM_ZK_NODES"); do
  CFG="$BASE_DIR/zookeeper/conf/zoo$i.cfg"
  if [ ! -f "$CFG" ]; then
    echo "Error: Missing $CFG. Run ./setup-solr.sh first."
    exit 1
  fi
  echo "Starting ZooKeeper node $i with $CFG"
  "$BASE_DIR/zookeeper/bin/zkServer.sh" start "$CFG"
done

# Wait for ZooKeeper to start
sleep 5

for i in $(seq 1 "$NUM_ZK_NODES"); do
  CFG="$BASE_DIR/zookeeper/conf/zoo$i.cfg"
  if ! "$BASE_DIR/zookeeper/bin/zkServer.sh" status "$CFG" >/dev/null 2>&1; then
    echo "Error: ZooKeeper node $i failed to start. Check $BASE_DIR/zookeeper/logs"
    exit 1
  fi
done

# Start Solr nodes
echo "Starting Solr nodes..."
for i in $(seq 1 "$NUM_SOLR_NODES"); do
    NODE_DIR="$BASE_DIR/solr-nodes/node$i"
    PORT=$((SOLR_PORT_BASE + i - 1))
    echo "Starting Solr node $i on port $PORT..."
    "$NODE_DIR/bin/solr" start -c -p "$PORT" -z "$ZK_CONNECT"
done

echo "Waiting for Solr to stabilize..."
sleep 10

echo "Creating collection..."
if curl -fsS "${SOLR_BASE_URL}/admin/collections?action=LIST&wt=json" | grep -q "\"${COLLECTION}\""; then
    echo "Collection '${COLLECTION}' already exists, skipping create_collection."
else
    # -d uploads the repository configset (schema + solrconfig) to ZooKeeper, so
    # the collection uses this repo's config rather than Solr's default configset.
    "$BASE_DIR/solr-nodes/node1/bin/solr" create_collection \
      -c "$COLLECTION" \
      -d "$CONFIG_DIR" \
      -shards "$SHARDS" \
      -replicationFactor "$REPLICATION_FACTOR" \
      -p "$SOLR_PORT_BASE"
fi

echo "All services started!"
for i in $(seq 1 "$NUM_SOLR_NODES"); do
    PORT=$((SOLR_PORT_BASE + i - 1))
    echo "Solr node $i: http://${SOLR_HOST}:${PORT}/solr/"
done
echo "ZooKeeper ensemble: $ZK_CONNECT"
