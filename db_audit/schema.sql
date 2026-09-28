-- Tables and test data for the database audit.
--
-- The script recreates the tables from scratch, so it can be rerun at any time
-- (for example, to drop all indexes created during the experiments):
--   docker compose exec postgres psql -U app -d shop -f /db_audit/schema.sql
--
-- Data: 2 000 000 orders and ~7 000 000 order items for the last 365 days,
-- 20 000 users, 2 000 products. Plain SQL without psql meta-commands: runs in any client.

DROP TABLE IF EXISTS order_items;
DROP TABLE IF EXISTS orders;

CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    user_id INTEGER NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'pending',
    total_amount NUMERIC(10, 2) NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT now(),
    updated_at TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE order_items (
    id SERIAL PRIMARY KEY,
    order_id INTEGER NOT NULL REFERENCES orders(id),
    product_id INTEGER NOT NULL,
    quantity INTEGER NOT NULL,
    price NUMERIC(10, 2) NOT NULL
);

-- No indexes except the primary keys: finding the missing ones is the goal of the audit.
-- REFERENCES does not create an index on order_items.order_id either.


-- Fixed seed: every run produces the same data, so plans and timings are comparable.
SELECT setseed(0.42);

-- Product catalogue. Prices are log-uniform from 20 to ~3 000: many cheap products, few expensive ones.
CREATE TEMP TABLE tmp_products AS
SELECT id AS product_id,
       round(exp(3 + random() * 5)::numeric, 2) AS price
FROM generate_series(1, 2000) AS id;

-- Orders without amounts: the total is known only after the items are generated.
CREATE TEMP TABLE tmp_orders AS
WITH raw AS (
    SELECT
        -- Active users order more often: power(random(), 2) shifts ids towards small values.
        1 + floor(20000 * power(random(), 2))::int AS user_id,
        -- The business grows: today there are twice as many orders per day as a year ago
        -- (inverse CDF of a linearly decreasing density of the order age).
        localtimestamp - interval '365 days' * (2 - sqrt(4 - 3 * random())) AS created_at,
        random() AS r,
        random() AS r2
    FROM generate_series(1, 2000000)
)
SELECT
    -- In a real table rows are appended over time, so id grows together with created_at.
    row_number() OVER (ORDER BY created_at)::int AS id,
    user_id,
    created_at,
    -- The status depends on the order age: fresh orders are still in progress, old ones are closed.
    CASE
        WHEN created_at > localtimestamp - interval '1 day' THEN
            CASE WHEN r < 0.50 THEN 'pending'
                 WHEN r < 0.80 THEN 'processing'
                 WHEN r < 0.95 THEN 'shipped'
                 ELSE 'cancelled' END
        WHEN created_at > localtimestamp - interval '7 days' THEN
            CASE WHEN r < 0.10 THEN 'processing'
                 WHEN r < 0.55 THEN 'shipped'
                 WHEN r < 0.90 THEN 'completed'
                 ELSE 'cancelled' END
        ELSE
            CASE WHEN r < 0.82 THEN 'completed'
                 WHEN r < 0.94 THEN 'cancelled'
                 ELSE 'refunded' END
    END AS status,
    r2
FROM raw;

-- 1-6 items per order. Product popularity is skewed (power(random(), 3)):
-- a few dozen products make most of the sales, which makes the "top 10 products" query meaningful.
CREATE TEMP TABLE tmp_items AS
WITH lines AS (
    SELECT o.id AS order_id,
           1 + floor(2000 * power(random(), 3))::int AS product_id,
           random() AS r
    FROM tmp_orders AS o
    -- "+ 0 * o.id" ties the call to the outer row, so the number of items is random for each order.
    CROSS JOIN LATERAL generate_series(1, 1 + floor(random() * 6)::int + 0 * o.id)
)
SELECT l.order_id,
       l.product_id,
       CASE WHEN l.r < 0.60 THEN 1
            WHEN l.r < 0.85 THEN 2
            WHEN l.r < 0.95 THEN 3
            ELSE 4 + floor(random() * 3)::int END AS quantity,
       p.price
FROM lines AS l
JOIN tmp_products AS p USING (product_id);

INSERT INTO orders (id, user_id, status, total_amount, created_at, updated_at)
SELECT o.id,
       o.user_id,
       o.status,
       t.total_amount,
       o.created_at,
       -- A pending order has not changed yet; the rest were updated within 5 days, but not in the future.
       CASE WHEN o.status = 'pending' THEN o.created_at
            ELSE least(o.created_at + o.r2 * interval '5 days', localtimestamp) END
FROM tmp_orders AS o
JOIN (
    SELECT order_id, sum(quantity * price) AS total_amount
    FROM tmp_items
    GROUP BY order_id
) AS t ON t.order_id = o.id
ORDER BY o.id;

INSERT INTO order_items (order_id, product_id, quantity, price)
SELECT order_id, product_id, quantity, price
FROM tmp_items
ORDER BY order_id;

-- Ids were inserted explicitly, so move the sequence past them, otherwise the next INSERT fails.
SELECT setval(pg_get_serial_sequence('orders', 'id'), (SELECT max(id) FROM orders));

DROP TABLE tmp_items;
DROP TABLE tmp_orders;
DROP TABLE tmp_products;

-- Fresh statistics for the planner and a filled visibility map (without it there is no Index Only Scan).
VACUUM ANALYZE orders;
VACUUM ANALYZE order_items;


-- Sanity check of the generated data.
SELECT 'orders' AS table_name, count(*) AS row_count FROM orders
UNION ALL
SELECT 'order_items', count(*) FROM order_items;

SELECT status,
       count(*) AS orders,
       round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM orders
GROUP BY status
ORDER BY orders DESC;

SELECT min(total_amount) AS min_total,
       round(avg(total_amount), 2) AS avg_total,
       percentile_cont(0.5) WITHIN GROUP (ORDER BY total_amount) AS median_total,
       max(total_amount) AS max_total,
       count(*) FILTER (WHERE total_amount > 10000) AS orders_over_10000,
       min(created_at) AS first_order,
       max(created_at) AS last_order
FROM orders;
