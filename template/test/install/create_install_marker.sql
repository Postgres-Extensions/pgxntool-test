\set ON_ERROR_STOP on
CREATE TABLE pgxntool_install_marker AS SELECT 'alive'::text AS marker;
