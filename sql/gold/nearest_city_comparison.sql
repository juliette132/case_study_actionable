-- Replaces the earlier "extreme_conditions_ranking" (option E) - that
-- rank-sum leaderboard didn't surface anything geographically meaningful.
-- This instead asks: for each matched city, how similar is it to its
-- single nearest geographic neighbor (by real lat/lon, via BigQuery's
-- native ST_DISTANCE - not a hand-rolled haversine formula)?
--
-- One row per city, so unlike a full pairwise comparison this doesn't
-- have the "40 cities produce 780 non-independent pairs" statistical
-- issue - see distance_similarity_trend.sql for the pairwise version and
-- its caveat.
--
-- A VIEW, not a table (see city_environment_summary.sql for why). The
-- self cross-join + ST_DISTANCE over 40 cities (~1,560 pairs) is trivial
-- to recompute per query - not a reason to materialize this.
CREATE OR REPLACE VIEW analytics.nearest_city_comparison AS
WITH cities AS (
  SELECT s.city_key, s.city_name, s.country_key, s.aqi_value, s.temperature_c,
         w.latitude, w.longitude
  FROM `silver.weather_air_quality` s
  JOIN `bronze.weather` w ON s.city_key = w.city_key AND s.country_key = w.country_key
  QUALIFY ROW_NUMBER() OVER (PARTITION BY s.city_key ORDER BY w.ingested_at DESC) = 1
),
pairs AS (
  SELECT
    a.city_name AS city,
    b.city_name AS nearest_city,
    a.aqi_value AS city_aqi,
    b.aqi_value AS nearest_aqi,
    a.temperature_c AS city_temp,
    b.temperature_c AS nearest_temp,
    ST_DISTANCE(ST_GEOGPOINT(a.longitude, a.latitude), ST_GEOGPOINT(b.longitude, b.latitude)) / 1000 AS distance_km,
    ROW_NUMBER() OVER (
      PARTITION BY a.city_name
      ORDER BY ST_DISTANCE(ST_GEOGPOINT(a.longitude, a.latitude), ST_GEOGPOINT(b.longitude, b.latitude))
    ) AS rn
  FROM cities a
  JOIN cities b ON a.city_name != b.city_name
)
SELECT
  city,
  nearest_city,
  ROUND(distance_km, 0) AS distance_km,
  city_aqi,
  nearest_aqi,
  ABS(city_aqi - nearest_aqi) AS aqi_diff,
  ROUND(city_temp, 1) AS city_temp_c,
  ROUND(nearest_temp, 1) AS nearest_temp_c,
  ROUND(ABS(city_temp - nearest_temp), 1) AS temp_diff_c
FROM pairs
WHERE rn = 1
ORDER BY distance_km ASC;
