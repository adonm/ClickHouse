
-- Test for Bug 56258

SET query_cache_tag = '02494_query_cache_bugs';

SYSTEM CLEAR QUERY CACHE TAG '02494_query_cache_bugs';

SELECT '-- Bug 56258: Check literals (ASTLiteral)';

SELECT 10 FORMAT Vertical SETTINGS use_query_cache = 1;
SELECT 10 AS x FORMAT Vertical SETTINGS use_query_cache = 1;

SELECT count(*) FROM (SELECT * FROM system.query_cache WHERE tag = '02494_query_cache_bugs') AS test_query_cache;

SYSTEM CLEAR QUERY CACHE TAG '02494_query_cache_bugs';

SELECT '-- Bug 56258: Check functions (ASTFunction)';

SELECT toUInt64(42) FORMAT Vertical SETTINGS use_query_cache = 1;
SELECT toUInt64(42) AS x FORMAT Vertical SETTINGS use_query_cache = 1;

SELECT count(*) FROM (SELECT * FROM system.query_cache WHERE tag = '02494_query_cache_bugs') AS test_query_cache;

SYSTEM CLEAR QUERY CACHE TAG '02494_query_cache_bugs';

SELECT '-- Bug 56258: Check identifiers (ASTIdentifier)';

DROP TABLE IF EXISTS tab;

CREATE TABLE tab(c UInt64) ENGINE = Memory AS SELECT 1;

SELECT c FROM tab FORMAT Vertical SETTINGS use_query_cache = 1;
SELECT c AS x FROM tab FORMAT Vertical SETTINGS use_query_cache = 1;

SELECT count(*) FROM (SELECT * FROM system.query_cache WHERE tag = '02494_query_cache_bugs') AS test_query_cache;

DROP TABLE tab;

SELECT '-- Bug 67476: Queries with overflow mode != throw must not be cached by the query cache';

DROP TABLE IF EXISTS tab;

CREATE TABLE tab(c UInt64) ENGINE = Memory;

SYSTEM CLEAR QUERY CACHE TAG '02494_query_cache_bugs';
SELECT sum(c) FROM tab SETTINGS read_overflow_mode = 'break', use_query_cache = 1; -- { serverError QUERY_CACHE_USED_WITH_NON_THROW_OVERFLOW_MODE }
SELECT sum(c) FROM tab SETTINGS read_overflow_mode_leaf = 'break', use_query_cache = 1; -- { serverError QUERY_CACHE_USED_WITH_NON_THROW_OVERFLOW_MODE }
SELECT sum(c) FROM tab SETTINGS group_by_overflow_mode = 'break', use_query_cache = 1; -- { serverError QUERY_CACHE_USED_WITH_NON_THROW_OVERFLOW_MODE }
SELECT sum(c) FROM tab SETTINGS sort_overflow_mode = 'break', use_query_cache = 1; -- { serverError QUERY_CACHE_USED_WITH_NON_THROW_OVERFLOW_MODE }
SELECT sum(c) FROM tab SETTINGS result_overflow_mode = 'break', use_query_cache = 1; -- { serverError QUERY_CACHE_USED_WITH_NON_THROW_OVERFLOW_MODE }
SELECT sum(c) FROM tab SETTINGS timeout_overflow_mode = 'break', use_query_cache = 1; -- { serverError QUERY_CACHE_USED_WITH_NON_THROW_OVERFLOW_MODE }
SELECT sum(c) FROM tab SETTINGS set_overflow_mode = 'break', use_query_cache = 1; -- { serverError QUERY_CACHE_USED_WITH_NON_THROW_OVERFLOW_MODE }
SELECT sum(c) FROM tab SETTINGS join_overflow_mode = 'break', use_query_cache = 1; -- { serverError QUERY_CACHE_USED_WITH_NON_THROW_OVERFLOW_MODE }
SELECT sum(c) FROM tab SETTINGS transfer_overflow_mode = 'break', use_query_cache = 1; -- { serverError QUERY_CACHE_USED_WITH_NON_THROW_OVERFLOW_MODE }
SELECT sum(c) FROM tab SETTINGS distinct_overflow_mode = 'break', use_query_cache = 1; -- { serverError QUERY_CACHE_USED_WITH_NON_THROW_OVERFLOW_MODE }

SYSTEM CLEAR QUERY CACHE TAG '02494_query_cache_bugs';
