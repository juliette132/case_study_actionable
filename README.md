# case_study_actionable

GCP-native ingestion pipeline built for Actionable's take-home exercise:
two sources (a keyed public API, and SFTP-hosted CSVs) landing in BigQuery,
using only hand-written pipeline code — no turnkey/low-code ingestion tools.

GCP project: `case-study-act`.

## Status

- [x] OpenWeatherMap API → BigQuery (`raw_data.import_weather`) — built and
      verified, see `docs/ai_usage_log.md` for details
- [x] SFTP CSVs → BigQuery (`raw_data.import_csv_data`) — built and verified
      against a real SFTPCloud instance with a real Kaggle CSV (23,463 rows,
      the [Global Air Pollution dataset](https://www.kaggle.com/datasets/hasibalmuzdadid/global-air-pollution-dataset));
      dedup-on-rerun verified live too
- [x] Deployed as scheduled Cloud Functions + Cloud Scheduler, both
      running hourly (`0 * * * *`) in `europe-west1`. Four real bugs
      surfaced only by actually deploying (not by review) and are fixed in
      `scripts/` — see `docs/ai_usage_log.md` and `docs/architecture.md`
      ("Security / IAM") for what they were.
- [~] Optional: bronze/silver/gold transform layer — **bronze built and
      tested** (`bronze.weather`, `bronze.air_quality`,
      `bronze.country_code_map`); silver and gold not started yet. See
      `docs/transform_layer_plan.md`.

## Repo layout

```
functions/
  weather_ingest/
    main.py            # ingestion logic + Cloud Function entry point
    requirements.txt
  sftp_ingest/
    main.py            # ingestion logic + Cloud Function entry point
    requirements.txt
sql/
  bronze/
    weather.sql               # bronze.weather build query
    air_quality.sql            # bronze.air_quality build query
    country_to_iso_udf.sql      # console convenience only, unused by the pipeline
scripts/
  deploy_weather.sh      # gcloud deploy commands, reviewed, not yet run
  deploy_sftp.sh          # same, for the SFTP function
  build_country_code_map.py  # builds bronze.country_code_map from real data
docs/
  architecture.md       # design rationale, IAM, deploy commands, roadmap
  transform_layer_plan.md  # bronze/silver/gold design, decisions, test results
  ai_usage_log.md        # mandatory AI-usage documentation for the exercise
.env.example              # config template — copy to .env for local runs
```

## Prerequisites

- Python 3.12+ (this was developed/tested against 3.14)
- The `gcloud` CLI, authenticated against the `case-study-act` project:
  ```
  gcloud auth login
  gcloud config set project case-study-act
  gcloud auth application-default login
  ```
  The last command is what lets the Python client libraries (BigQuery,
  Secret Manager) authenticate locally — it's separate from `gcloud auth
  login`, which only authenticates the CLI itself.
- Access to the `case-study-act` GCP project (you need at least read access
  to the `openweather-api-key` secret and write access to the `raw_data`
  dataset — see `docs/architecture.md` for the precise IAM roles).
- For the SFTP ingestion: an SFTP account (e.g. SFTPCloud) with a CSV file
  uploaded, and its password or private key stored in Secret Manager — not
  yet set up (see Status above).

## Running the weather ingestion locally

```
python -m venv .venv
.venv\Scripts\activate          # Windows
pip install -r functions/weather_ingest/requirements.txt

$env:GCP_PROJECT_ID = "case-study-act"    # or copy .env.example to .env
python functions/weather_ingest/main.py
```

It fetches the API key from Secret Manager, calls OpenWeatherMap for each
location in `WEATHER_LOCATIONS` (see `.env.example`), and inserts the
results into `raw_data.import_weather`, creating/patching the table's schema
if needed. Prints a JSON summary (locations requested, rows inserted, any
per-location or BigQuery errors) and exits 0 even on partial failure —
check the summary, not just the exit code.

To inspect what landed:
```
bq query --use_legacy_sql=false \
  "SELECT * FROM \`raw_data.import_weather\` ORDER BY ingested_at DESC LIMIT 20"
```

## Running the SFTP ingestion locally

Needs `SFTP_HOST`/`SFTP_USERNAME`/etc. set (see `.env.example`) and the
password or key stored in Secret Manager:

```
pip install -r functions/sftp_ingest/requirements.txt
python functions/sftp_ingest/main.py
```

Lists CSV files in `SFTP_REMOTE_DIR`, skips any whose content hash is
already recorded in `raw_data._ingested_files`, and loads the rest into
`raw_data.import_csv_data` (schema auto-detected from the CSV header).

## Deploying as Cloud Functions + Cloud Scheduler

Both are deployed and running hourly. `scripts/deploy_weather.sh` and
`scripts/deploy_sftp.sh` create each function's dedicated service account,
scope its IAM to exactly the dataset/secret/job-permission it needs, deploy
the function (`--no-allow-unauthenticated`), and create/update its Cloud
Scheduler job — safe to re-run.

Before running `deploy_sftp.sh`, export the real SFTP values as env vars
first (don't hardcode them — this repo is public):
```
export SFTP_HOST="your-instance.sftpcloud.io"
export SFTP_USERNAME="your-username"
bash scripts/deploy_sftp.sh
```

Four real issues only surfaced by actually deploying, all now fixed in the
scripts (see `docs/architecture.md` "Security / IAM" and
`docs/ai_usage_log.md` for the full story):
1. `bq add-iam-policy-binding` on a dataset needs Google allowlisting this
   project doesn't have — replaced with `scripts/grant_dataset_access.py`
   (the older ACL mechanism).
2. `GOOGLE_CLOUD_PROJECT` is not reliably auto-set on gen2 despite
   docs/folklore suggesting otherwise — `GCP_PROJECT_ID` is now always
   passed explicitly via `--set-env-vars`.
3. `sftp-ingest` needs `roles/bigquery.jobUser` at the **project** level
   (not just dataset-scoped `dataEditor`) because it runs LOAD/QUERY jobs,
   which are project-scoped resources in BigQuery — unlike
   `weather-ingest`'s plain streaming inserts.
4. Running the deploy script from Git Bash on Windows can mangle a bare
   `/` argument into a Windows path (MSYS path conversion) — if
   `SFTP_REMOTE_DIR` comes out wrong, fix it from PowerShell instead (see
   the comment in `deploy_sftp.sh`).

To manually trigger either job instead of waiting for the schedule:
```
gcloud scheduler jobs run weather-ingest-schedule --location=europe-west1
gcloud scheduler jobs run sftp-ingest-schedule --location=europe-west1
```

## Design notes

See `docs/architecture.md` for why Cloud Functions + Cloud Scheduler over
Dataflow/Composer, the landing-table schema rationale, idempotence,
error-handling, IAM, and monitoring approach — the material for Monday's
resilience/maintenance/monitoring discussion.

## AI usage

This project was built with Claude Code throughout. Per the exercise's
mandatory requirement, `docs/ai_usage_log.md` tracks prompts used, what was
generated, and — the more important part — where the output was trusted
as-is versus corrected or questioned.
