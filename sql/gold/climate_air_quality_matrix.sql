-- Option D: risk-bucket matrix. Temperature bands are the only invented
-- thresholds here (Cold/Mild/Hot, roughly WHO-style comfort bands - see
-- docs/transform_layer_plan.md for the exact reasoning); AQI buckets
-- reuse the source CSV's own "AQI Category" values directly rather than
-- inventing new AQI thresholds, so there's one fewer arbitrary choice to
-- defend than option B (the composite score) would have needed.
--
-- A VIEW, not a table (see city_environment_summary.sql for why).
CREATE OR REPLACE VIEW analytics.climate_air_quality_matrix AS
SELECT
  CASE
    WHEN temperature_c < 15 THEN 'Cold (<15C)'
    WHEN temperature_c <= 27 THEN 'Mild (15-27C)'
    ELSE 'Hot (>27C)'
  END AS temperature_band,
  aqi_category,
  COUNT(*) AS city_count
FROM `silver.weather_air_quality`
GROUP BY temperature_band, aqi_category
ORDER BY temperature_band, aqi_category;
