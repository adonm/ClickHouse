#!/usr/bin/env bash
# Starts a throwaway ClickHouse server, creates an Iceberg table over the
# dataset, and runs the warm-perf query set with clickhouse-benchmark.
#
# Usage:
#   run_benchmark.sh <clickhouse-binary> <iceberg-table-location> [run-name]
#
# The location may be a local path (created by build_dataset.py) or an
# s3:// URI. For S3, credentials are taken from AWS_ACCESS_KEY_ID /
# AWS_SECRET_ACCESS_KEY, and S3_ENDPOINT is appended when set.
#
# Results and logs are written to tmp/iceberg_warm_perf_results/<run-name>/
# (default run-name: "latest").

set -euo pipefail

BINARY="${1:?usage: run_benchmark.sh <clickhouse-binary> <iceberg-table-location> [run-name]}"
LOCATION="${2:?usage: run_benchmark.sh <clickhouse-binary> <iceberg-table-location> [run-name]}"
RUN_NAME="${3:-latest}"

BINARY="$(realpath "$BINARY")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$ROOT/tmp/iceberg_warm_perf_server"
RESULT_DIR="$ROOT/tmp/iceberg_warm_perf_results/$RUN_NAME"
SERVER_LOG="$ROOT/tmp/iceberg_warm_perf_server.log"

rm -rf "$WORK_DIR" "$RESULT_DIR"
mkdir -p "$WORK_DIR" "$RESULT_DIR"

HTTP_PORT=18123
TCP_PORT=19000

echo "starting server on http port $HTTP_PORT (log: $SERVER_LOG)"
"$BINARY" server \
    --config-file <(cat <<EOF
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
    <user_files_path>$WORK_DIR/user_files</user_files_path>
    <listen_host>127.0.0.1</listen_host>
    <mark_cache_size>536870912</mark_cache_size>
</clickhouse>
EOF
    ) &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 60); do
    if "$BINARY" client --port "$TCP_PORT" --query "SELECT 1" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done
"$BINARY" client --port "$TCP_PORT" --query "SELECT 1" >/dev/null

ICEBERG_ARGS="'$LOCATION'"
if [[ "$LOCATION" == s3://* ]]; then
    ICEBERG_ARGS+=", '${AWS_ACCESS_KEY_ID:-}', '${AWS_SECRET_ACCESS_KEY:-}'"
    if [[ -n "${S3_ENDPOINT:-}" ]]; then
        ICEBERG_ARGS+=", '${S3_ENDPOINT}'"
    fi
else
    ICEBERG_ARGS+=", 'no-ak', 'no-sk'"
fi

"$BINARY" client --port "$TCP_PORT" --multiquery <<EOF
SET allow_experimental_database_iceberg = 1;
DROP TABLE IF EXISTS default.taxi;
CREATE TABLE default.taxi ENGINE = Iceberg($ICEBERG_ARGS);
EOF

echo "warm-up query"
"$BINARY" client --port "$TCP_PORT" --query "SELECT count() FROM default.taxi" >/dev/null

QUERIES=(
    "SELECT count() FROM default.taxi WHERE tpep_pickup_datetime = '2025-01-15 12:34:56'"
    "SELECT count() FROM default.taxi WHERE tpep_pickup_datetime BETWEEN '2025-01-01 00:00:00' AND '2025-01-07 23:59:59'"
    "SELECT count() FROM default.taxi"
)

echo "benchmarking (concurrency 1, 10 iterations per query)"
for i in "${!QUERIES[@]}"; do
    "$BINARY" benchmark \
        --host 127.0.0.1 --port "$TCP_PORT" \
        --concurrency 1 --iterations 10 \
        --json "$RESULT_DIR/query_$((i + 1)).json" \
        <<< "${QUERIES[$i]}"
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
