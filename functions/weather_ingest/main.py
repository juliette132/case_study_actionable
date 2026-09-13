"""Ingest current weather observations from OpenWeatherMap into BigQuery.

Landing table: `{BQ_DATASET}.{BQ_WEATHER_TABLE}` (default: raw_data.import_weather).

This module works two ways:
  - As an HTTP-triggered Cloud Function (2nd gen). Entry point: `weather_ingest`.
  - As a local script: `python main.py` (reads config from the environment;
    see .env.example at the repo root).

Configuration is entirely via environment variables so the same code runs
locally and deployed without edits. See .env.example for the full list.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
from datetime import datetime, timezone
from typing import Any

import requests
from google.api_core.exceptions import NotFound
from google.cloud import bigquery, secretmanager

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("weather_ingest")

# NOTE: despite older Cloud Functions docs/folklore, GOOGLE_CLOUD_PROJECT is
# NOT reliably auto-populated on gen2 (confirmed by a live deploy failing
# with "Set GCP_PROJECT_ID..." until it was passed explicitly) — the deploy
# scripts always pass GCP_PROJECT_ID via --set-env-vars. Both env var names
# are still checked here so a manually-set GOOGLE_CLOUD_PROJECT works too.
PROJECT_ID = os.environ.get("GCP_PROJECT_ID") or os.environ.get("GOOGLE_CLOUD_PROJECT")
SECRET_NAME = os.environ.get("OPENWEATHER_SECRET_NAME", "openweather-api-key")
SECRET_VERSION = os.environ.get("OPENWEATHER_SECRET_VERSION", "latest")
BQ_DATASET = os.environ.get("BQ_DATASET", "raw_data")
BQ_TABLE = os.environ.get("BQ_WEATHER_TABLE", "import_weather")
DEFAULT_LOCATIONS = "Paris,FR;London,GB;New York,US;Berlin,DE"
WEATHER_LOCATIONS = os.environ.get("WEATHER_LOCATIONS", DEFAULT_LOCATIONS)

OPENWEATHER_URL = "https://api.openweathermap.org/data/2.5/weather"

# This script owns and enforces this schema (see ensure_table below). Every
# field is NULLABLE, deliberately: (1) BigQuery only allows *adding* NULLABLE
# columns to an existing table via a schema update — a REQUIRED column can
# only be set at creation time — and (2) a raw landing table shouldn't reject
# a whole row just because the source API omitted one field.
TABLE_SCHEMA = [
    bigquery.SchemaField(
        "location_query", "STRING",
        description="Query string sent to OpenWeatherMap, e.g. 'Paris,FR'.",
    ),
    bigquery.SchemaField("city_name", "STRING", description="City name as returned by the API."),
    bigquery.SchemaField("country", "STRING", description="ISO country code returned by the API."),
    bigquery.SchemaField("latitude", "FLOAT"),
    bigquery.SchemaField("longitude", "FLOAT"),
    bigquery.SchemaField(
        "observed_at", "TIMESTAMP",
        description="Observation time reported by OpenWeatherMap (field `dt`).",
    ),
    bigquery.SchemaField("temperature_c", "FLOAT"),
    bigquery.SchemaField("feels_like_c", "FLOAT"),
    bigquery.SchemaField("humidity_pct", "INTEGER"),
    bigquery.SchemaField("pressure_hpa", "INTEGER"),
    bigquery.SchemaField("wind_speed_ms", "FLOAT"),
    bigquery.SchemaField("weather_main", "STRING"),
    bigquery.SchemaField("weather_description", "STRING"),
    bigquery.SchemaField(
        "ingested_at", "TIMESTAMP",
        description="When this pipeline run fetched the record (not the observation time).",
    ),
    bigquery.SchemaField(
        "raw_response", "STRING",
        description="Full raw JSON payload from the API, kept for audit/reprocessing (bronze-style).",
    ),
]


def get_api_key(project_id: str) -> str:
    """Fetch the OpenWeatherMap API key from Secret Manager."""
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{project_id}/secrets/{SECRET_NAME}/versions/{SECRET_VERSION}"
    response = client.access_secret_version(name=name)
    return response.payload.data.decode("UTF-8")


def fetch_weather(location_query: str, api_key: str) -> dict[str, Any]:
    """Call the OpenWeatherMap current-weather endpoint for one location."""
    params = {"q": location_query, "appid": api_key, "units": "metric"}
    resp = requests.get(OPENWEATHER_URL, params=params, timeout=10)
    resp.raise_for_status()
    return resp.json()


def to_row(location_query: str, payload: dict[str, Any], ingested_at: datetime) -> dict[str, Any]:
    """Flatten one OpenWeatherMap response into a BigQuery row.

    Keeps both the flattened fields (for direct querying/BI) and the raw
    payload (so a future silver/gold layer can be reprocessed without
    re-calling the API) — a lightweight bronze/silver hybrid.
    """
    main_block = payload.get("main", {})
    wind = payload.get("wind", {})
    weather0 = (payload.get("weather") or [{}])[0]
    coord = payload.get("coord", {})

    return {
        "location_query": location_query,
        "city_name": payload.get("name"),
        "country": payload.get("sys", {}).get("country"),
        "latitude": coord.get("lat"),
        "longitude": coord.get("lon"),
        # Unix epoch seconds — BigQuery's JSON insert API accepts TIMESTAMP
        # as epoch seconds directly, no string formatting/timezone parsing needed.
        "observed_at": payload.get("dt"),
        "temperature_c": main_block.get("temp"),
        "feels_like_c": main_block.get("feels_like"),
        "humidity_pct": main_block.get("humidity"),
        "pressure_hpa": main_block.get("pressure"),
        "wind_speed_ms": wind.get("speed"),
        "weather_main": weather0.get("main"),
        "weather_description": weather0.get("description"),
        "ingested_at": ingested_at.timestamp(),
        "raw_response": json.dumps(payload),
    }


def row_id(row: dict[str, Any]) -> str:
    """Deterministic id so re-running for the same location/observation is a
    no-op: BigQuery streaming inserts de-duplicate best-effort on insertId
    within a short window. This is "best effort", not a hard guarantee —
    see README for the tradeoff."""
    basis = f"{row['location_query']}|{row['observed_at'] or row['ingested_at']}"
    return hashlib.sha256(basis.encode()).hexdigest()


def ensure_table(client: bigquery.Client, project_id: str) -> bigquery.TableReference:
    """Make sure the landing table exists with this script's schema.

    Three cases:
      - Table doesn't exist yet: create it fresh.
      - Table exists but has no columns (e.g. a placeholder created via the
        Console): patch in our schema. Safe because there's nothing to lose
        and every field is NULLABLE (see TABLE_SCHEMA).
      - Table exists with some other, different schema: refuse to guess —
        raise so a human reconciles it, instead of silently corrupting or
        failing to insert into someone else's table.
    """
    dataset_ref = bigquery.DatasetReference(project_id, BQ_DATASET)
    table_ref = dataset_ref.table(BQ_TABLE)

    try:
        existing = client.get_table(table_ref)
    except NotFound:
        client.create_table(bigquery.Table(table_ref, schema=TABLE_SCHEMA))
        logger.info("Created %s with the ingestion schema.", table_ref)
        return table_ref

    if not existing.schema:
        existing.schema = TABLE_SCHEMA
        client.update_table(existing, ["schema"])
        logger.info("Applied ingestion schema to previously-empty table %s.", table_ref)
    elif {f.name for f in existing.schema} != {f.name for f in TABLE_SCHEMA}:
        raise RuntimeError(
            f"{table_ref} already has a schema that doesn't match this script's "
            f"expected columns ({sorted(f.name for f in TABLE_SCHEMA)}). "
            "Reconcile manually before running (see README)."
        )
    return table_ref


def run(locations: str | None = None) -> dict[str, Any]:
    """Core pipeline: fetch weather for each configured location, load to BigQuery.

    Errors for individual locations are caught so one bad city doesn't fail
    the whole run; they're reported back in the result instead.
    """
    if not PROJECT_ID:
        raise RuntimeError("Set GCP_PROJECT_ID (or GOOGLE_CLOUD_PROJECT) in the environment.")

    locations = locations or WEATHER_LOCATIONS
    location_list = [loc.strip() for loc in locations.split(";") if loc.strip()]

    api_key = get_api_key(PROJECT_ID)
    ingested_at = datetime.now(timezone.utc)

    rows: list[dict[str, Any]] = []
    ids: list[str] = []
    fetch_errors: list[dict[str, str]] = []
    for loc in location_list:
        try:
            payload = fetch_weather(loc, api_key)
            row = to_row(loc, payload, ingested_at)
            rows.append(row)
            ids.append(row_id(row))
        except Exception as exc:  # noqa: BLE001 - isolate per-location failures
            logger.exception("Failed to fetch/parse weather for %s", loc)
            fetch_errors.append({"location": loc, "error": str(exc)})

    bq_client = bigquery.Client(project=PROJECT_ID)
    table_ref = ensure_table(bq_client, PROJECT_ID)

    bigquery_errors: list[dict[str, Any]] = []
    if rows:
        bigquery_errors = bq_client.insert_rows_json(table_ref, rows, row_ids=ids)
        if bigquery_errors:
            logger.error("BigQuery insert errors: %s", bigquery_errors)

    result = {
        "locations_requested": len(location_list),
        "rows_inserted": len(rows) - len(bigquery_errors) if rows else 0,
        "fetch_errors": fetch_errors,
        "bigquery_errors": bigquery_errors,
    }
    logger.info("Weather ingestion result: %s", result)
    return result


def weather_ingest(request=None):
    """HTTP Cloud Function entry point (functions-framework signature)."""
    try:
        result = run()
        ok = not result["fetch_errors"] and not result["bigquery_errors"]
        return json.dumps(result), 200 if ok else 207, {"Content-Type": "application/json"}
    except Exception as exc:  # noqa: BLE001 - surface as a 500 with detail in the body
        logger.exception("weather_ingest failed")
        return json.dumps({"error": str(exc)}), 500, {"Content-Type": "application/json"}


if __name__ == "__main__":
    print(json.dumps(run(), indent=2, default=str))
