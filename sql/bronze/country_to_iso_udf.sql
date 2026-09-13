-- NOT used by the bronze/silver/gold build (see bronze/air_quality.sql for
-- why: BigQuery doesn't support calling a table-referencing SQL UDF once
-- per row against another table - confirmed live, not assumed - so this
-- can't do the bulk country-name resolution the pipeline actually needs).
--
-- Kept only as a convenience for ad-hoc single-value lookups in the
-- BigQuery console, e.g. `SELECT bronze.country_to_iso('France')`.
CREATE OR REPLACE FUNCTION bronze.country_to_iso(name STRING) AS ((
  SELECT iso2 FROM `bronze.country_code_map` WHERE country_name = name LIMIT 1
));
