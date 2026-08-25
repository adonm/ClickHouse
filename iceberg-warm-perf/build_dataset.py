#!/usr/bin/env python3
"""
Build a public Iceberg dataset (NYC TLC trip records) for warm-performance benchmarks.

Downloads public Parquet files (no credentials required), creates an Iceberg
table partitioned by ``day(tpep_pickup_datetime)`` and sorted by
``tpep_pickup_datetime`` (so data files are physically ordered - this exercises
the row-group fence search from PR #115878), and appends the rows.

Requirements: ``pip install "pyiceberg[sql-sqlite,s3fs]" pyarrow``

Examples:
    # local table
    python3 iceberg-warm-perf/build_dataset.py \\
        --location "$PWD/tmp/iceberg_dataset/nyc_taxi" --months 2025-01,2025-02

    # S3 table (ambient AWS credentials, or pass --access-key/--secret-key/--endpoint)
    python3 iceberg-warm-perf/build_dataset.py \\
        --location s3://my-bucket/nyc_taxi --months 2025-01,2025-02
"""

from __future__ import annotations

import argparse
import os
import urllib.request
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq
from pyiceberg.catalog import load_catalog
from pyiceberg.partitioning import PartitionField, PartitionSpec
from pyiceberg.schema import Schema
from pyiceberg.table.sorting import NullOrder, SortDirection, SortField, SortOrder
from pyiceberg.transforms import DayTransform, IdentityTransform
from pyiceberg.types import (
    DoubleType,
    FloatType,
    IntegerType,
    LongType,
    NestedField,
    StringType,
    TimestampType,
)

SOURCE_URL = "https://d37ci6vzurychx.cloudfront.net/trip-data/yellow_tripdata_{month}.parquet"

# Curated subset of the TLC yellow tripdata schema.
SCHEMA = Schema(
    NestedField(1, "vendor_id", LongType(), required=False),
    NestedField(2, "tpep_pickup_datetime", TimestampType(), required=False),
    NestedField(3, "tpep_dropoff_datetime", TimestampType(), required=False),
    NestedField(4, "trip_distance", DoubleType(), required=False),
    NestedField(5, "pu_location_id", LongType(), required=False),
    NestedField(6, "do_location_id", LongType(), required=False),
    NestedField(7, "payment_type", LongType(), required=False),
    NestedField(8, "fare_amount", DoubleType(), required=False),
    NestedField(9, "total_amount", DoubleType(), required=False),
)

# Source column name -> (target name, target type). Types are the ones the
# public files actually use; the rest of the source columns are dropped.
COLUMNS = {
    "VendorID": ("vendor_id", pa.int64()),
    "tpep_pickup_datetime": ("tpep_pickup_datetime", pa.timestamp("us")),
    "tpep_dropoff_datetime": ("tpep_dropoff_datetime", pa.timestamp("us")),
    "trip_distance": ("trip_distance", pa.float64()),
    "PULocationID": ("pu_location_id", pa.int64()),
    "DOLocationID": ("do_location_id", pa.int64()),
    "payment_type": ("payment_type", pa.int64()),
    "fare_amount": ("fare_amount", pa.float64()),
    "total_amount": ("total_amount", pa.float64()),
}


def download_month(month: str, download_dir: Path) -> Path:
    target = download_dir / f"yellow_tripdata_{month}.parquet"
    if target.exists():
        print(f"using cached {target}")
        return target
    url = SOURCE_URL.format(month=month)
    print(f"downloading {url}")
    download_dir.mkdir(parents=True, exist_ok=True)
    tmp = target.with_suffix(".parquet.part")
    urllib.request.urlretrieve(url, tmp)
    tmp.rename(target)
    return target


def read_month(path: Path) -> pa.Table:
    table = pq.read_table(path)
    arrays = []
    fields = []
    for source_name, (target_name, target_type) in COLUMNS.items():
        if source_name not in table.column_names:
            continue
        column = table.column(source_name)
        if target_name in ("vendor_id", "payment_type", "pu_location_id", "do_location_id"):
            column = column.cast(pa.int64(), safe=False)
        arrays.append(column)
        fields.append(pa.field(target_name, column.type))
    return pa.Table.from_arrays(arrays, schema=pa.schema(fields))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--location", required=True, help="Iceberg table location (path or s3://bucket/prefix)")
    parser.add_argument("--months", required=True, help="comma-separated YYYY-MM source months")
    parser.add_argument("--download-dir", default=None, help="where to cache the source parquet files")
    parser.add_argument("--catalog-uri", default=None, help="sqlite catalog URI (default: <download-dir>/catalog.db)")
    parser.add_argument("--access-key", default=None)
    parser.add_argument("--secret-key", default=None)
    parser.add_argument("--endpoint", default=None)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    months = [m.strip() for m in args.months.split(",") if m.strip()]

    download_dir = Path(args.download_dir or f"{os.getcwd()}/tmp/iceberg_dataset/downloads")
    catalog_uri = args.catalog_uri or f"sqlite:///{download_dir}/catalog.db"
    download_dir.mkdir(parents=True, exist_ok=True)

    catalog_properties = {"uri": catalog_uri, "warehouse": args.location}
    if args.location.startswith("s3://") and args.endpoint:
        catalog_properties["s3.endpoint"] = args.endpoint
    if args.access_key:
        catalog_properties["s3.access-key-id"] = args.access_key
    if args.secret_key:
        catalog_properties["s3.secret-access-key"] = args.secret_key

    catalog = load_catalog("iceberg_warm_perf", type="sql", **catalog_properties)
    catalog.create_namespace_if_not_exists("nyc")

    try:
        table = catalog.load_table("nyc.taxis")
        print(f"table nyc.taxis already exists ({table.current_snapshot()})")
    except Exception:
        partition_spec = PartitionSpec(
            PartitionField(source_id=2, field_id=1000, transform=DayTransform(), name="tpep_pickup_datetime_day")
        )
        sort_order = SortOrder(
            SortField(
                source_id=2,
                transform=IdentityTransform(),
                direction=SortDirection.ASC,
                null_order=NullOrder.NULLS_FIRST,
            )
        )
        table = catalog.create_table(
            "nyc.taxis",
            schema=SCHEMA,
            partition_spec=partition_spec,
            sort_order=sort_order,
        )
        print(f"created table nyc.taxis at {args.location}")

    for month in months:
        source = download_month(month, download_dir)
        data = read_month(source)
        print(f"appending {month}: {data.num_rows} rows")
        table.append(data)

    print(f"done: {table.current_snapshot()}")


if __name__ == "__main__":
    main()
