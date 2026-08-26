# Warm-perf results log

Appended by `update_results.py` (run by the fork CI perf job on every push).
Each section is a master-vs-validation comparison on the public NYC TLC
dataset (2025-01..06, ~24M rows, PyIceberg, partitioned by
`day(tpep_pickup_datetime)`, sorted by `tpep_pickup_datetime`), RAM-backed
on the runner's ramdisk, `DataLakeCatalog` + local REST catalog, 50 queries
per connection, per-query cache attribution in the job artifacts.

## Comparison (concurrency 64)

### Before (master)

### before (2026-08-26 10:21 UTC, `19d5cbe6`)

| Query | QPS | p50 | p95 |
|---|---|---|---|
| point lookup | 287.75 | 38.00 ms | 55.00 ms |
| partition scan | 241.34 | 57.00 ms | 100.00 ms |
| full count | 331.66 | 28.00 ms | 44.00 ms |

Stress (point lookup, sustained): 860.96 QPS, 0 failed queries
### After (validation)

### after (2026-08-26 10:21 UTC, `19d5cbe6`)

| Query | QPS | p50 | p95 |
|---|---|---|---|
| point lookup | 344.04 | 17.00 ms | 33.00 ms |
| partition scan | 258.38 | 80.00 ms | 86.00 ms |
| full count | 391.68 | 12.00 ms | 14.00 ms |

Stress (point lookup, sustained): 1698.80 QPS, 0 failed queries
## Comparison (concurrency 8)

### Before (master)

### before (2026-08-26 10:21 UTC, `19d5cbe6`)

| Query | QPS | p50 | p95 |
|---|---|---|---|
| point lookup | 285.40 | 9.00 ms | 15.00 ms |
| partition scan | 240.03 | 14.00 ms | 19.00 ms |
| full count | 283.91 | 9.00 ms | 17.00 ms |

Stress (point lookup, sustained): 863.89 QPS, 0 failed queries
### After (validation)

### after (2026-08-26 10:21 UTC, `19d5cbe6`)

| Query | QPS | p50 | p95 |
|---|---|---|---|
| point lookup | 325.93 | 5.00 ms | 11.00 ms |
| partition scan | 275.93 | 10.00 ms | 18.00 ms |
| full count | 394.07 | 2.00 ms | 2.00 ms |

Stress (point lookup, sustained): 1740.88 QPS, 0 failed queries
