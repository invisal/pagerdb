-- name: insert
-- group: insert

-- load
CREATE TABLE _series (n INT);
INSERT INTO _series VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);
CREATE TABLE bench (id INT, name TEXT, score REAL);

-- run
INSERT INTO bench
  SELECT a.n * 1000 + b.n * 100 + c.n * 10 + d.n,
         CAST(a.n * 1000 + b.n * 100 + c.n * 10 + d.n AS TEXT),
         (a.n * 1000 + b.n * 100 + c.n * 10 + d.n) * 0.1
  FROM _series AS a, _series AS b, _series AS c, _series AS d;
