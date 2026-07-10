-- Tags: no-fasttest, long
-- Tag no-fasttest: Test runtime is > 6 sec
-- Tag long: Test runtime is > 6 sec

SET query_cache_tag = '02494_query_cache_ttl_long';

SYSTEM CLEAR QUERY CACHE TAG '02494_query_cache_ttl_long';

-- Cache query result into query cache with a TTL of 3 sec
SELECT 1 SETTINGS use_query_cache = true, query_cache_ttl = 3;

-- Expect one non-stale cache entry
SELECT COUNT(*) FROM (SELECT * FROM system.query_cache WHERE tag = '02494_query_cache_ttl_long') AS test_query_cache;
SELECT stale FROM (SELECT * FROM system.query_cache WHERE tag = '02494_query_cache_ttl_long') AS test_query_cache;

-- Wait until entry is expired
SELECT sleep(3);
SELECT sleep(3);
SELECT stale FROM (SELECT * FROM system.query_cache WHERE tag = '02494_query_cache_ttl_long') AS test_query_cache;

SELECT '---';

-- Run same query as before
SELECT 1 SETTINGS use_query_cache = true, query_cache_ttl = 3;

-- The entry should have been refreshed (non-stale)
SELECT COUNT(*) FROM (SELECT * FROM system.query_cache WHERE tag = '02494_query_cache_ttl_long') AS test_query_cache;
SELECT stale FROM (SELECT * FROM system.query_cache WHERE tag = '02494_query_cache_ttl_long') AS test_query_cache;

SYSTEM CLEAR QUERY CACHE TAG '02494_query_cache_ttl_long';
