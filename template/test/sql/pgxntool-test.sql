\i test/pgxntool/setup.sql

SELECT plan(1);

SELECT is(
  "pgxntool-test"(1,2)
  , 3
);

\i test/pgxntool/finish.sql

-- vi: expandtab ts=2 sw=2
