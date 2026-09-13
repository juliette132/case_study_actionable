"""Ingest CSV files from an SFTP server into BigQuery.

Landing table: `{BQ_DATASET}.{BQ_CSV_TABLE}` (default: raw_data.import_csv_data),
schema auto-detected from the CSV header by BigQuery's own load job — this
script doesn't know or care what dataset you point it at.

Idempotence: every file's SHA-256 content hash is checked against
`{BQ_DATASET}.{BQ_CONTROL_TABLE}` (default: raw_data._ingested_files) before
loading, and recorded after a successful load. Re-running against the same
files is a no-op — the SFTP-side equivalent of the weather script's
insertId dedup, needed here because a CSV load job has no such built-in key.

Works two ways:
  - As an HTTP-triggered Cloud Function (2nd gen). Entry point: `sftp_ingest`.
  - As a local script: `python main.py`.

Configuration is entirely via environment variables; see .env.example at
the repo root. Exactly one of SFTP_PASSWORD_SECRET_NAME or
SFTP_PRIVATE_KEY_SECRET_NAME should be set, matching how the SFTP account
authenticates.
"""

from __future__ import annotations

import hashlib
import io
import json
import logging
import os
from datetime import datetime, timezone
from typing import Any

import paramiko
from google.api_core.exceptions import NotFound
from google.cloud import bigquery, secretmanager

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("sftp_ingest")

PROJECT_ID = os.environ.get("GCP_PROJECT_ID") or os.environ.get("GOOGLE_CLOUD_PROJECT")
BQ_DATASET = os.environ.get("BQ_DATASET", "raw_data")
BQ_CSV_TABLE = os.environ.get("BQ_CSV_TABLE", "import_csv_data")
BQ_CONTROL_TABLE = os.environ.get("BQ_CONTROL_TABLE", "_ingested_files")

SFTP_HOST = os.environ.get("SFTP_HOST")
SFTP_PORT = int(os.environ.get("SFTP_PORT", "22"))
SFTP_USERNAME = os.environ.get("SFTP_USERNAME")
SFTP_REMOTE_DIR = os.environ.get("SFTP_REMOTE_DIR", "/")
SFTP_PASSWORD_SECRET_NAME = os.environ.get("SFTP_PASSWORD_SECRET_NAME")
SFTP_PRIVATE_KEY_SECRET_NAME = os.environ.get("SFTP_PRIVATE_KEY_SECRET_NAME")

CONTROL_TABLE_SCHEMA = [
    bigquery.SchemaField("file_name", "STRING", description="Name of the file as seen on the SFTP server."),
    bigquery.SchemaField(
        "file_hash", "STRING",
        description="SHA-256 of the file's bytes — the actual dedup key, not the file name.",
    ),
    bigquery.SchemaField("row_count", "INTEGER", description="Rows loaded from this file, per the BigQuery load job."),
    bigquery.SchemaField("ingested_at", "TIMESTAMP"),
]


def get_secret(project_id: str, secret_name: str, version: str = "latest") -> str:
    client = secretmanager.SecretManagerServiceClient()
    name = f"projects/{project_id}/secrets/{secret_name}/versions/{version}"
    response = client.access_secret_version(name=name)
    return response.payload.data.decode("UTF-8")


def _load_private_key(key_data: str) -> paramiko.PKey:
    """Try each common key type since we don't know upfront what the SFTP
    provider issued (RSA vs Ed25519 vs ECDSA)."""
    for key_cls in (paramiko.Ed25519Key, paramiko.RSAKey, paramiko.ECDSAKey):
        try:
            return key_cls.from_private_key(io.StringIO(key_data))
        except paramiko.SSHException:
            continue
    raise ValueError("Private key in SFTP_PRIVATE_KEY_SECRET_NAME is not a recognized RSA/Ed25519/ECDSA key.")


def connect_sftp(project_id: str) -> paramiko.SFTPClient:
    if not SFTP_HOST or not SFTP_USERNAME:
        raise RuntimeError("Set SFTP_HOST and SFTP_USERNAME in the environment.")

    transport = paramiko.Transport((SFTP_HOST, SFTP_PORT))
    if SFTP_PRIVATE_KEY_SECRET_NAME:
        pkey = _load_private_key(get_secret(project_id, SFTP_PRIVATE_KEY_SECRET_NAME))
        transport.connect(username=SFTP_USERNAME, pkey=pkey)
    elif SFTP_PASSWORD_SECRET_NAME:
        password = get_secret(project_id, SFTP_PASSWORD_SECRET_NAME)
        transport.connect(username=SFTP_USERNAME, password=password)
    else:
        raise RuntimeError("Set SFTP_PASSWORD_SECRET_NAME or SFTP_PRIVATE_KEY_SECRET_NAME.")

    return paramiko.SFTPClient.from_transport(transport)


def ensure_control_table(client: bigquery.Client, project_id: str) -> bigquery.TableReference:
    dataset_ref = bigquery.DatasetReference(project_id, BQ_DATASET)
    table_ref = dataset_ref.table(BQ_CONTROL_TABLE)
    try:
        client.get_table(table_ref)
    except NotFound:
        client.create_table(bigquery.Table(table_ref, schema=CONTROL_TABLE_SCHEMA))
        logger.info("Created control table %s.", table_ref)
    return table_ref


def already_ingested(client: bigquery.Client, control_table: bigquery.TableReference, file_hash: str) -> bool:
    query = f"""
        SELECT 1
        FROM `{control_table.project}.{control_table.dataset_id}.{control_table.table_id}`
        WHERE file_hash = @file_hash
        LIMIT 1
    """
    job_config = bigquery.QueryJobConfig(
        query_parameters=[bigquery.ScalarQueryParameter("file_hash", "STRING", file_hash)]
    )
    return client.query(query, job_config=job_config).result().total_rows > 0


def load_csv(client: bigquery.Client, project_id: str, file_bytes: bytes) -> int:
    """Load one CSV's bytes into BigQuery, letting BigQuery's own CSV
    parser detect the schema rather than reimplementing that in Python."""
    dataset_ref = bigquery.DatasetReference(project_id, BQ_DATASET)
    table_ref = dataset_ref.table(BQ_CSV_TABLE)
    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.CSV,
        skip_leading_rows=1,
        autodetect=True,
        write_disposition=bigquery.WriteDisposition.WRITE_APPEND,
        # BigQuery's default (STRICT/V1) column-name rules reject headers
        # with spaces, periods, etc. (e.g. "PM2.5 AQI Value") — real-world
        # CSV headers routinely have these. V2 normalizes them instead of
        # rejecting the load outright.
        column_name_character_map="V2",
    )
    job = client.load_table_from_file(io.BytesIO(file_bytes), table_ref, job_config=job_config)
    job.result()  # blocks until done; raises google.api_core.exceptions.GoogleAPIError on failure
    return job.output_rows


def record_ingestion(
    client: bigquery.Client,
    control_table: bigquery.TableReference,
    file_name: str,
    file_hash: str,
    row_count: int,
    ingested_at: datetime,
) -> None:
    row = {
        "file_name": file_name,
        "file_hash": file_hash,
        "row_count": row_count,
        "ingested_at": ingested_at.timestamp(),
    }
    errors = client.insert_rows_json(control_table, [row], row_ids=[file_hash])
    if errors:
        logger.error("Failed to record ingestion of %s: %s", file_name, errors)


def run() -> dict[str, Any]:
    if not PROJECT_ID:
        raise RuntimeError("Set GCP_PROJECT_ID (or GOOGLE_CLOUD_PROJECT) in the environment.")

    bq_client = bigquery.Client(project=PROJECT_ID)
    control_table = ensure_control_table(bq_client, PROJECT_ID)

    sftp = connect_sftp(PROJECT_ID)
    loaded: list[dict[str, Any]] = []
    skipped: list[str] = []
    errors: list[dict[str, str]] = []
    file_names: list[str] = []
    try:
        file_names = [f for f in sftp.listdir(SFTP_REMOTE_DIR) if f.lower().endswith(".csv")]
        for file_name in file_names:
            remote_path = f"{SFTP_REMOTE_DIR.rstrip('/')}/{file_name}"
            try:
                with sftp.open(remote_path, "rb") as f:
                    file_bytes = f.read()
                file_hash = hashlib.sha256(file_bytes).hexdigest()

                if already_ingested(bq_client, control_table, file_hash):
                    skipped.append(file_name)
                    continue

                row_count = load_csv(bq_client, PROJECT_ID, file_bytes)
                record_ingestion(bq_client, control_table, file_name, file_hash, row_count, datetime.now(timezone.utc))
                loaded.append({"file": file_name, "rows": row_count})
            except Exception as exc:  # noqa: BLE001 - isolate per-file failures
                logger.exception("Failed to ingest %s", file_name)
                errors.append({"file": file_name, "error": str(exc)})
    finally:
        sftp.close()

    result = {
        "files_seen": len(file_names),
        "loaded": loaded,
        "skipped_already_ingested": skipped,
        "errors": errors,
    }
    logger.info("SFTP ingestion result: %s", result)
    return result


def sftp_ingest(request=None):
    """HTTP Cloud Function entry point (functions-framework signature)."""
    try:
        result = run()
        return json.dumps(result), 200 if not result["errors"] else 207, {"Content-Type": "application/json"}
    except Exception as exc:  # noqa: BLE001 - surface as a 500 with detail in the body
        logger.exception("sftp_ingest failed")
        return json.dumps({"error": str(exc)}), 500, {"Content-Type": "application/json"}


if __name__ == "__main__":
    print(json.dumps(run(), indent=2, default=str))
