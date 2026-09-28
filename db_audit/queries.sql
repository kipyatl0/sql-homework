-- Все заказы пользователя за последний месяц со статусом completed.
EXPLAIN ANALYZE SELECT o.* 
FROM orders o
WHERE created_at >= now() - interval '1 month' AND status = 'completed' AND user_id = 5;
-- Gather  (cost=1000.00..38303.10 rows=361 width=40) (actual time=36.063..42.131 rows=260.00 loops=1)
--   Workers Planned: 2
--   Workers Launched: 2
--   Buffers: shared hit=470 read=18047
--   I/O Timings: shared read=1.335
--   ->  Parallel Seq Scan on orders o  (cost=0.00..37267.00 rows=150 width=40) (actual time=31.497..35.428 rows=86.67 loops=3)
--         Filter: (((status)::text = 'completed'::text) AND (user_id = 5) AND (created_at >= (now() - '1 mon'::interval)))
--         Rows Removed by Filter: 666580
--         Buffers: shared hit=470 read=18047
--         I/O Timings: shared read=1.335
-- Planning:
--   Buffers: shared hit=87 dirtied=1
-- Planning Time: 0.700 ms
-- Execution Time: 42.161 ms

-- Топ-10 товаров по количеству продаж за последний квартал.
EXPLAIN ANALYZE SELECT oi.product_id, SUM(oi.quantity) AS total_quantity
FROM order_items oi
WHERE oi.order_id IN (
    SELECT o.id 
    FROM orders o 
    WHERE o.created_at >= now() - interval '3 months' AND o.status = 'completed'
    )
GROUP BY oi.product_id
ORDER BY total_quantity DESC
LIMIT 10;
-- Limit  (cost=154882.44..154882.46 rows=10 width=12) (actual time=604.546..670.345 rows=10.00 loops=1)
--   Buffers: shared hit=4516 read=58576, temp read=28444 written=28484
--   I/O Timings: shared read=4.208, temp read=38.148 write=239.909
--   ->  Sort  (cost=154882.44..154887.44 rows=1999 width=12) (actual time=598.447..664.245 rows=10.00 loops=1)
--         Sort Key: (sum(oi.quantity)) DESC
--         Sort Method: top-N heapsort  Memory: 25kB
--         Buffers: shared hit=4516 read=58576, temp read=28444 written=28484
--         I/O Timings: shared read=4.208, temp read=38.148 write=239.909
--         ->  Finalize GroupAggregate  (cost=154236.46..154839.24 rows=1999 width=12) (actual time=597.624..664.143 rows=2000.00 loops=1)
--               Group Key: oi.product_id
--               Buffers: shared hit=4516 read=58576, temp read=28444 written=28484
--               I/O Timings: shared read=4.208, temp read=38.148 write=239.909
--               ->  Gather Merge  (cost=154236.46..154795.26 rows=4798 width=12) (actual time=597.608..663.808 rows=6000.00 loops=1)
--                     Workers Planned: 2
--                     Workers Launched: 2
--                     Buffers: shared hit=4516 read=58576, temp read=28444 written=28484
--                     I/O Timings: shared read=4.208, temp read=38.148 write=239.909
--                     ->  Sort  (cost=153236.43..153241.43 rows=1999 width=12) (actual time=584.112..584.407 rows=2000.00 loops=3)
--                           Sort Key: oi.product_id
--                           Sort Method: quicksort  Memory: 111kB
--                           Buffers: shared hit=4516 read=58576, temp read=28444 written=28484
--                           I/O Timings: shared read=4.208, temp read=38.148 write=239.909
--                           Worker 0:  Sort Method: quicksort  Memory: 111kB
--                           Worker 1:  Sort Method: quicksort  Memory: 111kB
--                           ->  Partial HashAggregate  (cost=153106.85..153126.84 rows=1999 width=12) (actual time=583.646..583.983 rows=2000.00 loops=3)
--                                 Group Key: oi.product_id
--                                 Batches: 1  Memory Usage: 217kB
--                                 Buffers: shared hit=4502 read=58576, temp read=28444 written=28484
--                                 I/O Timings: shared read=4.208, temp read=38.148 write=239.909
--                                 Worker 0:  Batches: 1  Memory Usage: 217kB
--                                 Worker 1:  Batches: 1  Memory Usage: 217kB
--                                 ->  Parallel Hash Join  (cost=38695.92..149363.65 rows=748639 width=8) (actual time=429.402..539.979 rows=571877.00 loops=3)
--                                       Hash Cond: (oi.order_id = o.id)
--                                       Buffers: shared hit=4502 read=58576, temp read=28444 written=28484
--                                       I/O Timings: shared read=4.208, temp read=38.148 write=239.909
--                                       ->  Parallel Seq Scan on order_items oi  (cost=0.00..73710.88 rows=2914988 width=12) (actual time=0.130..103.111 rows=2331990.33 loops=3)
--                                             Buffers: shared hit=2835 read=41726
--                                             I/O Timings: shared read=3.064
--                                       ->  Parallel Hash  (cost=35183.67..35183.67 rows=214020 width=4) (actual time=86.810..86.810 rows=163452.33 loops=3)
--                                             Buckets: 262144  Batches: 4  Memory Usage: 6912kB
--                                             Buffers: shared hit=1667 read=16850, temp written=1104
--                                             I/O Timings: shared read=1.144, temp write=9.559
--                                             ->  Parallel Seq Scan on orders o  (cost=0.00..35183.67 rows=214020 width=4) (actual time=48.110..70.826 rows=163452.33 loops=3)
--                                                   Filter: (((status)::text = 'completed'::text) AND (created_at >= (now() - '3 mons'::interval)))
--                                                   Rows Removed by Filter: 503214
--                                                   Buffers: shared hit=1667 read=16850
--                                                   I/O Timings: shared read=1.144
-- Planning:
--   Buffers: shared hit=8
-- Planning Time: 0.272 ms
-- JIT:
--   Functions: 58
--   Options: Inlining false, Optimization false, Expressions true, Deforming true
--   Timing: Generation 2.844 ms (Deform 0.704 ms), Inlining 0.000 ms, Optimization 0.819 ms, Emission 17.801 ms, Total 21.464 ms
-- Execution Time: 671.396 ms
-- Очень страшный план, индексами сложно оптимизировать 


-- Средний чек по дням за последние 30 дней.
EXPLAIN ANALYZE SELECT o.created_at::date AS day, AVG(o.total_amount) AS average_check
FROM orders o
WHERE o.created_at >= now() - interval '30 days' and o.status <> 'cancelled'
GROUP BY day;
-- HashAggregate  (cost=61742.96..66370.64 rows=186859 width=36) (actual time=102.215..107.465 rows=31.00 loops=1)
--   Group Key: ((created_at)::date)
--   Planned Partitions: 8  Batches: 1  Memory Usage: 553kB
--   Buffers: shared hit=2246 read=16271
--   I/O Timings: shared read=1.792
--   ->  Gather  (cost=1000.00..55064.21 rows=186859 width=11) (actual time=77.114..90.130 rows=189730.00 loops=1)
--         Workers Planned: 2
--         Workers Launched: 2
--         Buffers: shared hit=2246 read=16271
--         I/O Timings: shared read=1.792
--         ->  Parallel Seq Scan on orders o  (cost=0.00..35378.31 rows=77858 width=11) (actual time=66.372..79.279 rows=63243.33 loops=3)
--               Filter: (((status)::text <> 'cancelled'::text) AND (created_at >= (now() - '30 days'::interval)))
--               Rows Removed by Filter: 603423
--               Buffers: shared hit=2246 read=16271
--               I/O Timings: shared read=1.792
-- Planning Time: 0.097 ms
-- Execution Time: 107.888 ms

-- Не совсем понятно, какие заказы учитывать в этом среднем чеке. 
-- Отменённые точно мимо, а вот активные -- с одной стороны потенциальная прибыль,
-- с другой -- могут быть отменены в процессе. Если не считать активные --
-- то нам поможет почти бесполезный для прошлого запроса индекс. 
-- Иначе надо делать новый, с условием status <> 'cancelled'.


-- Все заказы с суммой выше 10 000 и их позиции (JOIN).
EXPLAIN ANALYZE SELECT o.*, oi.*
FROM orders o
JOIN order_items oi ON o.id = oi.order_id
WHERE o.total_amount > 10000;
-- Gather  (cost=30565.24..154345.28 rows=424173 width=62) (actual time=64.915..312.193 rows=587758.00 loops=1)
--   Workers Planned: 2
--   Workers Launched: 2
--   Buffers: shared hit=5442 read=57636
--   I/O Timings: shared read=4.583
--   ->  Parallel Hash Join  (cost=29565.24..110927.98 rows=176739 width=62) (actual time=51.000..277.929 rows=195919.33 loops=3)
--         Hash Cond: (oi.order_id = o.id)
--         Buffers: shared hit=5442 read=57636
--         I/O Timings: shared read=4.583
--         ->  Parallel Seq Scan on order_items oi  (cost=0.00..73710.88 rows=2914988 width=22) (actual time=0.114..81.054 rows=2331990.33 loops=3)
--               Buffers: shared hit=2444 read=42117
--               I/O Timings: shared read=2.361
--         ->  Parallel Hash  (cost=28933.67..28933.67 rows=50526 width=40) (actual time=50.171..50.171 rows=39648.33 loops=3)
--               Buckets: 131072  Batches: 1  Memory Usage: 10400kB
--               Buffers: shared hit=2998 read=15519
--               I/O Timings: shared read=2.222
--               ->  Parallel Seq Scan on orders o  (cost=0.00..28933.67 rows=50526 width=40) (actual time=6.577..38.857 rows=39648.33 loops=3)
--                     Filter: (total_amount > '10000'::numeric)
--                     Rows Removed by Filter: 627018
--                     Buffers: shared hit=2998 read=15519
--                     I/O Timings: shared read=2.222
-- Planning:
--   Buffers: shared hit=8
-- Planning Time: 0.248 ms
-- JIT:
--   Functions: 36
--   Options: Inlining false, Optimization false, Expressions true, Deforming true
--   Timing: Generation 2.097 ms (Deform 0.881 ms), Inlining 0.000 ms, Optimization 0.989 ms, Emission 18.352 ms, Total 21.439 ms
-- Execution Time: 326.746 ms