-- Option E: combined-extremes leaderboard. Rank-based rather than a
-- weighted formula (option B, not built) - defensible because ranks
-- don't require justifying arbitrary weights, only "this city is hotter/
-- more polluted than that one", which the source data answers directly.
-- Lower combined_rank = worse on both axes simultaneously (rank 1 + rank
-- 1 = 2 is the lowest possible score, i.e. hottest AND most polluted).
CREATE OR REPLACE TABLE analytics.extreme_conditions_ranking AS
SELECT
  city_name,
  country_key,
  temperature_c,
  aqi_value,
  aqi_category,
  RANK() OVER (ORDER BY temperature_c DESC) AS temp_rank,
  RANK() OVER (ORDER BY aqi_value DESC) AS aqi_rank,
  RANK() OVER (ORDER BY temperature_c DESC) + RANK() OVER (ORDER BY aqi_value DESC) AS combined_rank
FROM `silver.weather_air_quality`
ORDER BY combined_rank ASC;
