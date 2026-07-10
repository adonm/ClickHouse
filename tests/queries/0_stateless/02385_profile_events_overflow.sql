-- `OverflowBreak`/`OverflowThrow`/`OverflowAny` are ProfileEvents, so attribute them to each
-- triggering query via query_log instead of the process-wide system.events counter. This is
-- immune to concurrent queries elsewhere triggering the same overflow modes.

SELECT count() FROM system.numbers FORMAT Null SETTINGS max_rows_to_read = 1, read_overflow_mode = 'break';

SYSTEM FLUSH LOGS query_log;

SELECT ProfileEvents['OverflowBreak'] FROM system.query_log
WHERE current_database = currentDatabase() AND type != 'QueryStart'
    AND query LIKE 'SELECT count() FROM system.numbers FORMAT Null SETTINGS%break%';

SELECT count() FROM system.numbers SETTINGS max_rows_to_read = 1, read_overflow_mode = 'throw'; -- { serverError TOO_MANY_ROWS }

SYSTEM FLUSH LOGS query_log;

SELECT ProfileEvents['OverflowThrow'] FROM system.query_log
WHERE current_database = currentDatabase() AND type != 'QueryStart'
    AND query LIKE 'SELECT count() FROM system.numbers SETTINGS%throw%';

SELECT number, count() FROM numbers(100000) GROUP BY number FORMAT Null SETTINGS max_rows_to_group_by = 1, group_by_overflow_mode = 'any';

SYSTEM FLUSH LOGS query_log;

SELECT ProfileEvents['OverflowAny'] FROM system.query_log
WHERE current_database = currentDatabase() AND type != 'QueryStart'
    AND query LIKE 'SELECT number, count() FROM numbers(100000)%';
