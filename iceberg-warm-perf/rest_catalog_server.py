#!/usr/bin/env python3
"""Minimal Iceberg REST catalog server wrapping a PyIceberg SQL catalog.

Implements just the endpoints ClickHouse's `RestCatalog` uses:

    GET /v1/config
    GET /v1/namespaces
    GET /v1/namespaces/{ns}
    GET /v1/namespaces/{ns}/tables
    GET /v1/namespaces/{ns}/tables/{table}

The `default-base-location` in the config response tells ClickHouse which
storage backend the table locations use (`file://` -> local reads), and the
table response carries the full Iceberg metadata JSON.

Env:
    PORT          listen port (default 8787)
    CATALOG_URI   PyIceberg sql catalog URI, e.g. sqlite:///.../catalog.db
    WAREHOUSE     warehouse path the catalog was created with
    BASE_LOCATION default-base-location reported to ClickHouse
"""

from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from pyiceberg.catalog import load_catalog

PORT = int(os.getenv("PORT", "8787"))
CATALOG_NAME = os.getenv("CATALOG_NAME", "iceberg_warm_perf")
CATALOG_URI = os.getenv("CATALOG_URI", "sqlite:////tmp/opencode/iceberg_dataset/downloads/catalog.db")
WAREHOUSE = os.getenv("WAREHOUSE", "/tmp/opencode/iceberg_dataset")
BASE_LOCATION = os.getenv("BASE_LOCATION", f"file://{WAREHOUSE}")

# When the dataset is staged to another root (e.g. a ramdisk), the sqlite
# catalog and the metadata files still carry the original absolute paths.
# Rewrite them on the fly so the catalog can be moved without rebuilding.
REWRITE_SRC = os.getenv("PATH_REWRITE_SRC")
REWRITE_DST = os.getenv("PATH_REWRITE_DST")

# S3-backed warehouses (e.g. the JDBC-bench MinIO fixture): metadata files
# are fetched over S3 instead of local open(). Unset for file:// datasets.
S3_ENDPOINT = os.getenv("S3_ENDPOINT")
S3_ACCESS_KEY = os.getenv("S3_ACCESS_KEY")
S3_SECRET_KEY = os.getenv("S3_SECRET_KEY")


def rewrite_path(path: str) -> str:
    if REWRITE_SRC and REWRITE_DST and path.startswith(REWRITE_SRC):
        return REWRITE_DST + path[len(REWRITE_SRC):]
    return path


def read_metadata(path: str) -> dict:
    """Load a metadata.json from a local path or (with S3_* set) S3."""
    if path.startswith("s3://") and S3_ENDPOINT:
        import s3fs

        fs = s3fs.S3FileSystem(endpoint_url=S3_ENDPOINT, key=S3_ACCESS_KEY, secret=S3_SECRET_KEY)
        with fs.open(path, "rb") as metadata_file:
            return json.load(metadata_file)
    with open(rewrite_path(path), encoding="utf-8") as metadata_file:
        return json.load(metadata_file)

catalog_properties = {"uri": CATALOG_URI, "warehouse": WAREHOUSE}
if S3_ENDPOINT:
    catalog_properties.update(
        {
            "s3.endpoint": S3_ENDPOINT,
            "s3.access-key-id": S3_ACCESS_KEY or "",
            "s3.secret-access-key": S3_SECRET_KEY or "",
        }
    )
catalog = load_catalog(CATALOG_NAME, type="sql", **catalog_properties)
TABLES = {
    "nyc": sorted(identifier[-1] for identifier in catalog.list_tables("nyc") if len(identifier) > 1)
}


class Handler(BaseHTTPRequestHandler):
    def do_GET(self) -> None:
        path = self.path.split("?")[0].strip("/")
        parts = [part for part in path.split("/") if part]

        body, status = self.route(parts)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def route(self, parts):
        if not parts or parts[0] != "v1":
            return {"error": {"type": "NoSuchNamespaceException", "message": "not found"}}, 404

        parts = parts[1:]

        if parts == ["config"]:
            return {"defaults": {}, "overrides": {"default-base-location": BASE_LOCATION}}, 200

        if parts == ["namespaces"]:
            return {"namespaces": [["nyc"]], "next-page-token": ""}, 200

        if len(parts) >= 2 and parts[0] == "namespaces":
            namespace = parts[1]
            if namespace != "nyc":
                return {"error": {"type": "NoSuchNamespaceException", "message": namespace}}, 404

            if len(parts) == 2:
                return {"namespace": ["nyc"], "properties": {}}, 200

            if len(parts) == 3 and parts[2] == "tables":
                return {"identifiers": [{"namespace": ["nyc"], "name": name} for name in TABLES["nyc"]]}, 200

            if len(parts) == 4 and parts[2] == "tables":
                name = parts[3]
                if name not in TABLES["nyc"]:
                    return {"error": {"type": "NoSuchTableException", "message": name}}, 404
                table = catalog.load_table(f"nyc.{name}")
                raw_location = table.metadata_location
                metadata = read_metadata(raw_location)
                if raw_location.startswith("s3://"):
                    # S3-backed table: locations are already S3 URLs that
                    # ClickHouse resolves via its storage_endpoint setting.
                    metadata_location = raw_location
                    return {
                        "metadata-location": metadata_location,
                        "metadata": metadata,
                    }, 200
                metadata_location = rewrite_path(raw_location)
                # The served metadata file uses the kebab-case field names
                # ClickHouse's parser expects (PyIceberg's json() would emit
                # snake_case).
                # PyIceberg writes bare filesystem paths; ClickHouse's local
                # storage requires a file:// scheme.
                if "location" in metadata:
                    metadata["location"] = "file://" + rewrite_path(metadata["location"]).lstrip("file://")
                metadata_location = "file://" + metadata_location.lstrip("file://")
                return {
                    "metadata-location": metadata_location,
                    "metadata": metadata,
                }, 200

        return {"error": {"type": "NoSuchNamespaceException", "message": "not found"}}, 404

    def log_message(self, fmt, *args) -> None:
        print(f"[rest-catalog] {self.address_string()} {fmt % args}", flush=True)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    # Master re-resolves the catalog per query, so the stress phase can open
    # hundreds of connections per second; the default backlog of 5 would
    # overflow its accept queue and fail queries with connect timeouts.
    request_queue_size = 1024


if __name__ == "__main__":
    server = Server(("127.0.0.1", PORT), Handler)
    print(f"[rest-catalog] serving {CATALOG_URI} on 127.0.0.1:{PORT}", flush=True)
    server.serve_forever()
