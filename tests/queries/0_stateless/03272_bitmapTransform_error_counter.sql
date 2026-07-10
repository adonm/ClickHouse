-- `bitmapTransform` with matching from/to array sizes must not raise `ILLEGAL_TYPE_OF_ARGUMENT`.
-- Check this query's own query_log row instead of the process-wide system.errors counter, which
-- any concurrent test triggering the same (very common) error code would perturb.

SELECT bitmapToArray(bitmapTransform(bitmapBuild([1, 2, 3, 4, 5, 6, 7, 8, 9, 10]), cast([5,999,2] as Array(UInt32)), cast([2,888,20] as Array(UInt32)))) AS res FORMAT Null;

SYSTEM FLUSH LOGS query_log;

SELECT exception_code = 0 FROM system.query_log
WHERE current_database = currentDatabase() AND type != 'QueryStart'
    AND query LIKE 'SELECT bitmapToArray(bitmapTransform%';
