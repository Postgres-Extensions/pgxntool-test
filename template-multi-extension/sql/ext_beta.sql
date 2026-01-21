CREATE FUNCTION ext_beta_multiply(a int, b int)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
SELECT a * b;
$$;
