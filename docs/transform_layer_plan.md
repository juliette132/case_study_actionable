# Transform layer plan (bronze / silver / gold)

Planning only — nothing in this doc is built yet. This is the "optional
stretch" from the brief; the mandatory ingestion work (both sources, live
and scheduled) is already done and doesn't depend on any of this.

## Where each tier already stands

**Bronze already exists, informally.** `raw_data.import_weather` and
`raw_data.import_csv_data` already are the bronze layer: append-only,
source-shaped, minimal transformation. Weather additionally keeps the full
raw JSON payload (`raw_response`) alongside flattened fields — a
lighter-weight version of "keep raw, derive the rest downstream." Nothing
new to build here; this section is really about formalizing the label,
not changing anything.

**Silver and gold do not exist yet.** This plan is about those two.

## Tier 2 — Silver (`curated` dataset): cleaned, typed, deduplicated

| Table | Source | What changes from bronze |
|---|---|---|
| `curated.weather_observations` | `raw_data.import_weather` | Real dedup via `ROW_NUMBER() OVER (PARTITION BY location_query, observed_at ORDER BY ingested_at DESC)` instead of relying only on best-effort `insertId` dedup; drops `raw_response`; keeps typed columns as-is (already typed at bronze). |
| `curated.air_quality_readings` | `raw_data.import_csv_data` | Casts the AQI value columns from STRING to INT64 (BigQuery's CSV autodetect left them as STRING); trims/standardizes `Country`/`City` text; drops rows with obviously invalid values (e.g. negative AQI). |

Why bother deduplicating again if bronze already has `insertId`-based dedup
(weather) and a content-hash control table (SFTP)? Those two mechanisms
prevent *re-ingesting the same source data twice* — they don't prevent
BigQuery's streaming-insert dedup from occasionally missing a duplicate
(it's explicitly best-effort, not a hard guarantee — see
`docs/architecture.md` "Idempotence"). A silver-layer `ROW_NUMBER()` dedup
is the belt-and-suspenders version, and it's also just the conventional
place to do this kind of cleanup rather than pushing it into the ingestion
scripts themselves.

## Tier 3 — Gold (`analytics` dataset): business-level aggregates

| Table/view | Built from | Purpose |
|---|---|---|
| `analytics.daily_weather_summary` | `curated.weather_observations` | Per city per day: avg/min/max temperature and humidity, most frequent conditions. |
| `analytics.air_quality_by_country` | `curated.air_quality_readings` | Per country: avg AQI, count of readings by category (Good/Moderate/…). |
| ~~`analytics.environment_overview`~~ | — | **Checked, not worth building as scoped.** Joining on city name alone is actively wrong here — the CSV has multiple same-named cities worldwide (a "Paris" in the US, a "Berlin" in El Salvador). Joining on city **and** country against the real target locations (Paris,FR / London,GB / Berlin,DE / New York,US) returns exactly **one** match: London, GB. Not enough overlap to be a meaningful demo table. Fixable by changing `WEATHER_LOCATIONS` to cities actually well-represented in the CSV instead of the arbitrary current four — worth doing only if this cross-source view specifically matters to you; otherwise skip it and keep the two gold tables above. |

## Tooling options — this is the actual decision to make

Two ways to build tiers 2 and 3, both fully GCP-native (no low-code
ingestion tool involved either way — this is a transform layer, not a new
ingestion source, so the brief's hard constraint isn't really in play
here, but sticking to GCP-native keeps the story consistent).

### Option A — BigQuery Scheduled Queries (recommended given the timeline)

Each silver/gold table is just a `CREATE OR REPLACE TABLE ... AS SELECT`
statement, scheduled via BigQuery's built-in Data Transfer Service
(`bq query --schedule=... --destination_table=...` or the Console UI).

**New GCP resources needed:**
- `bq mk curated` and `bq mk analytics` datasets.
- 4-5 scheduled query resources (one per table above).
- IAM: the Data Transfer Service runs queries under a service account of
  its own (created automatically per scheduled query, or you assign one) —
  it needs `roles/bigquery.dataEditor` on `curated`/`analytics` (source
  tables only need read, which `dataEditor` also covers) and
  `roles/bigquery.jobUser` at the project level (same reason `sftp-ingest`
  needed it — every scheduled query is a BigQuery Job).

**Effort:** low — maybe 1-2 hours including writing and testing the SQL.
No new service to learn, no new deployment mechanism, reuses everything
already set up.

### Option B — Dataform (the more "correct" GCP-native answer, more setup)

Dataform is Google Cloud's own SQL-transformation-as-code product —
version-controlled `.sqlx` files defining a dependency graph (bronze
sources → silver → gold), compiled and scheduled by Dataform itself. Worth
noting: `dataform.googleapis.com` is **already enabled** on this project
(visible in `gcloud services list --enabled`), so there's no new API to
turn on.

**New GCP resources needed:**
- `gcloud dataform repositories create` + a workspace.
- SQLX files: source declarations for the two bronze tables, then
  transformation files for each silver/gold table (dependencies declared
  via `ref()`, so Dataform builds the DAG automatically instead of you
  ordering scheduled queries by hand).
- A release configuration (compiles the SQLX) + workflow configuration
  (schedules execution) — Dataform's own scheduling, no separate Cloud
  Scheduler job needed for this layer.
- IAM: Dataform's service agent needs the same `dataEditor` (on
  `curated`/`analytics`) + project-level `bigquery.jobUser` as Option A.

**Effort:** medium-high — the payoff is a real, visualizable dependency
graph and transformation-as-code sitting in the same repo as the ingestion
functions, which is a stronger answer to "how would this scale" in
Monday's discussion, but it's a new tool to set up correctly under time
pressure, and mistakes here won't have the safety net of "just a SQL
query" to fall back on.

**Recommendation given the timeline:** build tiers 2-3 with Option A
(Scheduled Queries) to have something real and demoable, and describe
Option B verbally in the discussion as "the production answer, here's
what it would look like and why I didn't build it under this deadline" —
itself a legitimate architecture-choice talking point. Switch to Option B
first if there's meaningfully more time before Monday than expected.

## Sequencing if this gets built

1. Create `curated` and `analytics` datasets.
2. Grant IAM (dataEditor scoped to both new datasets, project-level
   jobUser) to whichever identity runs the transforms (a new
   `transform-runner-sa`, or the Scheduled Query default service account).
3. Write and test the two silver queries against real bronze data.
4. Write and test the gold queries against real silver data.
5. Schedule all of them (cadence should trail ingestion — e.g. run 15
   minutes after the hourly ingestion jobs, not at the same minute).
6. Document the DAG (even just a short paragraph + the table above) in
   `docs/architecture.md`.
