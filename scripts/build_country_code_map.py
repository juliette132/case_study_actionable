"""Build bronze.country_code_map: every distinct country name that
actually appears in raw_data.import_csv_data, mapped to its ISO 3166-1
alpha-2 code (the same format weather_ingest stores in `country`).

Uses pycountry (official ISO 3166 data) rather than a hand-typed mapping -
built from the real data's distinct values, not guessed or hard-coded to
a curated city list, so adding a new city later doesn't require manually
re-verifying it (the original problem this whole design step solves).

A handful of country names in the source data don't match pycountry's
default lookup (either because pycountry's primary name changed - e.g.
Turkey's ISO record was updated to "Türkiye" in 2022 - or because of
punctuation differences in long-form names like "Bolivia (Plurinational
State of)"). MANUAL_OVERRIDES covers exactly the ones found; if new
countries are added to the source data later and this script's assertion
fails, add the new override here and rerun - the failure is loud, not
silent.

Usage: python scripts/build_country_code_map.py
Requires: pip install pycountry google-cloud-bigquery
"""

import io
import json

import pycountry
from google.cloud import bigquery

PROJECT_ID = "case-study-act"
TABLE_ID = f"{PROJECT_ID}.bronze.country_code_map"

# Every entry here failed pycountry's automatic lookup/fuzzy-search against
# the real distinct country names in raw_data.import_csv_data - confirmed
# by running this script without them and inspecting what came back
# unmatched, not guessed upfront.
MANUAL_OVERRIDES = {
    "Bolivia (Plurinational State of)": "BO",
    "Democratic Republic of the Congo": "CD",
    "Iran (Islamic Republic of)": "IR",
    "Turkey": "TR",  # pycountry's current primary name is "Türkiye" (2022 rename)
    "Venezuela (Bolivarian Republic of)": "VE",
}

SCHEMA = [
    bigquery.SchemaField(
        "country_name", "STRING",
        description="Exact country string as it appears in raw_data.import_csv_data.Country.",
    ),
    bigquery.SchemaField(
        "iso2", "STRING",
        description="ISO 3166-1 alpha-2 code, matching the format weather_ingest stores in `country`.",
    ),
]


def build_mapping(client: bigquery.Client) -> dict[str, str]:
    rows = client.query(
        "SELECT DISTINCT Country FROM `raw_data.import_csv_data` WHERE Country IS NOT NULL ORDER BY Country"
    ).result()
    names = [r["Country"] for r in rows]

    mapping: dict[str, str | None] = {}
    for name in names:
        if name in MANUAL_OVERRIDES:
            mapping[name] = MANUAL_OVERRIDES[name]
            continue
        try:
            mapping[name] = pycountry.countries.lookup(name).alpha_2
        except LookupError:
            try:
                results = pycountry.countries.search_fuzzy(name)
                mapping[name] = results[0].alpha_2 if results else None
            except LookupError:
                mapping[name] = None

    unmatched = [name for name, iso in mapping.items() if iso is None]
    if unmatched:
        raise RuntimeError(
            f"{len(unmatched)} country name(s) didn't resolve, add to MANUAL_OVERRIDES: {unmatched}"
        )
    return mapping  # type: ignore[return-value]


def main() -> None:
    client = bigquery.Client(project=PROJECT_ID)
    mapping = build_mapping(client)
    print(f"{len(mapping)} country names resolved.")

    client.create_table(bigquery.Table(TABLE_ID, schema=SCHEMA), exists_ok=True)

    rows = [{"country_name": name, "iso2": iso} for name, iso in mapping.items()]
    # NDJSON via an in-memory buffer, not the bash/CSV round trip - keeps
    # non-ASCII country names (e.g. "Côte d'Ivoire") intact.
    buf = io.BytesIO("\n".join(json.dumps(r, ensure_ascii=False) for r in rows).encode("utf-8"))
    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.NEWLINE_DELIMITED_JSON,
        write_disposition=bigquery.WriteDisposition.WRITE_TRUNCATE,
        schema=SCHEMA,
    )
    job = client.load_table_from_file(buf, TABLE_ID, job_config=job_config)
    job.result()
    print(f"Loaded {job.output_rows} rows into {TABLE_ID}")


if __name__ == "__main__":
    main()
