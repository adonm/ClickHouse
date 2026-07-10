#!/usr/bin/env bash
# Tags: no-parallel, no-replicated-database, no-ordinary-database, no-shared-merge-tree, no-fasttest
# Tag no-parallel: creates the server-wide `flags/force_drop_table` marker file, which
# globally bypasses the `max_table_size_to_drop` protection for the *next* oversized DROP
# on the server (`Context::checkCanBeDropped` deletes the marker on first use) — a
# concurrent test's oversized drop could consume it before this test's own
# `CREATE OR REPLACE` does, or vice versa.

CURDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CURDIR"/../shell_config.sh

server_path=$(${CLICKHOUSE_CLIENT} -q "SELECT value FROM system.server_settings WHERE name = 'path'")
# `server_path` may or may not end with `/`; normalize before appending `/flags`.
flags_dir="${server_path%/}/flags"
flag_file="${flags_dir}/force_drop_table"

mkdir -p "$flags_dir" 2>/dev/null || :

function cleanup()
{
    rm -f "$flag_file" 2>/dev/null ||:
    ${CLICKHOUSE_CLIENT} --max_table_size_to_drop=0 -q "DROP TABLE IF EXISTS t04329" 2>/dev/null ||:
}
trap cleanup EXIT
cleanup

${CLICKHOUSE_CLIENT} -nm -q "
    CREATE TABLE t04329 (a UInt64) ENGINE = MergeTree() ORDER BY a;
    INSERT INTO t04329 SELECT number FROM numbers(1000);
"

touch "$flag_file" && chmod a=rw "$flag_file"

${CLICKHOUSE_CLIENT} \
    --max_table_size_to_drop=1 \
    -q "CREATE OR REPLACE TABLE t04329 (b UInt64) ENGINE = MergeTree() ORDER BY b
        AS SELECT number FROM numbers(50)"

${CLICKHOUSE_CLIENT} -q "SELECT name FROM system.columns WHERE database = currentDatabase() AND table = 't04329' ORDER BY name"
${CLICKHOUSE_CLIENT} -q "SELECT count() FROM t04329"
${CLICKHOUSE_CLIENT} -q "SELECT count() FROM system.tables WHERE database = currentDatabase() AND name LIKE '%tmp_replace%'"

echo "flag_consumed:"
[ -f "$flag_file" ] && echo "0" || echo "1"
