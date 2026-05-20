-- name: join-predicate
-- group: join

-- load
CREATE TABLE _s10 (n INT);
INSERT INTO _s10 VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);
CREATE TABLE users (id INT, name TEXT);
INSERT INTO users SELECT n, CAST(n AS TEXT) FROM _s10;
CREATE TABLE orders (id INT, user_id INT, amount INT);
INSERT INTO orders
  SELECT a.n * 1000 + b.n * 100 + c.n * 10 + d.n,
         a.n,
         b.n * 100 + c.n * 10 + d.n
  FROM _s10 AS a, _s10 AS b, _s10 AS c, _s10 AS d;

-- run
SELECT o.id, u.name, o.amount
FROM orders AS o
INNER JOIN users AS u ON o.user_id = u.id
WHERE o.amount > 500;
