# case_study_actionable

GCP-native ingestion pipeline built for Actionable's take-home exercise:
two sources (a keyed public API, and SFTP-hosted CSVs) landing in BigQuery,
using only hand-written pipeline code — no turnkey/low-code ingestion tools.

GCP project: `case-study-act`.

## Status

- [x] OpenWeatherMap API → BigQuery (`raw_data.import_weather`) — built, run
      once against the real project, see `docs/ai_usage_log.md` for details
- [ ] SFTP CSVs → BigQuery
- [ ] Deployed as a scheduled Cloud Function (currently local-only; deploy
      commands are documented but unexecuted, see `docs/architecture.md`)
- [ ] Optional: bronze/silver/gold transform layer

## Repo layout

```
functions/
  weather_ingest/
    main.py            # ingestion logic + Cloud Function entry point
    requirements.txt
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

## Deploying as a Cloud Function + Cloud Scheduler

Not done yet. Commands are written out in `docs/architecture.md` (service
account creation, least-privilege IAM bindings, `gcloud functions deploy`,
Cloud Scheduler job) but haven't been run — review them against
`gcloud functions deploy --help` before using, since they were documented
rather than executed.

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
