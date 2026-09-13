# case_study_actionable

GCP-native ingestion pipeline built for Actionable's take-home exercise:
two sources (a keyed public API, and SFTP-hosted CSVs) landing in BigQuery,
using only hand-written pipeline code — no turnkey/low-code ingestion tools.

GCP project: `case-study-act`.

## Status

- [x] OpenWeatherMap API → BigQuery (`raw_data.import_weather`) — built, run
      once against the real project, see `docs/ai_usage_log.md` for details
- [ ] SFTP CSVs → BigQuery — code built (`functions/sftp_ingest/`), untested:
      no SFTPCloud account/dataset exists yet
- [ ] Deployed as scheduled Cloud Functions (currently local-only; deploy
      scripts are written and reviewed but not run, see `scripts/`)
- [ ] Optional: bronze/silver/gold transform layer

## Repo layout

```
functions/
  weather_ingest/
    main.py            # ingestion logic + Cloud Function entry point
    requirements.txt
  sftp_ingest/
    main.py            # ingestion logic + Cloud Function entry point
    requirements.txt
scripts/
  deploy_weather.sh      # gcloud deploy commands, reviewed, not yet run
  deploy_sftp.sh          # same, for the SFTP function
docs/
  architecture.md       # design rationale, IAM, deploy commands, roadmap
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

Needs an SFTP account and a CSV file uploaded first (not yet set up — see
Status above). Once `.env` has `SFTP_HOST`/`SFTP_USERNAME`/etc. filled in
and the password or key stored in Secret Manager:

```
pip install -r functions/sftp_ingest/requirements.txt
python functions/sftp_ingest/main.py
```

Lists CSV files in `SFTP_REMOTE_DIR`, skips any whose content hash is
already recorded in `raw_data._ingested_files`, and loads the rest into
`raw_data.import_csv_data` (schema auto-detected from the CSV header).

## Deploying as Cloud Functions + Cloud Scheduler

Not done yet. `scripts/deploy_weather.sh` and `scripts/deploy_sftp.sh`
create each function's dedicated service account, scope its IAM to exactly
the dataset/secret it needs, deploy the function
(`--no-allow-unauthenticated`), and create its Cloud Scheduler job. Written
and reviewed, not executed — review against `gcloud functions deploy --help`
before running, and fill in the `SFTP_*` placeholders in
`deploy_sftp.sh` once that account exists.

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
