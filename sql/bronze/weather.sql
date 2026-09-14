-- bronze.weather: normalized, deduplicated view of raw_data.import_weather.
--
-- Adds city_key (accent-stripped, lowercased city name) and country_key
-- (weather's country is already an ISO-3166 alpha-2 code, so this is just
-- a rename for consistency with bronze.air_quality's country_key).
-- Deduplicates on (location_query, observed_at) - belt-and-suspenders on
-- top of the ingestion script's best-effort insertId dedup (see
-- docs/architecture.md "Idempotence"): a real deploy showed 55 raw rows
-- collapse to 51 here, confirming insertId dedup alone isn't a hard
-- guarantee. Drops raw_response - bronze is the normalized layer, not
-- the audit trail (that's still in raw_data.import_weather).
--
-- _updated_at: when THIS bronze table was last rebuilt by the pipeline -
-- not the same thing as ingested_at (when the underlying row was first
-- fetched from the API). Named with an underscore prefix and _updated_at
-- rather than reusing "ingested_at" specifically to avoid colliding with
-- that existing, differently-scoped column.
CREATE OR REPLACE TABLE bronze.weather AS
WITH deduped AS (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY location_query, observed_at ORDER BY ingested_at DESC
    ) AS rn
  FROM `raw_data.import_weather`
)
SELECT
  location_query,
  city_name,
  REGEXP_REPLACE(NORMALIZE(LOWER(city_name), NFD), r'\pM', '') AS city_key,
  country AS country_key,
  latitude,
  longitude,
  observed_at,
  temperature_c,
  feels_like_c,
  humidity_pct,
  pressure_hpa,
  wind_speed_ms,
  weather_main,
  weather_description,
  ingested_at,
  CURRENT_TIMESTAMP() AS _updated_at
FROM deduped
WHERE rn = 1;
