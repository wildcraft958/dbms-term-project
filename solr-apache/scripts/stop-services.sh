#!/bin/bash
# stop-services.sh - Stop the Solr nodes and ZooKeeper ensemble.
#
# Mirrors start-services.sh, tearing services down in the reverse order: Solr
# first (the Solr nodes are clients of the ZooKeeper ensemble), then ZooKeeper.
# Safe to run even if some services are already stopped.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/env.sh"

BASE_DIR="$SCRIPT_DIR"

# `bin/solr stop` launches Java to send Jetty's stop command, so make sure
# JAVA_HOME points at a Solr-compatible JDK (env.sh resolves/exports it).
require_compatible_java || exit 1

# Stop Solr nodes
echo "Stopping Solr nodes..."
for i in $(seq 1 "$NUM_SOLR_NODES"); do
    NODE_DIR="$BASE_DIR/solr-nodes/node$i"
    PORT=$((SOLR_PORT_BASE + i - 1))
    if [ ! -x "$NODE_DIR/bin/solr" ]; then
        echo "Skipping Solr node $i: $NODE_DIR/bin/solr not found."
        continue
    fi
    echo "Stopping Solr node $i on port $PORT..."
    "$NODE_DIR/bin/solr" stop -p "$PORT" || echo "Solr node $i was not running."
done

# Stop ZooKeeper ensemble
echo "Stopping ZooKeeper ensemble..."
for i in $(seq 1 "$NUM_ZK_NODES"); do
    CFG="$BASE_DIR/zookeeper/conf/zoo$i.cfg"
    if [ ! -f "$CFG" ]; then
        echo "Skipping ZooKeeper node $i: missing $CFG."
        continue
    fi
    echo "Stopping ZooKeeper node $i with $CFG"
    "$BASE_DIR/zookeeper/bin/zkServer.sh" stop "$CFG" || echo "ZooKeeper node $i was not running."
done

echo "All services stopped!"
