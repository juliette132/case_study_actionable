# Transform layer plan (bronze / silver / gold)

Planning only — nothing in this doc is built yet. This is the "optional
stretch" from the brief; the mandatory ingestion work (both sources, live
and scheduled) is already done and doesn't depend on any of this.

**Layering, as directed:** `raw_data.*` (already built) is the ingestion
landing zone — source-shaped, append-only, no cleanup. Bronze is where
normalization/typing/dedup happens; silver does the cross-source join and
drops columns gold doesn't need; gold is pure aggregation. (This shifts
cleanup a tier earlier than the more common medallion convention of
"bronze = raw" — a legitimate variant, and simpler here since there are
only two sources to conform before the one join that matters.)

## Tier 1 — Bronze (`bronze` dataset): normalized, typed, deduplicated

One row per source record still — no joining, no aggregation yet.

| Table | Source | What it does |
|---|---|---|
| `bronze.weather` | `raw_data.import_weather` | Adds `city_key` (accent-stripped, lowercased `city_name` — see normalization expression below) and `country_key` (lowercased ISO code, already clean). Dedups via `ROW_NUMBER() OVER (PARTITION BY location_query, observed_at ORDER BY ingested_at DESC)`, keeping rank 1. Drops `raw_response`. Types are already correct from bronze ingestion. |
| `bronze.air_quality` | `raw_data.import_csv_data` | Adds `city_key`/`country_key` normalized the same way from `City`/`Country`. Casts every `... AQI Value` column from STRING to INT64 (BigQuery's CSV autodetect left them as STRING). Dedups on `(city_key, country_key)` — see caveat below. |

**Normalization expression** (verified against real data, not assumed —
this is what caught São Paulo not joining on a plain string match):
```sql
city_key = REGEXP_REPLACE(NORMALIZE(LOWER(city_name), NFD), r'\pM', '')
```
`NORMALIZE(..., NFD)` decomposes accented characters into base letter +
combining mark; `REGEXP_REPLACE(..., r'\pM', '')` strips the marks
(`\p{Mark}` is a Unicode-category regex class BigQuery's `REGEXP_REPLACE`
supports). Confirmed live: `São Paulo` → `sao paulo`, matching the CSV's
`Sao Paulo` after the same treatment.

**Dedup caveat for `bronze.air_quality`:** the CSV is a one-time snapshot
(23,463 rows, effectively one row per city) with no per-row ingestion
timestamp in the data itself — only `raw_data._ingested_files` (the
control table) knows *when* a file landed, not each row. Today, `COUNT(*)
GROUP BY city_key, country_key` dedup is enough because there's only one
file. If a second, overlapping air-quality file is ever ingested, "keep
the newest" wouldn't be answerable at the row level as currently designed
— worth flagging now rather than after it silently picks an arbitrary row.
Cheapest fix if/when it matters: have `sftp_ingest` stamp a
`_source_file`/`_ingested_at` column onto every row at load time (a small
change to `load_csv()`'s job config), not something to build speculatively
today.

**Country-code mapping, needed for a correct join later:** weather stores
`country` as an ISO-2 code (`FR`, `DE`); the CSV stores full English names
(`France`, `Germany`). A city-name-only join (what today's verification
query used) only avoided the "multiple Berlins worldwide" problem because
the 40 candidate cities were hand-checked one at a time. For the actual
silver join to be robust for any *future* added city — not just today's
curated list — `country_key` needs a real translation, not just
lowercasing. Simplest fix: a small static mapping (`WITH country_codes AS
(SELECT * FROM UNNEST([STRUCT('fr' AS iso, 'france' AS name), ...]))`)
covering just the ~40 countries in play, joined in alongside the city key.
Bounded and explicit rather than pulling in a public reference dataset for
40 rows.

## Tier 2 — Silver (`silver` dataset): the join, pruned to what gold needs

| Table | Built from | What it does |
|---|---|---|
| `silver.weather_air_quality` | `bronze.weather` (latest row per city) JOIN `bronze.air_quality` ON `city_key` AND mapped `country_key` | One row per matched city: `city_key`, `country_key`, `temperature_c`, `humidity_pct`, `weather_description`, `aqi_value` (now INT64), `aqi_category`. Drops everything else (raw ids, query strings, per-observation timestamps) — gold doesn't need them. |

This is an inner join by design — cities with no cross-source match
(Paris, New York, and most of the original weather list) simply don't
appear here. That's correct for this table's purpose; they still exist
untouched in `bronze.weather` for the weather-only gold aggregate.

## Tier 3 — Gold (`analytics` dataset): aggregation

**Single-source aggregates (straightforward, build regardless of what
follows):**
- `analytics.daily_weather_summary` (from `bronze.weather`): per city per
  day, avg/min/max temperature and humidity.
- `analytics.air_quality_by_country` (from `bronze.air_quality`): per
  country, avg AQI, count by category.

**The combined weather+air-quality metric — options, as requested.** All
of these read from `silver.weather_air_quality`; pick one (or two — A is
cheap enough to keep alongside whichever of B–E you also want):

| # | Approach | What it produces | Strengths | Weaknesses |
|---|---|---|---|---|
| **A** | Side-by-side summary | One row per city: temp and AQI next to each other, no blending | Zero subjective choices to defend; trivial to explain; good BI-table baseline | Not really a "combined metric" — just co-located numbers |
| **B** | Composite comfort score | `100 - LEAST(ABS(temp_c - 21) * 2, 50) - LEAST(aqi_value * 0.3, 50)` — one 0-100 number per city | Strong single headline number for a demo ("Riyadh scores 12/100") | The weights/comfort-band are your own design choice — have a ready answer for "why these numbers" in the discussion, since it's the one place here that's genuinely arbitrary |
| **C** | Statistical correlation | `CORR(temperature_c, aqi_value)` across matched cities — one number | Shows actual analytical thinking, not just a display metric; cheap to compute | ~40 data points is a thin sample for a correlation claim; be upfront that it's exploratory, not a finding, if asked |
| **D** | Risk quadrant / bucket matrix | Cities bucketed by temperature band × the CSV's *existing* AQI Category (no new thresholds invented), counted per bucket | No arbitrary math to defend — reuses the source's own AQI bands; easy 3×N heatmap chart | Less of a single "story number" than B or E |
| **E** | Combined-extremes leaderboard | `RANK() OVER (ORDER BY temperature_c DESC) + RANK() OVER (ORDER BY aqi_value DESC) AS combined_rank`, top N | Genuinely interesting narrative ("cities with both hot weather and bad air right now"), defensible because it's rank-based rather than a weighted formula | Ranks don't carry a magnitude — "how much worse", not just "worse than" |

**Recommendation:** build **A** (nearly free) plus **E** (best
story-to-effort ratio, no defensibility risk) as the actual gold output;
mention **B**, **C**, **D** verbally as considered alternatives in the
discussion if it comes up — that's a stronger answer than picking one
metric and presenting it as the only reasonable choice.

## Tooling options — this is the actual decision to make

Two ways to build tiers 1–3, both fully GCP-native (no low-code tool
involved either way — this is a transform layer, not a new ingestion
source, so the brief's hard constraint isn't really in play here, but
sticking to GCP-native keeps the story consistent).

### Option A — BigQuery Scheduled Queries (recommended given the timeline)

Each bronze/silver/gold table is a `CREATE OR REPLACE TABLE ... AS SELECT`
statement, scheduled via BigQuery's built-in Data Transfer Service
(`bq query --schedule=... --destination_table=...` or the Console UI).

**New GCP resources needed:**
- `bq mk bronze`, `bq mk silver`, `bq mk analytics` datasets.
- One scheduled query per table above (roughly 6-7 total).
- IAM: the Data Transfer Service runs queries under a service account —
  needs `roles/bigquery.dataEditor` on `bronze`/`silver`/`analytics` and
  `roles/bigquery.jobUser` at the project level (every scheduled query is
  a BigQuery Job — same reason `sftp-ingest` needed it).

**Effort:** low — a few hours including writing and testing the SQL. No
new service to learn, reuses everything already set up.

### Option B — Dataform (the more "correct" GCP-native answer, more setup)

Dataform is Google Cloud's own SQL-transformation-as-code product —
version-controlled `.sqlx` files defining a dependency graph (bronze
sources → silver → gold), compiled and scheduled by Dataform itself. Worth
noting: `dataform.googleapis.com` is **already enabled** on this project
(visible in `gcloud services list --enabled`), so there's no new API to
turn on.

**New GCP resources needed:**
- `gcloud dataform repositories create` + a workspace.
- SQLX files: source declarations for the two `raw_data` tables, then a
  transformation file per bronze/silver/gold table (dependencies declared
  via `ref()`, so Dataform builds the DAG automatically).
- A release configuration (compiles the SQLX) + workflow configuration
  (schedules execution) — Dataform's own scheduling, no separate Cloud
  Scheduler job needed for this layer.
- IAM: Dataform's service agent needs the same `dataEditor` (on the three
  new datasets) + project-level `bigquery.jobUser` as Option A.

**Effort:** medium-high — the payoff is a real, visualizable dependency
graph and transformation-as-code sitting in the same repo as the ingestion
functions, a stronger answer to "how would this scale" in Monday's
discussion, but it's a new tool to set up correctly under time pressure.

**Recommendation given the timeline:** build with Option A (Scheduled
Queries) to have something real and demoable; describe Option B verbally
as "the production answer, here's what it would look like and why I
didn't build it under this deadline" — itself a legitimate
architecture-choice talking point.

## Sequencing if this gets built

1. Create `bronze`, `silver`, `analytics` datasets.
2. Grant IAM (dataEditor on all three, project-level jobUser) to whichever
   identity runs the transforms (a new `transform-runner-sa`, or the
   Scheduled Query default service account).
3. Write and test the two bronze queries (normalization + typing + dedup)
   against real `raw_data` — including the country-code mapping.
4. Write and test the silver join against real bronze data — confirm the
   40-city match count holds (39 + London, or 40 with the accent fix).
5. Write and test the gold queries (A + E, per the recommendation above)
   against real silver data.
6. Schedule all of them, cadence trailing ingestion (e.g. 15 minutes after
   the hourly ingestion jobs, not at the same minute).
7. Document the DAG (even just a short paragraph + the tables above) in
   `docs/architecture.md`.
