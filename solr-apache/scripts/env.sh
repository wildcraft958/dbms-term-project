#!/usr/bin/env bash
# Shared configuration for the Solr / ZooKeeper benchmark scripts.
#
# Every value is overridable from the environment; the defaults reproduce the
# original hardcoded behavior. Scripts should `source` this file so that the
# collection name, ports, node counts, and Solr URL are defined in one place.

SOLR_VERSION="${SOLR_VERSION:-9.3.0}"
ZOOKEEPER_VERSION="${ZOOKEEPER_VERSION:-3.8.1}"

NUM_SOLR_NODES="${NUM_SOLR_NODES:-2}"
NUM_ZK_NODES="${NUM_ZK_NODES:-3}"

SOLR_HOST="${SOLR_HOST:-localhost}"
SOLR_PORT_BASE="${SOLR_PORT_BASE:-8983}"

COLLECTION="${COLLECTION:-searchcore}"
SHARDS="${SHARDS:-2}"
REPLICATION_FACTOR="${REPLICATION_FACTOR:-1}"

SOLR_BASE_URL="${SOLR_BASE_URL:-http://${SOLR_HOST}:${SOLR_PORT_BASE}/solr}"
SOLR_URL="${SOLR_URL:-${SOLR_BASE_URL}/${COLLECTION}}"

# ZooKeeper client ports start at ZK_CLIENT_PORT_BASE and increment per node.
ZK_CLIENT_PORT_BASE="${ZK_CLIENT_PORT_BASE:-2181}"
if [ -z "${ZK_CONNECT:-}" ]; then
    _zk_connect=""
    for _i in $(seq 1 "$NUM_ZK_NODES"); do
        _port=$((ZK_CLIENT_PORT_BASE + _i - 1))
        _zk_connect="${_zk_connect:+$_zk_connect,}${SOLR_HOST}:${_port}"
    done
    ZK_CONNECT="$_zk_connect"
fi

# Repo-local siege resource file. Enables JSON output (required by
# run-siege-benchmark.sh's parser) and silences the logfile notice, so a fresh
# checkout produces real metrics instead of all-zero rows.
ENV_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIEGERC="${SIEGERC:-${ENV_SH_DIR}/benchmark/siege-config/siegerc}"

# --- Java selection -------------------------------------------------------
# Solr 9.x requires Java 11-23: it relies on the SecurityManager, which was
# removed in Java 24, so it will NOT start on Java 24+. Many distros now ship a
# newer default JDK, so resolve a compatible one here and export JAVA_HOME for
# the Solr/ZooKeeper launchers (both honor JAVA_HOME).
JAVA_MIN_MAJOR="${JAVA_MIN_MAJOR:-11}"
JAVA_MAX_MAJOR="${JAVA_MAX_MAJOR:-23}"

_java_major() {  # $1 = java binary; prints major version (e.g. 17)
    "$1" -version 2>&1 | awk -F'"' '/version/ {print $2; exit}' \
        | awk -F. '{print ($1=="1")?$2:$1}'
}

_java_compatible() {  # $1 = major version
    [ -n "$1" ] && [ "$1" -ge "$JAVA_MIN_MAJOR" ] 2>/dev/null \
        && [ "$1" -le "$JAVA_MAX_MAJOR" ] 2>/dev/null
}

_resolve_java() {
    # 1) Respect JAVA_HOME if it already points at a compatible JDK.
    if [ -n "${JAVA_HOME:-}" ] && [ -x "${JAVA_HOME}/bin/java" ] \
        && _java_compatible "$(_java_major "${JAVA_HOME}/bin/java")"; then
        return 0
    fi
    # 2) Use `java` on PATH if it's compatible.
    if command -v java >/dev/null 2>&1 \
        && _java_compatible "$(_java_major "$(command -v java)")"; then
        JAVA_HOME="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
        export JAVA_HOME
        return 0
    fi
    # 3) Search common JVM locations (prefer 17, then 11, then anything in range).
    local candidate ver
    for candidate in /usr/lib/jvm/*17* /usr/lib/jvm/*11* /usr/lib/jvm/* \
                     /Library/Java/JavaVirtualMachines/*/Contents/Home; do
        [ -x "${candidate}/bin/java" ] || continue
        ver="$(_java_major "${candidate}/bin/java")"
        if _java_compatible "$ver"; then
            JAVA_HOME="$candidate"
            export JAVA_HOME
            return 0
        fi
    done
    return 1
}

if _resolve_java; then
    export PATH="${JAVA_HOME}/bin:${PATH}"
fi

# Call from scripts that launch Solr/ZooKeeper to fail loudly when no compatible
# JDK is available, instead of hanging for 180s on "Still not seeing Solr".
require_compatible_java() {
    if ! _resolve_java; then
        echo "Error: Solr ${SOLR_VERSION} needs Java ${JAVA_MIN_MAJOR}-${JAVA_MAX_MAJOR}, but none was found." >&2
        echo "       Solr 9.x will not start on Java 24+ (SecurityManager was removed)." >&2
        echo "       Install one (e.g. 'sudo apt-get install openjdk-17-jdk-headless')" >&2
        echo "       or set JAVA_HOME to a compatible JDK, then re-run." >&2
        return 1
    fi
    export PATH="${JAVA_HOME}/bin:${PATH}"
    echo "Using Java $(_java_major "${JAVA_HOME}/bin/java") at JAVA_HOME=${JAVA_HOME}"
}
