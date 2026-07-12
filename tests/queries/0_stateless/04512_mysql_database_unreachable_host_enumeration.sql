-- Tags: no-fasttest, no-parallel:remote-databases
-- Tag no-fasttest: depends on libmysql (MySQL database engine), which is not built in fast test.
-- Tag no-parallel: attaches a MySQL database pointing at an unreachable host; grouped with
--   the other remote-database attachers (see `04210_show_remote_databases_in_system_tables`).

SET send_logs_level = 'fatal';

DROP DATABASE IF EXISTS {CLICKHOUSE_DATABASE_1:Identifier};

-- MySQL probes the server at CREATE time, but is tolerant of failures on ATTACH.
-- Use a short connect_timeout / single try so the tolerated failure happens fast.
ATTACH DATABASE {CLICKHOUSE_DATABASE_1:Identifier} ENGINE = MySQL('192.0.2.1:3306', 'fake_db', 'user', 'password') SETTINGS connect_timeout = 1, connection_max_tries = 1;

-- Enumerating the tables of a MySQL database with an unreachable endpoint must not throw:
-- `system.tables` / `system.columns` scans, completion suggestions, and unknown-table-name
-- hints all iterate remote databases via `getTablesIterator`, and a connection failure there
-- used to fail the enclosing - typically unrelated - query. The iterator falls back to the
-- (possibly stale or empty) local table cache instead.
-- (The scans are database-scoped; the target is the attached database rather than
-- database = currentDatabase(), which the style check would otherwise suggest.)
SELECT count() FROM system.tables WHERE database = {CLICKHOUSE_DATABASE_1:String};
SELECT count() FROM system.columns WHERE database = {CLICKHOUSE_DATABASE_1:String};

DROP DATABASE {CLICKHOUSE_DATABASE_1:Identifier};
