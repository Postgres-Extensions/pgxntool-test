\set ECHO none
-- DO NOT REMOVE: pg_regress runs psql with echo-all, so without this the SQL
-- input is echoed into the output and never matches expected/base.out.
\a
\t
SELECT pg_sleep(.1);
SELECT 'multi_ext_ok';
