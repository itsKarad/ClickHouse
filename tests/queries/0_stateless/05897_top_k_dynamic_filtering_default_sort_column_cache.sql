-- Tags: no-parallel
-- no-parallel: Clears and inspects the global query condition cache.

-- A missing `MergeTree` sort column is computed from its `DEFAULT` by the reader. Changing the `Join` lookup can move
-- the `ORDER BY` boundary without changing the part, so cached top-K `PREWHERE` decisions must not be reused.
SET enable_parallel_replicas = 0;
SET automatic_parallel_replicas_mode = 0;
SET optimize_read_in_order = 0;
SET max_threads = 1;
SET max_streams_for_merge_tree_reading = 1;
SET max_block_size = 8192;
SET use_query_condition_cache = 1;
SET use_query_condition_cache_for_top_k = 1;
SET use_top_k_dynamic_filtering = 1;
SET use_skip_indexes_for_top_k = 0;
SET query_plan_max_limit_for_top_k_optimization = 1000;
SET merge_tree_min_rows_for_seek = 0;
SET merge_tree_min_bytes_for_seek = 0;

DROP TABLE IF EXISTS t_order_by_default_topk_cache;
DROP TABLE IF EXISTS lookup_order_by_default_topk_cache;
CREATE TABLE lookup_order_by_default_topk_cache (v UInt64, val UInt64) ENGINE = Join(ANY, LEFT, v);
CREATE TABLE t_order_by_default_topk_cache (id UInt32, v UInt64) ENGINE = MergeTree ORDER BY id
SETTINGS index_granularity = 64, min_bytes_for_wide_part = 0, min_bytes_for_full_part_storage = 0,
    add_minmax_index_for_numeric_columns = 0;
INSERT INTO t_order_by_default_topk_cache SELECT number, number FROM numbers(100000)
SETTINGS max_insert_threads = 1, max_insert_block_size = 2000000, min_insert_block_size_rows = 2000000;
ALTER TABLE t_order_by_default_topk_cache ADD COLUMN g UInt64 DEFAULT joinGet(
    {CLICKHOUSE_DATABASE:String} || '.lookup_order_by_default_topk_cache', 'val', v);

-- The old part has no `g`; the first lookup gives the earliest rows the smallest sort keys.
INSERT INTO lookup_order_by_default_topk_cache SELECT number, number FROM numbers(100000);
SYSTEM CLEAR QUERY CONDITION CACHE;
SELECT count() = 0 FROM system.query_condition_cache;

-- The dynamic `__topKFilter` remains active even when the cache is not safe to use.
SELECT count() > 0
FROM (
    EXPLAIN actions = 1
    SELECT g, id FROM t_order_by_default_topk_cache ORDER BY g, id LIMIT 5
)
WHERE explain LIKE '%__topKFilter(g)%';

SELECT g, id FROM t_order_by_default_topk_cache ORDER BY g, id LIMIT 5;
-- A read-time default makes the boundary-dependent cache unsafe, so the read neither writes nor reads QCC entries.
SELECT count() FROM system.query_condition_cache;

-- Reverse the lookup: the correct winners now live in later marks of the same part.
TRUNCATE TABLE lookup_order_by_default_topk_cache;
INSERT INTO lookup_order_by_default_topk_cache SELECT number, 100000 - number FROM numbers(100000);
SELECT g, id FROM t_order_by_default_topk_cache ORDER BY g, id LIMIT 5;
SELECT count() FROM system.query_condition_cache;

DROP TABLE t_order_by_default_topk_cache;
DROP TABLE lookup_order_by_default_topk_cache;
