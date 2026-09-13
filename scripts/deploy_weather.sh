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
# bq add-iam-policy-binding on a dataset requires allowlisting Google hasn't
# granted this project ("This feature requires allowlisting") - using the
# older ACL-based equivalent instead. Needs google-cloud-bigquery installed
# (e.g. run from inside .venv).
python scripts/grant_dataset_access.py "${PROJECT_ID}" raw_data "${SERVICE_ACCOUNT}"

echo "== Secret-scoped Secret Manager access (not project-wide) =="
gcloud secrets add-iam-policy-binding openweather-api-key \
  --project="${PROJECT_ID}" \
  --member="serviceAccount:${SERVICE_ACCOUNT}" \
  --role="roles/secretmanager.secretAccessor"

echo "== Deploy the function =="
# WEATHER_LOCATIONS contains commas (City,CC pairs), which would corrupt
# --set-env-vars's own comma-delimited syntax - using --env-vars-file (a
# YAML file) instead avoids delimiter-escaping entirely. Falls back to
# .env.example's default list if WEATHER_LOCATIONS isn't set in the
# environment running this script.
ENV_VARS_FILE="$(mktemp)"
trap 'rm -f "${ENV_VARS_FILE}"' EXIT
cat > "${ENV_VARS_FILE}" <<EOF
GCP_PROJECT_ID: "${PROJECT_ID}"
WEATHER_LOCATIONS: "${WEATHER_LOCATIONS:-Paris,FR;London,GB;New York,US;Berlin,DE;Amsterdam,NL;Bangkok,TH;Brussels,BE;Budapest,HU;Cairo,EG;Dubai,AE;Helsinki,FI;Istanbul,TR;Jakarta,ID;Lisbon,PT;Nairobi,KE;Oslo,NO;Prague,CZ;Seoul,KR;Singapore,SG;Sydney,AU;Tokyo,JP;Toronto,CA;Warsaw,PL;Accra,GH;Auckland,NZ;Bogota,CO;Cape Town,ZA;Casablanca,MA;Chicago,US;Doha,QA;Geneva,CH;Hanoi,VN;Johannesburg,ZA;Kuala Lumpur,MY;Lima,PE;Los Angeles,US;Manila,PH;Reykjavik,IS;Riyadh,SA;Sao Paulo,BR;Shanghai,CN;Wellington,NZ;Zurich,CH}"
EOF

gcloud functions deploy "${FUNCTION_NAME}" \
  --project="${PROJECT_ID}" \
  --gen2 \
  --runtime=python312 \
  --region="${REGION}" \
  --source=functions/weather_ingest \
  --entry-point=weather_ingest \
  --trigger-http \
  --no-allow-unauthenticated \
  --service-account="${SERVICE_ACCOUNT}" \
  --env-vars-file="${ENV_VARS_FILE}"

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
gcloud scheduler jobs describe weather-ingest-schedule --project="${PROJECT_ID}" --location="${REGION}" &>/dev/null \
  && SCHEDULER_ACTION="update"
gcloud scheduler jobs "${SCHEDULER_ACTION}" http weather-ingest-schedule \
  --project="${PROJECT_ID}" \
  --location="${REGION}" \
  --schedule="${SCHEDULE}" \
  --uri="${FUNCTION_URI}" \
  --http-method=POST \
  --oidc-service-account-email="${SERVICE_ACCOUNT}"

echo "Done. Function URI: ${FUNCTION_URI}"
