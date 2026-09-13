#!/usr/bin/env bash
# Deploys the SFTP CSV ingestion function + its Cloud Scheduler job.
#
# NOT run automatically by anything in this repo — review, then run
# yourself: `bash scripts/deploy_sftp.sh`. Requires `gcloud` authenticated
# against PROJECT_ID below, and the SFTP account/secret already created
# (see README / .env.example) — fill in the SFTP_* values below first.
set -euo pipefail

PROJECT_ID="case-study-act"
REGION="europe-west1"           # same geography as the raw_data dataset (EU)
FUNCTION_NAME="sftp-ingest"
SERVICE_ACCOUNT="sftp-ingest-sa@${PROJECT_ID}.iam.gserviceaccount.com"
SCHEDULE="0 * * * *"            # every hour, on the hour — adjust as needed

# --- fill these in once the SFTP account exists ---
SFTP_HOST="CHANGE_ME.sftpcloud.io"
SFTP_USERNAME="CHANGE_ME"
SFTP_REMOTE_DIR="/"
# Whichever one of these two you actually created a secret for; leave the
# other blank. Matches SFTP_PASSWORD_SECRET_NAME / SFTP_PRIVATE_KEY_SECRET_NAME
# in .env.example.
SFTP_SECRET_NAME="sftp-password"
SFTP_AUTH_ENV_VAR="SFTP_PASSWORD_SECRET_NAME"   # or SFTP_PRIVATE_KEY_SECRET_NAME

echo "== Service account =="
gcloud iam service-accounts create sftp-ingest-sa \
  --project="${PROJECT_ID}" \
  --display-name="SFTP CSV ingestion Cloud Function" \
  || echo "(already exists, continuing)"

echo "== Dataset-scoped BigQuery access (not project-wide) =="
bq add-iam-policy-binding \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/bigquery.dataEditor" \
  "${PROJECT_ID}:raw_data"

echo "== Secret-scoped Secret Manager access (not project-wide) =="
gcloud secrets add-iam-policy-binding "${SFTP_SECRET_NAME}" \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/secretmanager.secretAccessor"

echo "== Deploy the function =="
gcloud functions deploy "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" \
  --gen2 \
  --runtime=python312 \
  --region="${REGION}" \
  --source=functions/sftp_ingest \
  --entry-point=sftp_ingest \
  --trigger-http \
  --no-allow-unauthenticated \
  --service-account="${SERVICE_ACCOUNT}" \
  --set-env-vars="SFTP_HOST=${SFTP_HOST},SFTP_USERNAME=${SFTP_USERNAME},SFTP_REMOTE_DIR=${SFTP_REMOTE_DIR},${SFTP_AUTH_ENV_VAR}=${SFTP_SECRET_NAME}"

echo "== Let Cloud Scheduler invoke it =="
gcloud functions add-invoker-policy-binding "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --member="serviceAccount:${SERVICE_ACCOUNT}"

FUNCTION_URI=$(gcloud functions describe "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" --gen2 --region="${REGION}" \
  --format='value(serviceConfig.uri)')

echo "== Schedule it (${SCHEDULE}) =="
gcloud scheduler jobs create http sftp-ingest-schedule \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --schedule="${SCHEDULE}" \
  --uri="${FUNCTION_URI}" \
  --http-method=POST \
  --oidc-service-account-email="${SERVICE_ACCOUNT}"

echo "Done. Function URI: ${FUNCTION_URI}"
