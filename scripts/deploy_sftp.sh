#!/usr/bin/env bash
# Deploys the SFTP CSV ingestion function + its Cloud Scheduler job.
#
# NOT run automatically by anything in this repo — review, then run
# yourself: `bash scripts/deploy_sftp.sh`. Requires `gcloud` authenticated
# against PROJECT_ID below.
#
# This repo is PUBLIC — do not commit real SFTP_HOST/SFTP_USERNAME values
# here even though the password itself stays in Secret Manager; fill them
# in locally (uncommitted) before running, e.g. by exporting them as env
# vars just before `bash scripts/deploy_sftp.sh`, or in a local copy that
# stays untracked.
#
# Windows/Git Bash gotcha, confirmed by a real deploy: MSYS auto-converts a
# bare "/" argument into a Windows path (e.g. "C:/Program Files/Git/")
# before gcloud ever sees it. If SFTP_REMOTE_DIR ends up wrong after
# running this from Git Bash, fix it from PowerShell instead:
#   gcloud functions deploy sftp-ingest --project=PROJECT_ID --gen2 \
#     --region=REGION --source=functions/sftp_ingest \
#     --update-env-vars="SFTP_REMOTE_DIR=/"
# (setting MSYS_NO_PATHCONV=1 is NOT a safe fix here — it also breaks
# gcloud's own bash launcher script, confirmed by trying it.)
set -euo pipefail

PROJECT_ID="case-study-act"
REGION="europe-west1"           # same geography as the raw_data dataset (EU)
FUNCTION_NAME="sftp-ingest"
SERVICE_ACCOUNT="sftp-ingest-sa@${PROJECT_ID}.iam.gserviceaccount.com"
SCHEDULE="0 * * * *"            # every hour, on the hour — adjust as needed

# --- fill these in (or export as env vars before running — see note above) ---
SFTP_HOST="${SFTP_HOST:-CHANGE_ME.sftpcloud.io}"
SFTP_USERNAME="${SFTP_USERNAME:-CHANGE_ME}"
SFTP_REMOTE_DIR="${SFTP_REMOTE_DIR:-/}"
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
# bq add-iam-policy-binding on a dataset requires allowlisting Google hasn't
# granted this project ("This feature requires allowlisting") - using the
# older ACL-based equivalent instead. Needs google-cloud-bigquery installed
# (e.g. run from inside .venv).
python scripts/grant_dataset_access.py "${PROJECT_ID}" raw_data "${SERVICE_ACCOUNT}"

echo "== Project-level bigquery.jobUser (required - not a looser choice) =="
# Unlike the weather function's streaming inserts, this function runs LOAD
# and QUERY jobs (load_csv, already_ingested). BigQuery jobs are
# project-scoped resources with no dataset-level equivalent permission -
# confirmed live: dataEditor alone gave "403 ... does not have
# bigquery.jobs.create permission" on the real deploy.
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/bigquery.jobUser" \
  --condition=None \
  > /dev/null
echo "Granted roles/bigquery.jobUser (project-level) to ${SERVICE_ACCOUNT}"

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
  --set-env-vars="GCP_PROJECT_ID=${PROJECT_ID},SFTP_HOST=${SFTP_HOST},SFTP_USERNAME=${SFTP_USERNAME},SFTP_REMOTE_DIR=${SFTP_REMOTE_DIR},${SFTP_AUTH_ENV_VAR}=${SFTP_SECRET_NAME}"

echo "== Let Cloud Scheduler invoke it =="
gcloud functions add-invoker-policy-binding "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --member="serviceAccount:${SERVICE_ACCOUNT}"

FUNCTION_URI=$(gcloud functions describe "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" --gen2 --region="${REGION}" \
  --format='value(serviceConfig.uri)')

echo "== Schedule it (${SCHEDULE}) =="
SCHEDULER_ACTION="create"
gcloud scheduler jobs describe sftp-ingest-schedule --project="${PROJECT_ID}" --location="${REGION}" &>/dev/null \
  && SCHEDULER_ACTION="update"
gcloud scheduler jobs "${SCHEDULER_ACTION}" http sftp-ingest-schedule \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --schedule="${SCHEDULE}" \
  --uri="${FUNCTION_URI}" \
  --http-method=POST \
  --oidc-service-account-email="${SERVICE_ACCOUNT}"

echo "Done. Function URI: ${FUNCTION_URI}"
