-- Companion to nearest_city_comparison.sql: is there an actual trend
-- between geographic distance and how similar two cities' air quality
-- (and temperature) are, across every pair, not just each city's single
-- nearest neighbor?
--
-- Caveat worth being upfront about: 40 cities produce C(40,2) = 780
-- pairs, but they are NOT 780 independent observations - each city
-- appears in 39 of them, so this table is useful for eyeballing a trend,
-- not for a rigorous statistical claim. nearest_city_comparison.sql (one
-- row per city) is the more defensible table if asked to justify sample
-- independence.
--
-- overall_corr_* columns are the SAME value repeated on every row
-- (computed once across all 780 pairs, then cross-joined onto the
-- per-band breakdown) - deliberately not computed per-band, which would
-- answer a different, narrower question (correlation *within* a distance
-- range) than the one this table is for (is there an overall trend).
CREATE OR REPLACE TABLE analytics.distance_similarity_trend AS
WITH cities AS (
  SELECT s.city_name, s.aqi_value, s.temperature_c, w.latitude, w.longitude
  FROM `silver.weather_air_quality` s
  JOIN `bronze.weather` w ON s.city_key = w.city_key AND s.country_key = w.country_key
  QUALIFY ROW_NUMBER() OVER (PARTITION BY s.city_key ORDER BY w.ingested_at DESC) = 1
),
pairs AS (
  SELECT
    ST_DISTANCE(ST_GEOGPOINT(a.longitude, a.latitude), ST_GEOGPOINT(b.longitude, b.latitude)) / 1000 AS distance_km,
    ABS(a.aqi_value - b.aqi_value) AS aqi_diff,
    ABS(a.temperature_c - b.temperature_c) AS temp_diff
  FROM cities a
  JOIN cities b ON a.city_name < b.city_name -- one row per unordered pair, not two
),
overall AS (
  SELECT
    ROUND(CORR(distance_km, aqi_diff), 3) AS overall_corr_distance_aqi_diff,
    ROUND(CORR(distance_km, temp_diff), 3) AS overall_corr_distance_temp_diff
  FROM pairs
),
banded AS (
  SELECT
    CASE
      WHEN distance_km < 1000 THEN '1: <1,000 km'
      WHEN distance_km < 4000 THEN '2: 1,000-4,000 km'
      WHEN distance_km < 8000 THEN '3: 4,000-8,000 km'
      ELSE '4: >8,000 km'
    END AS distance_band,
    COUNT(*) AS n_pairs,
    ROUND(AVG(aqi_diff), 1) AS avg_aqi_diff,
    ROUND(AVG(temp_diff), 1) AS avg_temp_diff
  FROM pairs
  GROUP BY distance_band
)
SELECT banded.*, overall.*
FROM banded
CROSS JOIN overall
ORDER BY distance_band;
