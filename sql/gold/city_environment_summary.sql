-- Option A: side-by-side summary. Deliberately the simplest gold table -
-- no blending, no invented thresholds, nothing to defend. Just puts
-- temperature and air quality next to each other per city, for direct
-- comparison or as a BI-tool source table.
CREATE OR REPLACE TABLE analytics.city_environment_summary AS
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
