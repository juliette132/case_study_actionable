-- bronze.weather: normalized, deduplicated, CURRENT-ONLY view of
-- raw_data.import_weather.
--
-- Adds city_key (accent-stripped, lowercased city name) and country_key
-- (weather's country is already an ISO-3166 alpha-2 code, so this is just
-- a rename for consistency with bronze.air_quality's country_key).
--
-- Collapses to ONE row per city - the single most recent observation, by
-- observed_at (the real-world time OpenWeatherMap reports the weather
-- for - not ingested_at, when our pipeline happened to poll it; the two
-- usually track closely but observed_at is the semantically correct one
-- for "the current weather," and they can diverge if the API's own feed
-- lags behind our poll). raw_data.import_weather is append-only and
-- already keeps the full time series; bronze doesn't need to
-- re-accumulate that same archive, and silver/gold only ever care about
-- "current conditions" - so the collapse now happens here, once, instead
-- of being re-derived downstream. (Previously: bronze kept every
-- distinct (location_query, observed_at) pair - a real archive that just
-- kept growing across hourly runs - and silver/each gold view
-- independently re-ranked to the latest row per city on every read.
-- silver's own copy of this logic is removed accordingly - see
-- silver/weather_air_quality.sql.)
--
-- Drops raw_response - bronze is the normalized layer, not the audit
-- trail (that's still in raw_data.import_weather, in full, regardless of
-- what bronze does - CREATE OR REPLACE only ever touches bronze itself).
--
-- _updated_at: when THIS bronze table was last rebuilt by the pipeline -
-- not the same thing as ingested_at (when the underlying row was first
-- fetched from the API). Named with an underscore prefix and _updated_at
-- rather than reusing "ingested_at" specifically to avoid colliding with
-- that existing, differently-scoped column.
CREATE OR REPLACE TABLE bronze.weather AS
WITH normalized AS (
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
  FROM `raw_data.import_weather`
),
ranked AS (
  SELECT *,
    ROW_NUMBER() OVER (
      PARTITION BY city_key, country_key ORDER BY observed_at DESC
    ) AS rn
  FROM normalized
)
SELECT * EXCEPT(rn)
FROM ranked
WHERE rn = 1;
