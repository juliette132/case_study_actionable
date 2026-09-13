-- silver.weather_air_quality: the one cross-source join, pruned to what
-- gold's aggregates actually need.
--
-- INNER JOIN by design: cities present in only one source (e.g. Paris,
-- New York - weather-only; most of the CSV's 23,463 cities - air-quality-
-- only) correctly don't appear here. They're still available untouched in
-- bronze.weather / bronze.air_quality for single-source gold aggregates.
--
-- bronze.weather has one row per (city, observation time) - not yet
-- collapsed to "current conditions" - so this takes the latest
-- observation per city before joining, rather than joining on every
-- historical row (which would multiply air-quality rows once weather
-- has accumulated more than one hourly reading per city).
CREATE OR REPLACE TABLE silver.weather_air_quality AS
WITH latest_weather AS (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY city_key, country_key ORDER BY ingested_at DESC
    ) AS rn
  FROM `bronze.weather`
)
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
  a.pm25_aqi_value
FROM latest_weather w
JOIN `bronze.air_quality` a
  ON w.city_key = a.city_key AND w.country_key = a.country_key
WHERE w.rn = 1;
