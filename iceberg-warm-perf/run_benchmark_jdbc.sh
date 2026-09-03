#!/usr/bin/env bash
# JDBC-catalog-backed benchmark: starts a throwaway ClickHouse server, creates
# a DataLakeCatalog database with catalog_type='jdbc' over a standard
# Iceberg SqlCatalog in Postgres (table data on S3-compatible storage), and
# runs the same warm-perf query set as run_benchmark_rest.sh so the two legs
# are directly comparable via report.py --compare.
#
# Usage:
#   run_benchmark_jdbc.sh <clickhouse-binary> [run-name]
#
# The fixture (Postgres catalog rows + S3 warehouse) must already exist; build
# it with e.g.:
#   python3 iceberg-warm-perf/build_dataset.py \
#       --location s3://benchci/nyc_taxi \
#       --catalog-uri "postgresql+psycopg://postgres:postgres@127.0.0.1:5432/benchci" \
#       --endpoint "$S3_ENDPOINT" --access-key "$S3_ACCESS_KEY" \
#       --secret-key "$S3_SECRET_KEY" --months 2025-01 \
#       --download-dir tmp/iceberg_dataset/downloads
#
# Env (no defaults except ports):
#   PG_HOST PG_PORT PG_DATABASE PG_SCHEMA PG_USER PG_PASSWORD PG_CATALOG
#       Postgres holding iceberg_tables; PG_CATALOG is the JdbcCatalog
#       catalog_name and becomes the DataLakeCatalog `warehouse` setting.
#   S3_ENDPOINT S3_ACCESS_KEY S3_SECRET_KEY
#       S3-compatible storage holding the warehouse (also used as ClickHouse
#       storage_endpoint + static credentials).
#   PYTHON selects the python with psycopg installed (defaults to python3).

set -euo pipefail

BINARY="${1:?usage: run_benchmark_jdbc.sh <clickhouse-binary> [run-name]}"
RUN_NAME="${2:-latest}"
CONCURRENCY="${BENCH_CONCURRENCY:-1}"
ITERATIONS="${BENCH_ITERATIONS:-50}"

: "${PG_HOST:?set PG_HOST}"
: "${PG_DATABASE:?set PG_DATABASE}"
: "${PG_USER:?set PG_USER}"
: "${PG_CATALOG:?set PG_CATALOG}"
: "${S3_ENDPOINT:?set S3_ENDPOINT}"
: "${S3_ACCESS_KEY:?set S3_ACCESS_KEY}"
: "${S3_SECRET_KEY:?set S3_SECRET_KEY}"
PG_PORT="${PG_PORT:-5432}"
PG_SCHEMA="${PG_SCHEMA:-public}"
PG_PASSWORD="${PG_PASSWORD:-}"

BINARY="$(realpath "$BINARY")"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${BENCH_SERVER_DIR:-$ROOT/tmp/iceberg_warm_perf_jdbc_server}"
RESULT_DIR="$ROOT/tmp/iceberg_warm_perf_results/$RUN_NAME"
SERVER_LOG="$ROOT/tmp/iceberg_warm_perf_jdbc_server.log"

rm -rf "$WORK_DIR" "$RESULT_DIR"
mkdir -p "$WORK_DIR" "$RESULT_DIR"
for _ in 1 2 3; do
    rm -rf "$WORK_DIR" 2>/dev/null && break
    sleep 2
done
mkdir -p "$WORK_DIR"

HTTP_PORT=18125
TCP_PORT=19002

echo "checking Postgres fixture ($PG_HOST:$PG_PORT/$PG_DATABASE catalog '$PG_CATALOG')"
TABLE_COUNT="$("$PYTHON" - "$PG_HOST" "$PG_PORT" "$PG_DATABASE" "$PG_SCHEMA" "$PG_USER" "$PG_PASSWORD" "$PG_CATALOG" <<'EOF'
import sys
import psycopg
host, port, db, schema, user, password, catalog = sys.argv[1:8]
quoted = '"' + schema.replace('"', '""') + '"."iceberg_tables"'
with psycopg.connect(host=host, port=port, dbname=db, user=user, password=password or None) as conn:
    with conn.cursor() as cur:
        cur.execute(f"SELECT count(*) FROM {quoted} WHERE catalog_name = %s", (catalog,))
        print(cur.fetchone()[0])
EOF
)"
if [ "${TABLE_COUNT:-0}" -lt 1 ]; then
    echo "no tables for catalog '$PG_CATALOG' in $PG_SCHEMA.iceberg_tables; build the fixture first" >&2
    exit 1
fi
echo "fixture has $TABLE_COUNT table(s)"

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
    <user_files_path>$WORK_DIR/user_files</user_files_path>
    <listen_host>127.0.0.1</listen_host>
    <mark_cache_size>536870912</mark_cache_size>
    <query_log>
        <database>system</database>
        <table>query_log</table>
    </query_log>
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
trap 'kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true' EXIT

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
    ENGINE = DataLakeCatalog
    SETTINGS catalog_type='jdbc',
             warehouse='$PG_CATALOG',
             jdbc_host='$PG_HOST',
             jdbc_port=$PG_PORT,
             jdbc_database='$PG_DATABASE',
             jdbc_schema='$PG_SCHEMA',
             jdbc_user='$PG_USER',
             jdbc_password='$PG_PASSWORD',
             storage_endpoint='$S3_ENDPOINT',
             aws_access_key_id='$S3_ACCESS_KEY',
             aws_secret_access_key='$S3_SECRET_KEY'${CATALOG_CACHE_SETTINGS:+, $CATALOG_CACHE_SETTINGS}
             ;
EOF

QUERIES=(
    "SELECT count() FROM bench_catalog.\`nyc.taxis\` WHERE tpep_pickup_datetime = '2025-01-15 12:34:56'"
    "SELECT count() FROM bench_catalog.\`nyc.taxis\` WHERE tpep_pickup_datetime BETWEEN '2025-01-01 00:00:00' AND '2025-01-07 23:59:59'"
    "SELECT count() FROM bench_catalog.\`nyc.taxis\`"
)

echo "warm-up: run each query once so all caches are hot before measuring"
for q in "${QUERIES[@]}"; do
    "$BINARY" client --port "$TCP_PORT" --query "$q" >/dev/null
done
# A second pass removes first-pass page-fault and lazy-init noise.
for q in "${QUERIES[@]}"; do
    "$BINARY" client --port "$TCP_PORT" --query "$q" >/dev/null
done

echo "benchmarking (concurrency $CONCURRENCY, $ITERATIONS iterations per query)"
for i in "${!QUERIES[@]}"; do
    "$BINARY" benchmark \
        --host 127.0.0.1 --port "$TCP_PORT" \
        --concurrency "$CONCURRENCY" --iterations "$ITERATIONS" \
        <<< "${QUERIES[$i]}" 2> "$RESULT_DIR/query_$((i + 1)).txt"
done

# Per-query attribution: run each query once with a known query_id and read
# its cache and I/O counters back from query_log.
"$BINARY" client --port "$TCP_PORT" --query "SYSTEM FLUSH LOGS" >/dev/null
for i in "${!QUERIES[@]}"; do
    "$BINARY" client --port "$TCP_PORT" --query "${QUERIES[$i]}" --query_id="bench_events_$((i + 1))" >/dev/null
done
"$BINARY" client --port "$TCP_PORT" --query "SYSTEM FLUSH LOGS" >/dev/null
for i in "${!QUERIES[@]}"; do
    "$BINARY" client --port "$TCP_PORT" --query "
        SELECT event, ProfileEvents[event] AS value FROM system.query_log
        ARRAY JOIN mapKeys(ProfileEvents) AS event
        WHERE query_id='bench_events_$((i + 1))' AND type='QueryFinish' AND current_database = currentDatabase()
        FORMAT JSONEachRow" > "$RESULT_DIR/events_query_$((i + 1)).jsonl"
done

# Optional saturation stress: fixed-duration run at high concurrency.
if [ -n "${STRESS_TIMELIMIT:-}" ]; then
    echo "stress: ${STRESS_CONCURRENCY:-128} connections for ${STRESS_TIMELIMIT}s (point lookup)"
    "$BINARY" benchmark \
        --host 127.0.0.1 --port "$TCP_PORT" \
        --concurrency "${STRESS_CONCURRENCY:-128}" --timelimit "$STRESS_TIMELIMIT" \
        <<< "${QUERIES[0]}" 2> "$RESULT_DIR/stress.txt" || true
    FAILURES="$(grep -c "Code: " "$RESULT_DIR/stress.txt" || true)"
    echo "$FAILURES" > "$RESULT_DIR/stress_failures.txt"
    echo "stress failures: $FAILURES"
fi

"$BINARY" client --port "$TCP_PORT" --query "SYSTEM FLUSH LOGS" >/dev/null
"$BINARY" client --port "$TCP_PORT" --query "
    SELECT event, value FROM system.events
    WHERE event LIKE '%Iceberg%Cache%'
       OR event LIKE '%DataLakeCatalog%'
       OR event LIKE '%ParquetOrderedRowGroup%'
       OR event = 'ParquetRowGroupMinMaxPredicateChecks'
       OR event IN ('OSReadBytes', 'OSWriteBytes', 'OSIOWaitMicroseconds',
                    'DiskReadElapsedMicroseconds', 'DiskWriteElapsedMicroseconds',
                    'FileSegmentReadMicroseconds', 'FileSegmentUseMicroseconds')
    FORMAT JSONEachRow" > "$RESULT_DIR/events.jsonl"

echo "results written to $RESULT_DIR"
ls -la "$RESULT_DIR"
