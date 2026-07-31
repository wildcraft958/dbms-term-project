#!/bin/bash
# setup-solr.sh - Download and configure Solr + a local ZooKeeper ensemble.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/env.sh"

BASE_DIR="$SCRIPT_DIR"
ZK_PEER_PORT_BASE="${ZK_PEER_PORT_BASE:-2888}"
ZK_ELECTION_PORT_BASE="${ZK_ELECTION_PORT_BASE:-3888}"

# Require a Solr-compatible JDK (env.sh resolves/exports JAVA_HOME).
require_compatible_java || exit 1

# Create directories
mkdir -p "$BASE_DIR/downloads"
mkdir -p "$BASE_DIR/solr-nodes"
mkdir -p "$BASE_DIR/zookeeper"

# Download Solr
if [ ! -f "$BASE_DIR/downloads/solr-$SOLR_VERSION.tgz" ]; then
    echo "Downloading Solr $SOLR_VERSION..."
    curl -o "$BASE_DIR/downloads/solr-$SOLR_VERSION.tgz" "https://archive.apache.org/dist/solr/solr/$SOLR_VERSION/solr-$SOLR_VERSION.tgz"
fi

# Download ZooKeeper
if [ ! -f "$BASE_DIR/downloads/apache-zookeeper-$ZOOKEEPER_VERSION-bin.tar.gz" ]; then
    echo "Downloading ZooKeeper $ZOOKEEPER_VERSION..."
    curl -o "$BASE_DIR/downloads/apache-zookeeper-$ZOOKEEPER_VERSION-bin.tar.gz" "https://archive.apache.org/dist/zookeeper/zookeeper-$ZOOKEEPER_VERSION/apache-zookeeper-$ZOOKEEPER_VERSION-bin.tar.gz"
fi

# Extract Solr (skip if already extracted)
if [ ! -d "$BASE_DIR/downloads/solr-$SOLR_VERSION" ]; then
    echo "Extracting Solr..."
    tar xzf "$BASE_DIR/downloads/solr-$SOLR_VERSION.tgz" -C "$BASE_DIR/downloads"
else
    echo "Solr already extracted, skipping."
fi

# Extract ZooKeeper (skip if already extracted)
if [ ! -d "$BASE_DIR/downloads/apache-zookeeper-$ZOOKEEPER_VERSION-bin" ]; then
    echo "Extracting ZooKeeper..."
    tar xzf "$BASE_DIR/downloads/apache-zookeeper-$ZOOKEEPER_VERSION-bin.tar.gz" -C "$BASE_DIR/downloads"
else
    echo "ZooKeeper already extracted, skipping."
fi

# Set up ZooKeeper
echo "Setting up ZooKeeper..."
cp -r "$BASE_DIR/downloads/apache-zookeeper-$ZOOKEEPER_VERSION-bin/." "$BASE_DIR/zookeeper/"
mkdir -p "$BASE_DIR/zookeeper/data"

# Build the list of ensemble peers (server.N=host:peerPort:electionPort).
SERVER_LINES=""
for i in $(seq 1 "$NUM_ZK_NODES"); do
    PEER_PORT=$((ZK_PEER_PORT_BASE + i - 1))
    ELECTION_PORT=$((ZK_ELECTION_PORT_BASE + i - 1))
    SERVER_LINES+="server.$i=127.0.0.1:${PEER_PORT}:${ELECTION_PORT}"$'\n'
done

# Write a config, dataDir, clientPort, and myid for each ensemble node.
for i in $(seq 1 "$NUM_ZK_NODES"); do
    CLIENT_PORT=$((ZK_CLIENT_PORT_BASE + i - 1))
    NODE_DATA_DIR="$BASE_DIR/zookeeper/data/zk$i"
    NODE_CFG="$BASE_DIR/zookeeper/conf/zoo$i.cfg"

    mkdir -p "$NODE_DATA_DIR"
    echo "$i" > "$NODE_DATA_DIR/myid"

    cat > "$NODE_CFG" << EOF
tickTime=2000
initLimit=10
syncLimit=5
dataDir=$NODE_DATA_DIR
clientPort=$CLIENT_PORT
${SERVER_LINES}
EOF
done

# Keep zoo.cfg aligned with node-1 for tools that default to this filename.
cp "$BASE_DIR/zookeeper/conf/zoo1.cfg" "$BASE_DIR/zookeeper/conf/zoo.cfg"

# Also write a single-node (standalone) ZK config. A lone node from the 3-server
# ensemble configs above can't form a quorum, so the "1 ZooKeeper" benchmark
# configurations use this standalone config instead.
cat > "$BASE_DIR/zookeeper/conf/zoo-standalone.cfg" << EOF
tickTime=2000
initLimit=10
syncLimit=5
dataDir=$BASE_DIR/zookeeper/data/zk1
clientPort=$ZK_CLIENT_PORT_BASE
EOF

# Create Solr nodes
for i in $(seq 1 "$NUM_SOLR_NODES"); do
    echo "Setting up Solr node $i..."
    NODE_DIR="$BASE_DIR/solr-nodes/node$i"
    mkdir -p "$NODE_DIR"
    cp -r "$BASE_DIR/downloads/solr-$SOLR_VERSION/." "$NODE_DIR/"

    # Configure Solr to use ZooKeeper
    cp "$BASE_DIR/solr-config/solr.xml" "$NODE_DIR/server/solr/"
done

echo "Local ZooKeeper ensemble configured at: $ZK_CONNECT"
echo "Setup complete! Start ZooKeeper and Solr nodes to begin."
