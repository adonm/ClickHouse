
SET query_cache_tag = '03381_query_result_cache_explicit_optin';

SET enable_analyzer = 1;

SYSTEM CLEAR QUERY CACHE TAG '03381_query_result_cache_explicit_optin';

-- Test 1: Explicit opt-in on subquery creates cache entry with is_subquery = 1
SELECT * FROM (SELECT number FROM numbers(5) SETTINGS use_query_cache = true) ORDER BY number;

SELECT count(*) FROM (SELECT * FROM system.query_cache WHERE tag = '03381_query_result_cache_explicit_optin') AS test_query_cache WHERE is_subquery = 1;
-- Expected: 1

-- Test 2: Second run hits cache (verified via ProfileEvents)
SELECT * FROM (SELECT number FROM numbers(5) SETTINGS use_query_cache = true) ORDER BY number;

SYSTEM FLUSH LOGS query_log;
SELECT ProfileEvents['QueryCacheHits']
FROM system.query_log
WHERE type = 'QueryFinish'
  AND current_database = currentDatabase()
  AND query LIKE '%SELECT number FROM numbers(5) SETTINGS use_query_cache = true%'
  AND query NOT LIKE '%system.query_log%'
ORDER BY event_time_microseconds DESC
LIMIT 1;

SYSTEM CLEAR QUERY CACHE TAG '03381_query_result_cache_explicit_optin';
