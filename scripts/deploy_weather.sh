#!/usr/bin/env bash
# Deploys the weather ingestion function + its Cloud Scheduler job.
#
# NOT run automatically by anything in this repo — review, then run
# yourself: `bash scripts/deploy_weather.sh`. Requires `gcloud` authenticated
# against PROJECT_ID below (see README "Prerequisites").
set -euo pipefail

PROJECT_ID="case-study-act"
REGION="europe-west1"           # same geography as the raw_data dataset (EU)
FUNCTION_NAME="weather-ingest"
SERVICE_ACCOUNT="weather-ingest-sa@${PROJECT_ID}.iam.gserviceaccount.com"
SCHEDULE="0 * * * *"            # every hour, on the hour — adjust as needed

echo "== Service account =="
gcloud iam service-accounts create weather-ingest-sa \
  --project="${PROJECT_ID}" \
  --display-name="Weather ingestion Cloud Function" \
  || echo "(already exists, continuing)"

echo "== Dataset-scoped BigQuery access (not project-wide) =="
bq add-iam-policy-binding \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/bigquery.dataEditor" \
  "${PROJECT_ID}:raw_data"

echo "== Secret-scoped Secret Manager access (not project-wide) =="
gcloud secrets add-iam-policy-binding openweather-api-key \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/secretmanager.secretAccessor"

echo "== Deploy the function =="
gcloud functions deploy "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" \
  --gen2 \
  --runtime=python312 \
  --region="${REGION}" \
  --source=functions/weather_ingest \
  --entry-point=weather_ingest \
  --trigger-http \
  --no-allow-unauthenticated \
  --service-account="${SERVICE_ACCOUNT}"

echo "== Let Cloud Scheduler invoke it =="
gcloud functions add-invoker-policy-binding "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --member="serviceAccount:${SERVICE_ACCOUNT}"

FUNCTION_URI=$(gcloud functions describe "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" --gen2 --region="${REGION}" \
  --format='value(serviceConfig.uri)')

echo "== Schedule it (${SCHEDULE}) =="
gcloud scheduler jobs create http weather-ingest-schedule \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --schedule="${SCHEDULE}" \
  --uri="${FUNCTION_URI}" \
  --http-method=POST \
  --oidc-service-account-email="${SERVICE_ACCOUNT}"

echo "Done. Function URI: ${FUNCTION_URI}"
