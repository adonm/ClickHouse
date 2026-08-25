#!/usr/bin/env bash
# REST-catalog-backed benchmark: starts the local REST catalog server and a
# throwaway ClickHouse server, creates a DataLakeCatalog database over the
# dataset, and runs the warm-perf query set with clickhouse-benchmark.
#
# Usage:
#   run_benchmark_rest.sh <clickhouse-binary> <catalog-uri> <table-location> [run-name]
#
# <table-location> must be the Iceberg table root (e.g. .../nyc/taxis) whose
# parent contains the whole warehouse; the server's user_files_path is set to
# that parent so the file:// reads are allowed. PYTHON env selects the python
# with pyiceberg installed (defaults to python3).

set -euo pipefail

BINARY="${1:?usage: run_benchmark_rest.sh <clickhouse-binary> <catalog-uri> <table-location> [run-name]}"
CATALOG_URI="${2:?usage: run_benchmark_rest.sh <clickhouse-binary> <catalog-uri> <table-location> [run-name]}"
LOCATION="${3:?usage: run_benchmark_rest.sh <clickhouse-binary> <catalog-uri> <table-location> [run-name]}"
RUN_NAME="${4:-latest}"
PYTHON="${PYTHON:-python3}"
CONCURRENCY="${BENCH_CONCURRENCY:-1}"

BINARY="$(realpath "$BINARY")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$ROOT/tmp/iceberg_warm_perf_rest_server"
RESULT_DIR="$ROOT/tmp/iceberg_warm_perf_results/$RUN_NAME"
SERVER_LOG="$ROOT/tmp/iceberg_warm_perf_rest_server.log"
REST_PORT=18787

rm -rf "$WORK_DIR" "$RESULT_DIR"
mkdir -p "$WORK_DIR" "$RESULT_DIR"

HTTP_PORT=18123
TCP_PORT=19000
USER_FILES="$(dirname "$(realpath "$LOCATION")")"

WAREHOUSE="$(dirname "$USER_FILES")"
export CATALOG_URI
export WAREHOUSE
PORT="$REST_PORT" "$PYTHON" "$ROOT/iceberg-warm-perf/rest_catalog_server.py" \
    > "$ROOT/tmp/iceberg_warm_perf_rest_catalog.log" 2>&1 &
REST_PID=$!
trap 'kill "$REST_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 30); do
    curl -fsS "http://127.0.0.1:$REST_PORT/v1/config" >/dev/null 2>&1 && break
    sleep 1
done
curl -fsS "http://127.0.0.1:$REST_PORT/v1/config" >/dev/null

echo "starting server on http port $HTTP_PORT (log: $SERVER_LOG)"
cat > "$WORK_DIR/config.xml" <<EOF
<clickhouse>
    <logger>
        <level>warning</level>
        <log>$SERVER_LOG</log>
        <errorlog>$SERVER_LOG.err</errorlog>
    </logger>
    <http_port>$HTTP_PORT</http_port>
    <tcp_port>$TCP_PORT</tcp_port>
    <path>$WORK_DIR</path>
    <tmp_path>$WORK_DIR/tmp</tmp_path>
    <user_files_path>$USER_FILES</user_files_path>
    <listen_host>127.0.0.1</listen_host>
    <mark_cache_size>536870912</mark_cache_size>
    <profiles>
        <default></default>
    </profiles>
    <users>
        <default>
            <password></password>
            <networks>
                <ip>::/0</ip>
            </networks>
            <profile>default</profile>
            <quota>default</quota>
        </default>
    </users>
    <quotas>
        <default></default>
    </quotas>
</clickhouse>
EOF
"$BINARY" server --config-file "$WORK_DIR/config.xml" &
SERVER_PID=$!
trap 'kill "$SERVER_PID" "$REST_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
    if "$BINARY" client --port "$TCP_PORT" --query "SELECT 1" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
"$BINARY" client --port "$TCP_PORT" --query "SELECT 1" >/dev/null

CATALOG_CACHE_SETTINGS="${CATALOG_CACHE_SETTINGS:-}"
"$BINARY" client --port "$TCP_PORT" --multiquery <<EOF
SET allow_database_iceberg = 1;
DROP DATABASE IF EXISTS bench_catalog;
CREATE DATABASE bench_catalog
    ENGINE = DataLakeCatalog('http://127.0.0.1:$REST_PORT/v1')
    SETTINGS catalog_type='rest',
             warehouse='warm_perf',
             vended_credentials=false${CATALOG_CACHE_SETTINGS:+, $CATALOG_CACHE_SETTINGS}
             ;
EOF

echo "warm-up query"
"$BINARY" client --port "$TCP_PORT" --query "SELECT count() FROM bench_catalog.\`nyc.taxis\`" >/dev/null

QUERIES=(
    "SELECT count() FROM bench_catalog.\`nyc.taxis\` WHERE tpep_pickup_datetime = '2025-01-15 12:34:56'"
    "SELECT count() FROM bench_catalog.\`nyc.taxis\` WHERE tpep_pickup_datetime BETWEEN '2025-01-01 00:00:00' AND '2025-01-07 23:59:59'"
    "SELECT count() FROM bench_catalog.\`nyc.taxis\`"
)

echo "benchmarking (concurrency $CONCURRENCY, 10 iterations per query)"
for i in "${!QUERIES[@]}"; do
    "$BINARY" benchmark \
        --host 127.0.0.1 --port "$TCP_PORT" \
        --concurrency "$CONCURRENCY" --iterations 10 \
        <<< "${QUERIES[$i]}" 2> "$RESULT_DIR/query_$((i + 1)).txt"
done

"$BINARY" client --port "$TCP_PORT" --query "SYSTEM FLUSH LOGS" >/dev/null
"$BINARY" client --port "$TCP_PORT" --query "
    SELECT event, value FROM system.events
    WHERE event LIKE '%Iceberg%Cache%'
       OR event LIKE '%DataLakeCatalog%'
       OR event LIKE '%ParquetOrderedRowGroup%'
       OR event = 'ParquetRowGroupMinMaxPredicateChecks'
    FORMAT JSONEachRow" > "$RESULT_DIR/events.jsonl"

echo "results written to $RESULT_DIR"
ls -la "$RESULT_DIR"
