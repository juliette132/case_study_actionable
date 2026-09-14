-- silver.weather_air_quality: the one cross-source join, pruned to what
-- gold's aggregates actually need.
--
-- INNER JOIN by design: cities present in only one source (e.g. Paris,
-- New York - weather-only; most of the CSV's 23,463 cities - air-quality-
-- only) correctly don't appear here. They're still available untouched in
-- bronze.weather / bronze.air_quality for single-source gold aggregates.
--
-- No re-ranking needed here anymore: bronze.weather now collapses to one
-- row per city itself (see bronze/weather.sql), so this is a plain join,
-- not a join against a table that still needs its own latest-row logic
-- re-derived on every read.
--
-- _updated_at: when THIS silver table was last rebuilt - see
-- bronze/weather.sql for the same column and naming rationale.
CREATE OR REPLACE TABLE silver.weather_air_quality AS
SELECT
  w.city_key,
  w.country_key,
  w.city_name,
  w.temperature_c,
  w.humidity_pct,
  w.weather_description,
  w.observed_at AS weather_observed_at,
  a.aqi_value,
  a.aqi_category,
  a.pm25_aqi_value,
  CURRENT_TIMESTAMP() AS _updated_at
FROM `bronze.weather` w
JOIN `bronze.air_quality` a
  ON w.city_key = a.city_key AND w.country_key = a.country_key;
