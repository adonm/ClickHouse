# Iceberg warm-performance validation

Harness for the Iceberg/DataLakeCatalog warm-query performance work
(ClickHouse PRs #115873–#115878). Lives on the fork's validation branch
`adonm/iceberg-warm-perf-validation`, which merges all six PRs onto current
master so they can be built, tested, and benchmarked together. Fixes developed
here are kept as separate commits and cherry-picked into the individual PRs.

## Layout

- `build_dataset.py` — builds a public Iceberg dataset (NYC TLC trip records)
  partitioned by `day(tpep_pickup_datetime)` and sorted by
  `tpep_pickup_datetime`. No credentials needed for the source data.
- `run_benchmark.sh` — starts a throwaway ClickHouse server, creates an
  `Iceberg` table over the dataset, runs the warm-perf query set with
  `clickhouse-benchmark`, and collects the cache counters from `system.events`.
- `report.py` — turns benchmark JSON results into a markdown table; can compare
  two runs (e.g. master vs validation branch).
- CI: `.github/workflows/iceberg-warm-perf-validation.yml` builds the branch on
  GitHub Actions and runs the stateless tests from the PRs; a
  `workflow_dispatch` input additionally runs this harness.

All run artifacts (downloads, server data, results) go to `tmp/` in the repo
root, which is gitignored.

## Quick start

```bash
# 1. Build the dataset (local filesystem; ~4M rows/month, ~50 MB/month)
#    Put it on tmpfs so warm reads are pure RAM - disk I/O otherwise
#    dominates and hides the cache wins on both sides of the comparison.
pip install "pyiceberg[sql-sqlite,s3fs]" pyarrow
python3 iceberg-warm-perf/build_dataset.py \
    --location /tmp/opencode/iceberg_dataset/nyc_taxi \
    --months 2025-01,2025-02

# 2. Run the benchmark against a ClickHouse binary
iceberg-warm-perf/run_benchmark.sh build/programs/clickhouse \
    /tmp/opencode/iceberg_dataset/nyc_taxi/nyc/taxis

# 3. Report (or compare two runs)
python3 iceberg-warm-perf/report.py tmp/iceberg_warm_perf_results/latest
python3 iceberg-warm-perf/report.py --compare tmp/iceberg_warm_perf_results/before tmp/iceberg_warm_perf_results/after
```

For an S3-backed dataset, pass an `s3://` location and ambient AWS credentials
(or `--access-key`/`--secret-key`/`--endpoint`); `run_benchmark.sh` forwards
`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`S3_ENDPOINT` to the table engine.

## Benchmark protocol

The query set (see `run_benchmark_rest.sh`) mirrors the PR validation:

1. point lookup on the sort column (`tpep_pickup_datetime = '2025-01-15 12:34:56'`)
2. partition-filtered scan (`WHERE tpep_pickup_datetime BETWEEN ...`)
3. full `count()`

Each query is warmed twice (all caches hot, page-fault noise gone), then
measured with `clickhouse-benchmark` over `BENCH_ITERATIONS` (default 50)
queries per connection at `BENCH_CONCURRENCY` (default 1). After the
throughput runs, each query is executed once more under a known `query_id`
and its cache/I/O counters are read back from `system.query_log`
(`events_query_*.jsonl`), so every cache can be attributed per query. When
`STRESS_TIMELIMIT` is set, a sustained saturation run of the point lookup
at `STRESS_CONCURRENCY` (default 128) connections reports its QPS in
`stress.txt` and as a "stress" row in `report.py`.

Run the comparison twice (`before`/`after`) and report p50/p95, QPS, the
per-query attribution table, and the stress row; compare master vs the
validation branch with the same dataset and settings.

## JDBC catalog leg (`catalog_type = 'jdbc'`)

`run_benchmark_jdbc.sh` runs the same query set over a standard Iceberg
JdbcCatalog in Postgres (table data on S3-compatible storage) and is compared
against the REST leg on the same binary and fixture:

- `rest_catalog_server.py` also serves S3-backed catalogs: set `S3_ENDPOINT`,
  `S3_ACCESS_KEY`, `S3_SECRET_KEY` and a Postgres `CATALOG_URI`, and pass
  `BASE_LOCATION=s3://<bucket>` plus
  `CATALOG_STORAGE_SETTINGS="storage_endpoint='<endpoint>', ..."` to
  `run_benchmark_rest.sh`.
- Fixture: `build_dataset.py` with an `s3://` location and a Postgres
  `--catalog-uri` writes both the warehouse and the standard
  `iceberg_tables` rows (needs MinIO/Postgres running; create the bucket
  first).
- CI: `.github/workflows/iceberg-jdbc-bench.yml` (manual
  `workflow_dispatch`) builds the `adonm/iceberg-jdbc-catalog` branch, runs
  its stateless test, then benches `rest` vs `jdbc` at concurrencies 8 and
  64. It lives on this branch so the implementation branch stays
  upstream-clean.

## Known integration fixes (cherry-pick into PRs)

When the PRs land in sequence, two cross-PR fixes made on this branch must be
carried into the individual PRs:

1. **PR #115878 after #115877**: `Parquet::Reader::findOrderedRowGroupForPoint`
   must read row-group metadata through the `getFileMetadata()` accessor that
   #115877 introduced (`shared_file_metadata`), not the by-value
   `file_metadata` member, which is no longer populated when the footer comes
   from the cache. See the fix inside merge commit
   `2319f60bec33` (`Merge pr-115878 into validation branch`).
2. **`SYSTEM CLEAR` plumbing between #115873 and #115876**: both PRs add
   adjacent entries to `AccessType.h`, `ProfileEvents.cpp`,
   `CurrentMetrics.cpp`, `InterpreterSystemQuery.cpp`, `ASTSystemQuery.*`, and
   `ParserSystemQuery.cpp`. The resolution is "keep both"; see merge commit
   `6d1b158a7582` (`Merge pr-115876 into validation branch`).

## CI notes

The build job runs in the `clickhouse/binary-builder` container (the image
upstream CI uses), since ClickHouse master requires Clang ≥ 21 while
`ubuntu-latest` ships Clang 18. GitHub-hosted runners are small (4 vCPU /
16 GB / ~14 GB disk), so the job builds only the `clickhouse` target in
`Release` mode; if it runs out of disk, check the "Disk usage" step and trim
contrib or build without ccache. Perf numbers from shared runners are noisy;
use them only for gross before/after sanity, and re-run the real numbers on a
dedicated machine.
