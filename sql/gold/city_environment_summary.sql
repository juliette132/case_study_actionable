-- Option A: side-by-side summary. Deliberately the simplest gold output -
-- no blending, no invented thresholds, nothing to defend. Just puts
-- temperature and air quality next to each other per city, for direct
-- comparison or as a BI-tool source.
--
-- A VIEW, not a table, per gold-layer convention: no stored data of its
-- own to go stale, always reflects whatever silver.weather_air_quality
-- currently holds, and needs no scheduled rebuild step. Callers wanting a
-- guaranteed row order should add their own ORDER BY - a view's ORDER BY
-- is not guaranteed to survive query planning.
CREATE OR REPLACE VIEW analytics.city_environment_summary AS
SELECT
  city_name,
  country_key,
  ROUND(temperature_c, 1) AS temperature_c,
  humidity_pct,
  weather_description,
  aqi_value,
  aqi_category
FROM `silver.weather_air_quality`
ORDER BY aqi_value DESC;
