#!/usr/bin/env bash
# Deploys the pipeline orchestration Workflow + syncs its SQL to GCS +
# consolidates the two independent ingestion schedules into one that
# triggers the whole pipeline in dependency order.
#
# NOT run automatically by anything in this repo — review, then run
# yourself: `bash scripts/deploy_workflow.sh`. Requires `gcloud`
# authenticated against PROJECT_ID below, and both ingestion functions
# already deployed (scripts/deploy_weather.sh, scripts/deploy_sftp.sh).
set -euo pipefail

PROJECT_ID="case-study-act"
REGION="europe-west1"            # same geography as the raw_data dataset (EU)
BUCKET="case-study-act-pipeline-sql"
WORKFLOW_NAME="pipeline"
SERVICE_ACCOUNT="workflow-runner-sa@${PROJECT_ID}.iam.gserviceaccount.com"
SCHEDULE="0 * * * *"             # every hour, on the hour — same cadence as before

echo "== Service account =="
gcloud iam service-accounts create workflow-runner-sa \
  --project="${PROJECT_ID}" \
  --display-name="Pipeline orchestration Workflow" \
  || echo "(already exists, continuing)"

echo "== GCS bucket for SQL (created once, synced every deploy) =="
gsutil mb -p "${PROJECT_ID}" -l EU "gs://${BUCKET}" 2>/dev/null || echo "(bucket already exists, continuing)"
gsutil -m rsync -r sql "gs://${BUCKET}"

echo "== Grant read access to the SQL bucket =="
gsutil iam ch "serviceAccount:${SERVICE_ACCOUNT}:roles/storage.objectViewer" "gs://${BUCKET}"

echo "== Read access to raw_data (bronze queries FROM it - found live: bronze failed with Access Denied without this) =="
python scripts/grant_dataset_access.py "${PROJECT_ID}" raw_data "${SERVICE_ACCOUNT}" roles/bigquery.dataViewer

echo "== Dataset-scoped BigQuery access on bronze/silver/analytics (not project-wide) =="
python scripts/grant_dataset_access.py "${PROJECT_ID}" bronze "${SERVICE_ACCOUNT}"
python scripts/grant_dataset_access.py "${PROJECT_ID}" silver "${SERVICE_ACCOUNT}"
python scripts/grant_dataset_access.py "${PROJECT_ID}" analytics "${SERVICE_ACCOUNT}"

echo "== Project-level bigquery.jobUser (required for LOAD/QUERY jobs - see docs/architecture.md) =="
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/bigquery.jobUser" \
  --condition=None \
  > /dev/null

echo "== logWriter for sys.log calls (found live, not anticipated - two identities need it) =="
# workflow-runner-sa itself...
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/logging.logWriter" \
  --condition=None \
  > /dev/null
# ...and the Google-managed Workflows service agent, which is what actually
# performs the log write for sys.log on the control plane's behalf - the
# grant above alone was NOT enough, confirmed by the identical 403
# persisting until this second grant was added too.
PROJECT_NUMBER=$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-workflows.iam.gserviceaccount.com" \
  --role="roles/logging.logWriter" \
  --condition=None \
  > /dev/null

echo "== Invoker rights on both ingestion functions =="
gcloud functions add-invoker-policy-binding weather-ingest \
  --project="${PROJECT_ID}" --region="${REGION}" \
  --member="serviceAccount:${SERVICE_ACCOUNT}"
gcloud functions add-invoker-policy-binding sftp-ingest \
  --project="${PROJECT_ID}" --region="${REGION}" \
  --member="serviceAccount:${SERVICE_ACCOUNT}"

echo "== Deploy the workflow =="
gcloud workflows deploy "${WORKFLOW_NAME}" \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --source=workflows/pipeline.yaml \
  --service-account="${SERVICE_ACCOUNT}"

echo "== Create/update the gold views (run once here, not part of the recurring workflow - see workflows/pipeline.yaml) =="
for f in sql/gold/*.sql; do
  echo "  -- ${f}"
  bq query --project_id="${PROJECT_ID}" --use_legacy_sql=false < "${f}"
done

echo "== Let a scheduler service account invoke workflow executions =="
gcloud iam service-accounts create scheduler-workflow-sa \
  --project="${PROJECT_ID}" \
  --display-name="Cloud Scheduler -> pipeline Workflow trigger" \
  || echo "(already exists, continuing)"
# gcloud has no per-workflow IAM verb (confirmed live: no add-iam-policy-binding
# or set-iam-policy under `gcloud workflows`, in GA or beta) - granting at the
# project level instead. With only one workflow in this project the practical
# scope difference is negligible; a resource-scoped binding would need a raw
# REST call to workflows.googleapis.com's setIamPolicy, not worth the added
# complexity here.
gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
  --member="serviceAccount:scheduler-workflow-sa@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/workflows.invoker" \
  --condition=None \
  > /dev/null

echo "== Pause the old per-function schedules (not deleted - safe rollback) =="
gcloud scheduler jobs pause weather-ingest-schedule --project="${PROJECT_ID}" --location="${REGION}" 2>&1 || true
gcloud scheduler jobs pause sftp-ingest-schedule --project="${PROJECT_ID}" --location="${REGION}" 2>&1 || true

echo "== Schedule the consolidated pipeline run (${SCHEDULE}) =="
WORKFLOW_EXEC_URI="https://workflowexecutions.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/workflows/${WORKFLOW_NAME}/executions"
SCHEDULER_ACTION="create"
gcloud scheduler jobs describe pipeline-schedule --project="${PROJECT_ID}" --location="${REGION}" &>/dev/null \
  && SCHEDULER_ACTION="update"
gcloud scheduler jobs "${SCHEDULER_ACTION}" http pipeline-schedule \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --schedule="${SCHEDULE}" \
  --uri="${WORKFLOW_EXEC_URI}" \
  --http-method=POST \
  --oauth-service-account-email="scheduler-workflow-sa@${PROJECT_ID}.iam.gserviceaccount.com"

echo "Done. Trigger a run manually with:"
echo "  gcloud workflows run ${WORKFLOW_NAME} --project=${PROJECT_ID} --location=${REGION}"
