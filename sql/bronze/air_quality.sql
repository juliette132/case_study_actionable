-- bronze.air_quality: normalized, typed, deduplicated view of
-- raw_data.import_csv_data.
--
-- country_key is resolved via a plain JOIN against bronze.country_code_map
-- (built by scripts/build_country_code_map.py), NOT via a scalar UDF -
-- BigQuery does not support a table-referencing SQL UDF being called
-- per-row against another table (confirmed live: "Unsupported subquery
-- with table in join predicate", and separately "Correlated subqueries
-- that reference other tables are not supported" even outside a JOIN
-- condition). A plain JOIN is the only proven-working approach for this.
--
-- AQI value columns are SAFE_CAST from STRING to INT64 (BigQuery's CSV
-- autodetect left them as STRING) - SAFE_CAST rather than CAST so one
-- unparseable value nulls just that column, not the whole row.
--
-- _updated_at: when THIS bronze table was last rebuilt by the pipeline -
-- see bronze/weather.sql for the same column and why it's not named
-- "ingested_at" (that name means something different at the raw_data
-- layer, and this table has no per-row ingestion timestamp anyway).
--
-- Dedup on (city_key, country_key): the CSV is a one-time snapshot with
-- no per-row ingestion timestamp, so "keep newest" isn't answerable yet -
-- ORDER BY City is just a stable, deterministic tie-break, not a
-- freshness signal. See docs/transform_layer_plan.md for the caveat if a
-- second overlapping file is ever ingested.
CREATE OR REPLACE TABLE bronze.air_quality AS
WITH resolved AS (
  SELECT
    a.*,
    REGEXP_REPLACE(NORMALIZE(LOWER(a.City), NFD), r'\pM', '') AS city_key,
    m.iso2 AS country_key
  FROM `raw_data.import_csv_data` a
  LEFT JOIN `bronze.country_code_map` m ON a.Country = m.country_name
),
deduped AS (
  SELECT *,
    ROW_NUMBER() OVER (PARTITION BY city_key, country_key ORDER BY City) AS rn
  FROM resolved
)
SELECT
  City AS city_name,
  city_key,
  Country AS country_name,
  country_key,
  SAFE_CAST(`AQI Value` AS INT64) AS aqi_value,
  `AQI Category` AS aqi_category,
  SAFE_CAST(`CO AQI Value` AS INT64) AS co_aqi_value,
  `CO AQI Category` AS co_aqi_category,
  SAFE_CAST(`Ozone AQI Value` AS INT64) AS ozone_aqi_value,
  `Ozone AQI Category` AS ozone_aqi_category,
  SAFE_CAST(`NO2 AQI Value` AS INT64) AS no2_aqi_value,
  `NO2 AQI Category` AS no2_aqi_category,
  SAFE_CAST(`PM2_5 AQI Value` AS INT64) AS pm25_aqi_value,
  `PM2_5 AQI Category` AS pm25_aqi_category,
  CURRENT_TIMESTAMP() AS _updated_at
FROM deduped
WHERE rn = 1;
