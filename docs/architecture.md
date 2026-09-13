# Architecture & design notes

## Sources → destination

| Source | Auth | Status |
|---|---|---|
| OpenWeatherMap current-weather API | API key in Secret Manager | Built, tested against real GCP project |
| SFTP server (CSV files) | password/key in Secret Manager (SFTPCloud) | Built, tested against real SFTPCloud instance + a real Kaggle CSV |

Both land in BigQuery, in the `raw_data` dataset, in the same project (`case-study-act`).

## Why Cloud Functions (2nd gen) + Cloud Scheduler, not Dataflow/Composer

This is a small number of low-volume, independent batch sources on a fixed
schedule (poll a REST API a few times a day; pick up new CSVs from an SFTP
drop). That's a poor fit for Dataflow (built for large-scale/streaming
transforms) or Composer (orchestrating many interdependent tasks/DAGs) —
both would add real operational and cost overhead for no benefit here.

A small HTTP-triggered Cloud Function per source, invoked by Cloud Scheduler,
gets the same outcome with:
- **Serverless ops** — nothing to patch/scale, pay only per invocation (fits
  comfortably in the free-tier credit).
- **Isolated failure domains** — the weather ingestion breaking doesn't touch
  the SFTP ingestion, and each shows up separately in Cloud Logging.
- **A trivial mental model** for the Monday discussion: one function, one
  job, one table, one clear failure surface.

If either source grew into many interdependent stages needing DAG-level
retries/backfills, Cloud Composer would be the natural next step — noted
here as a deliberate "not yet, and here's the trigger for reconsidering."

## Landing table design: a light bronze/silver hybrid

`raw_data.import_weather` stores both:
- **Flattened key fields** (temperature, humidity, description, coordinates,
  timestamps, …) — directly queryable, no JSON parsing needed for a first
  dashboard/BI pass.
- **The full raw JSON response**, in `raw_response` — so if a future
  transform needs a field that wasn't flattened, or a bug in the flattening
  logic needs correcting, the source data can be reprocessed without
  re-calling the API for historical rows.

This is the "optional stretch" bronze/silver idea taken partway, without
building out a full separate bronze table + dbt-style silver/gold layer for
what is, right now, a single small landing table. If the SFTP source and a
real transform layer both land, promoting `raw_response` into its own bronze
table (append-only, immutable) with `import_weather` becoming a silver view
over it is the natural next step (see Roadmap).

Every column is **NULLABLE** by design:
1. BigQuery only allows *adding* NULLABLE columns to an existing table via a
   schema update — a REQUIRED column can only be set at creation time. Since
   this script is meant to be able to adopt a pre-existing, differently-shaped
   (or empty) table rather than assume it always creates one from scratch,
   REQUIRED fields would make that self-healing behavior fail.
2. A raw landing table shouldn't reject an entire row just because the
   source API omitted one field on a given call.

## Idempotence

Each row's BigQuery `insertId` (via `insert_rows_json(..., row_ids=...)`) is
a deterministic hash of `(location, observed_at)`. Re-running the function
for a location/observation BigQuery has already seen is a best-effort no-op —
BigQuery de-duplicates on `insertId` within a short window (not a hard
guarantee long-term, but enough to make retries after a Scheduler timeout or
a transient network blip safe rather than duplicating data).

## Error handling

- Each location is fetched/parsed independently inside a `try/except`; one
  bad city (typo, OpenWeatherMap outage for that query) doesn't fail the
  whole run — it's reported back in the result instead, and the rest still
  land.
- The function returns HTTP 200 on a fully clean run, 207 on partial failure
  (some locations failed), 500 on a systemic failure (e.g. Secret Manager or
  BigQuery unreachable). Cloud Scheduler's retry policy
  (`--max-retry-attempts` / `--max-retry-duration`, configured on the job)
  should be set to retry on 5xx but not on 207 — a partial failure on one
  city is a data-quality signal to look at, not something blindly retried.

## SFTP CSV ingestion design

Same overall shape as the weather function (fetch → load → BigQuery,
per-item error isolation, HTTP 200/207/500), with two differences forced by
the source being files rather than a JSON API:

- **Schema**: rather than hand-writing a schema for whatever CSV dataset
  ends up on the SFTP server, the BigQuery load job runs with
  `autodetect=True` — BigQuery's own CSV parser infers types from the
  header and first rows. Simpler and more robust than reimplementing CSV
  type inference, and means the script doesn't need to know the dataset
  shape ahead of time.
- **Idempotence**: a streaming API call has a natural per-row `insertId` to
  dedup on; a file load job doesn't have an equivalent built in. Instead,
  every file's SHA-256 content hash is looked up in a small control table
  (`raw_data._ingested_files`, created on first run) before loading, and
  recorded after a successful load. Re-running against files already seen —
  by content, not just by name, so a re-uploaded identical file doesn't
  reload either — is a no-op. This also naturally supports dropping new
  files into the same SFTP directory over time: only the new ones get
  loaded on each scheduled run.

## Security / IAM

- The OpenWeatherMap key and the SFTP password/key live only in Secret
  Manager, never in code, env files committed to the repo, or the Cloud
  Function's source.
- Each deployed function runs under its **own** service account (not the
  default compute service account), granted only:
  - `roles/bigquery.dataEditor` scoped to the `raw_data` **dataset**, not the
    project (create/update tables and insert rows — nothing else).
  - `roles/secretmanager.secretAccessor` scoped to that function's **one**
    secret (`openweather-api-key`, or the SFTP password/key secret) — not
    the project, and not the other function's secret.
- Both functions are deployed with `--no-allow-unauthenticated`; only Cloud
  Scheduler's own service account (granted invoker rights) can call them.

## Monitoring

- Cloud Functions logs go to Cloud Logging automatically — the structured
  `logger.info(...)` result summary (locations requested/inserted, per-city
  errors) is queryable there without extra setup.
- Cloud Scheduler's job history page shows run outcomes (success / failure
  code) at a glance — the cheapest possible "did today's ingestion happen"
  check.
- For the SFTP source specifically, `raw_data._ingested_files` itself is a
  free audit trail: which files came in, when, and how many rows each
  produced — useful for "did we actually pick up today's file" without
  digging through logs.
- Suggested next step (not yet built): a log-based Cloud Monitoring alert on
  a 500 response or on `bigquery_errors`/`errors` being non-empty for either
  function, notifying by email.

## Deploying

Deploy commands live in `scripts/deploy_weather.sh` and
`scripts/deploy_sftp.sh` — reviewed and ready, but **not executed from this
session** (deploying is a deliberate call to make once the code and IAM
scoping have been read over, not something to run automatically). Each
script creates its function's dedicated service account, scopes it to
exactly the dataset/secret it needs, deploys the function
(`--no-allow-unauthenticated`), and creates its Cloud Scheduler job. Flag any
flag/runtime-name drift against `gcloud functions deploy --help` before
running — they're written from documented syntax, not from a live deploy in
this project.

`europe-west1` is used in both scripts because the existing `raw_data`
dataset is in the `EU` multi-region — keep the function/scheduler region and
the BigQuery dataset location in the same geography to avoid cross-region
latency/egress.

## Roadmap

1. Set up the SFTPCloud account, pick a CSV dataset, upload it — the one
   piece here that isn't a coding task.
2. Run `scripts/deploy_weather.sh` and `scripts/deploy_sftp.sh` for real,
   confirm an end-to-end scheduled run for both.
3. If a transform layer is worth adding: promote `raw_response` into an
   append-only bronze table, add a scheduled query or view as the silver
   layer doing typed/deduplicated output, and a gold aggregate (e.g. daily
   min/max/avg per city) if there's a concrete downstream use for it.
4. Monitoring alert policy (see above).
