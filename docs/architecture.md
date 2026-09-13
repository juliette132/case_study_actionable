# Architecture & design notes

## Sources → destination

| Source | Auth | Status |
|---|---|---|
| OpenWeatherMap current-weather API | API key in Secret Manager | Built, tested against real GCP project |
| SFTP server (CSV files) | TBD (SFTPCloud) | Not started |

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

## Security / IAM

- The OpenWeatherMap key lives only in Secret Manager, never in code, env
  files committed to the repo, or the Cloud Function's source.
- The deployed function should run under its **own** service account (not
  the default compute service account), granted only:
  - `roles/bigquery.dataEditor` scoped to the `raw_data` **dataset**, not the
    project (create/update tables and insert rows — nothing else).
  - `roles/secretmanager.secretAccessor` scoped to the
    `openweather-api-key` **secret**, not the project.
- The function itself is deployed with `--no-allow-unauthenticated`; only
  Cloud Scheduler's own service account (granted invoker rights) can call it.

## Monitoring

- Cloud Functions logs go to Cloud Logging automatically — the structured
  `logger.info(...)` result summary (locations requested/inserted, per-city
  errors) is queryable there without extra setup.
- Cloud Scheduler's job history page shows run outcomes (success / failure
  code) at a glance — the cheapest possible "did today's ingestion happen"
  check.
- Suggested next step (not yet built): a log-based Cloud Monitoring alert on
  a 500 response or on `bigquery_errors` being non-empty, notifying by email.

## Deploying (documented here; not yet run from this repo)

These commands are written from the documented `gcloud` syntax but haven't
been executed — the CLI was only installed/authenticated in this session to
run and verify the ingestion script itself. Flag any flag/runtime-name drift
against `gcloud functions deploy --help` before running for real.

```bash
# One-off: dedicated least-privilege service account for the function.
gcloud iam service-accounts create weather-ingest-sa \
  --display-name="Weather ingestion Cloud Function"

# Dataset-scoped BigQuery access (not project-wide).
bq add-iam-policy-binding \
  --member="serviceAccount:weather-ingest-sa@case-study-act.iam.gserviceaccount.com" \
  --role="roles/bigquery.dataEditor" \
  case-study-act:raw_data

# Secret-scoped Secret Manager access (not project-wide).
gcloud secrets add-iam-policy-binding openweather-api-key \
  --member="serviceAccount:weather-ingest-sa@case-study-act.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# Deploy the function itself.
gcloud functions deploy weather-ingest \
  --gen2 \
  --runtime=python312 \
  --region=europe-west1 \
  --source=functions/weather_ingest \
  --entry-point=weather_ingest \
  --trigger-http \
  --no-allow-unauthenticated \
  --service-account=weather-ingest-sa@case-study-act.iam.gserviceaccount.com

# Let Cloud Scheduler invoke it.
gcloud functions add-invoker-policy-binding weather-ingest \
  --region=europe-west1 \
  --member="serviceAccount:weather-ingest-sa@case-study-act.iam.gserviceaccount.com"

# Schedule it (every hour, on the hour).
gcloud scheduler jobs create http weather-ingest-schedule \
  --location=europe-west1 \
  --schedule="0 * * * *" \
  --uri="$(gcloud functions describe weather-ingest --gen2 --region=europe-west1 --format='value(serviceConfig.uri)')" \
  --http-method=POST \
  --oidc-service-account-email=weather-ingest-sa@case-study-act.iam.gserviceaccount.com
```

Note: `europe-west1` is used above because the existing `raw_data` dataset
is in the `EU` multi-region — keep the function/scheduler region and the
BigQuery dataset location in the same geography to avoid cross-region
latency/egress.

## Roadmap

1. SFTP/CSV ingestion, same pattern (Cloud Function + Scheduler), into its
   own `raw_data` landing table.
2. Deploy the weather function + Scheduler job for real (commands above),
   confirm an end-to-end scheduled run.
3. If a transform layer is worth adding: promote `raw_response` into an
   append-only bronze table, add a scheduled query or view as the silver
   layer doing typed/deduplicated output, and a gold aggregate (e.g. daily
   min/max/avg per city) if there's a concrete downstream use for it.
4. Monitoring alert policy (see above).
