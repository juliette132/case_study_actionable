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

## Orchestration: why Cloud Workflows, once there was something to orchestrate

Until the transform layer (`bronze`/`silver`/`gold`) existed, there was no
real orchestration problem: `weather-ingest` and `sftp-ingest` run on
independent hourly Cloud Scheduler jobs with zero dependency between them.
The transform layer changes that — bronze needs ingestion to have run,
silver needs both bronze tables, gold needs silver — and none of that was
scheduled; it had only ever been run by hand.

**Options considered:**

| Option | Verdict |
|---|---|
| Give bronze/silver/gold their own Scheduler jobs at fixed time offsets | Rejected — no real dependency awareness; a slow or failed ingestion run still lets downstream jobs fire against stale/absent data, with no single place to halt the chain. |
| Cloud Composer (managed Airflow) | Rejected for this project's scale — needs a persistent GKE-backed environment running 24/7, realistically $300+/month even minimally sized, which would consume most of the free credit just to stay idle between hourly runs. Right tool for many interdependent pipelines with complex scheduling; disproportionate here. |
| Pub/Sub event-driven chaining (each step publishes "done", next step Eventarc-triggered) | Valid GCP-native pattern, but the fan-in (wait for *both* weather and SFTP before bronze runs) needs extra state — a Firestore doc or BigQuery flag row — to coordinate the join. Real added complexity for no clear benefit over the option below. |
| **Cloud Workflows** | **Chosen** — GCP-native, serverless (no idle cost: ~5,000 free internal steps/month, ~$0.01/1,000 after), gives real dependency-aware sequencing, built-in retry policies, and one execution log per run instead of correlating two Cloud Functions' logs with however many separate BigQuery job IDs by hand. |

**Deployed and verified live** (2026-09-13): `gcloud workflows run pipeline`
returned `state: SUCCEEDED`, `bronze.weather`'s freshest `ingested_at`
matched the execution's own start time exactly, and `silver`/the gold
views held the expected 40 rows. Getting there surfaced four more real
bugs — none visible from reading the YAML/script, only from actually
running them:
1. The `init` step's `assign` block had all 7 variables under one list
   entry (`- key: val` repeated as multiple keys of one item); Workflows
   requires exactly one assignment per list entry. Rejected at deploy
   time with a clear parse error — fixed by splitting each into its own
   `-` entry.
2. `gcloud workflows add-iam-policy-binding` does not exist — confirmed
   by checking `gcloud workflows --help` in both GA and beta, neither
   has any IAM subcommand for this resource type. Granted
   `roles/workflows.invoker` at the **project** level instead (only one
   workflow exists in this project, so the practical scope difference is
   negligible; a resource-scoped binding would need a raw REST call).
3. `sys.log` calls failed with `403 logging.logEntries.create` even
   after granting `workflow-runner-sa` (the workflow's own runtime
   identity) `roles/logging.logWriter` — the identical error persisted
   until a **second**, separate grant was made to
   `service-{project_number}@gcp-sa-workflows.iam.gserviceaccount.com`,
   a Google-managed service agent auto-created when the Workflows API
   was enabled, which turns out to be what actually performs the log
   write on the control plane's behalf.
4. `build_bronze` failed with `403 Access Denied` on `raw_data.import_weather`
   / `raw_data.import_csv_data` — the IAM grants had covered writing to
   `bronze`/`silver`/`analytics`, but nothing had granted **read** access
   to `raw_data`, the dataset bronze actually queries *from*. Fixed with
   `roles/bigquery.dataViewer` scoped to `raw_data`.

**Design:** ingest weather + SFTP in parallel → bronze (2 tables,
parallel) → silver. Gold is **views**, not tables (see below) — nothing
gold-related runs in the recurring workflow at all. SQL is read from
Cloud Storage at runtime (`scripts/deploy_workflow.sh` syncs `sql/` to a
GCS bucket on deploy) rather than duplicated inline in the workflow YAML,
so `sql/*.sql` stays
the single source of truth.

**Gold is views, not materialized tables — a correction from an earlier
draft.** `analytics.*` is queried, not scheduled: a view has no stored
data of its own to refresh, so it always reflects whatever `silver`
currently holds, with no build step, no staleness risk from a missed
run, and no orchestration needed for it at all. `scripts/deploy_workflow.sh`
runs each `CREATE OR REPLACE VIEW` once at deploy time (cheap to also
re-run any time a view definition changes). The heavier queries here (a
40×40 self cross-join with `ST_DISTANCE` for the geographic-proximity
views) are trivial to recompute per query at this data volume, so there's
no materialization case to make on performance grounds either.

**Error handling, worked through concretely, not just asserted:**
- Each ingestion call gets its own retry (Workflows' default predicate
  retries transient network errors and 429/502/503/504 — deliberately
  *not* a 500 from our own function, since that means something like
  Secret Manager being down, and blindly retrying won't fix a real
  outage; better to fail fast and mark that source down for the run).
- **The workflow aborts before touching bronze/silver if *either* source
  failed this run — a correction from an earlier draft that only aborted
  if *both* failed.** The original reasoning ("bronze/silver/gold are
  full-refresh, so a partial run just reflects one fresh source and one
  stale one") missed that silver is a *join* of both bronze tables and
  gold reads from silver — a run with only one source fresh doesn't
  produce a result that's "current for one side," it produces a joined
  output that silently mixes this run's fresh data with a stale
  carry-over on the other side. That's a misleading result, not merely an
  incomplete one, so requiring both sources to succeed before rebuilding
  the transform layer is the correct gate.

**Idempotency at this layer is close to free**, and worth naming as a
payoff of an earlier design choice: because bronze/silver are full-refresh
CTAS (and gold is a live view), re-running the workflow (after a retry, or
a manual re-trigger) just recomputes from current state — no risk of
duplicate/accumulating rows the way the append-only `raw_data.*` tables
needed explicit `insertId`/content-hash dedup for.

**Operational change this makes:** the two existing per-function
Scheduler jobs (`weather-ingest-schedule`, `sftp-ingest-schedule`) get
paused (not deleted — reversible) in favor of one `pipeline-schedule` job
that triggers a Workflow execution, which then calls both functions
itself in the right order.

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
  default compute service account), granted:
  - `roles/bigquery.dataEditor` scoped to the `raw_data` **dataset**, not the
    project (create/update tables and insert/stream data — nothing else).
    Granted via the dataset's own access-control list
    (`scripts/grant_dataset_access.py`), not `bq add-iam-policy-binding` —
    that command returned "This feature requires allowlisting" on this
    project; the ACL mechanism is the older, always-available equivalent.
  - `roles/secretmanager.secretAccessor` scoped to that function's **one**
    secret (`openweather-api-key`, or the SFTP password/key secret) — not
    the project, and not the other function's secret.
  - **`sftp-ingest` only**: `roles/bigquery.jobUser` at the **project**
    level — necessary, not a looser choice. This function runs `LOAD` and
    `QUERY` jobs (the CSV load, and the content-hash dedup check); a
    BigQuery Job is a project-scoped resource with no dataset-scoped
    equivalent for `bigquery.jobs.create`, unlike `weather-ingest`'s plain
    streaming inserts (`tabledata.insertAll`), which only need
    dataset-level `dataEditor`. Confirmed live: without this,
    `sftp-ingest` failed with `403 ... does not have
    bigquery.jobs.create permission`.
- Both functions are deployed with `--no-allow-unauthenticated`; only Cloud
  Scheduler's own service account (granted invoker rights) can call them.
- **`GCP_PROJECT_ID` is passed explicitly via `--set-env-vars`/
  `--update-env-vars` on both functions.** Despite Cloud Functions
  docs/folklore suggesting `GOOGLE_CLOUD_PROJECT` is auto-populated on
  gen2, a live deploy failed with a `RuntimeError` until it was set
  explicitly — don't rely on that assumption.

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
