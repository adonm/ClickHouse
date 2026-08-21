#!/usr/bin/env bash
# Test Iceberg manifest prune cache hits
# Uses IcebergLocal with partition pruning to exercise ManifestFileIterator::processRow cache

CUR_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
. "$CUR_DIR"/../shell_config.sh

# Create a simple Iceberg table via IcebergLocal (file-based, no REST catalog)
TMP_DIR=$(mktemp -d)
TABLE_PATH="$TMP_DIR/iceberg_prune_test"
mkdir -p "$TABLE_PATH"

# Use clickhouse to create Iceberg table with partitioning, then query with same filter twice
$CLICKHOUSE_CLIENT -q "DROP TABLE IF EXISTS iceberg_prune_test"
$CLICKHOUSE_CLIENT -q "CREATE TABLE iceberg_prune_test (id Int32, part Int32) ENGINE=IcebergLocal('$TABLE_PATH', 'parquet') PARTITION BY part SETTINGS allow_experimental_iceberg=1"

# Insert some data with partitions 0..3
$CLICKHOUSE_CLIENT -q "INSERT INTO iceberg_prune_test SETTINGS allow_insert_into_iceberg=1 VALUES (1, 0), (2, 1), (3, 2), (4, 3)"

# First query with filter that prunes to part=1 (should miss prune cache)
$CLICKHOUSE_CLIENT -q "SELECT * FROM iceberg_prune_test WHERE part = 1 SETTINGS use_iceberg_partition_pruning=1" --query_id=q_prune1 > /dev/null
$CLICKHOUSE_CLIENT -q "SYSTEM FLUSH LOGS"
$CLICKHOUSE_CLIENT -q "SELECT ProfileEvents['IcebergManifestPruneCacheMisses'] > 0 AS miss1, ProfileEvents['IcebergPartitionPrunedFiles'] > 0 AS pruned1 FROM system.query_log WHERE query_id='q_prune1' AND type='QueryFinish'"

# Second identical query should hit prune cache
$CLICKHOUSE_CLIENT -q "SELECT * FROM iceberg_prune_test WHERE part = 1 SETTINGS use_iceberg_partition_pruning=1" --query_id=q_prune2 > /dev/null
$CLICKHOUSE_CLIENT -q "SYSTEM FLUSH LOGS"
$CLICKHOUSE_CLIENT -q "SELECT ProfileEvents['IcebergManifestPruneCacheHits'] > 0 AS hit2 FROM system.query_log WHERE query_id='q_prune2' AND type='QueryFinish'"

$CLICKHOUSE_CLIENT -q "SYSTEM CLEAR ICEBERG MANIFEST PRUNE CACHE"
echo "CLEAR OK"
$CLICKHOUSE_CLIENT -q "SELECT * FROM iceberg_prune_test WHERE part = 1 SETTINGS use_iceberg_partition_pruning=1" --query_id=q_prune3 > /dev/null
$CLICKHOUSE_CLIENT -q "SYSTEM FLUSH LOGS"
$CLICKHOUSE_CLIENT -q "SELECT ProfileEvents['IcebergManifestPruneCacheMisses'] > 0 AS miss3 FROM system.query_log WHERE query_id='q_prune3' AND type='QueryFinish'"

$CLICKHOUSE_CLIENT -q "DROP TABLE iceberg_prune_test"
rm -rf "$TMP_DIR"
echo "OK"
