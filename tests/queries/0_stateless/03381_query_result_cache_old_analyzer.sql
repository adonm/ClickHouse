
SET query_cache_tag = '03381_query_result_cache_old_analyzer';

SYSTEM CLEAR QUERY CACHE TAG '03381_query_result_cache_old_analyzer';

-- Subquery caching is only supported with the analyzer.
-- With the old analyzer, no subquery cache entries should be created.

SET enable_analyzer = 0;

SELECT number FROM (SELECT number FROM numbers(5)) ORDER BY number
SETTINGS use_query_cache = true, query_cache_for_subqueries = true;

SELECT count(*) FROM (SELECT * FROM system.query_cache WHERE tag = '03381_query_result_cache_old_analyzer') AS test_query_cache WHERE is_subquery = 1;
-- Expected: 0

SYSTEM CLEAR QUERY CACHE TAG '03381_query_result_cache_old_analyzer';
