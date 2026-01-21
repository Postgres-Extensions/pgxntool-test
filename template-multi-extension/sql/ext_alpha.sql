CREATE FUNCTION ext_alpha_add(a int, b int)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
SELECT a + b;
$$;
