# Warm-perf results log

Appended by `update_results.py` (run by the fork CI perf job on every push).
Each section is a master-vs-validation comparison on the public NYC TLC
dataset (2025-01..06, ~24M rows, PyIceberg, partitioned by
`day(tpep_pickup_datetime)`, sorted by `tpep_pickup_datetime`), RAM-backed
on the runner's ramdisk, `DataLakeCatalog` + local REST catalog, 50 queries
per connection, per-query cache attribution in the job artifacts.

