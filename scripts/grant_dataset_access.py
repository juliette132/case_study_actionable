"""Grant a principal a BigQuery role scoped to one dataset, via the
dataset's access-control list.

Exists because `bq add-iam-policy-binding <project>:<dataset>` — the
documented, simpler way to do this — returned "This feature requires
allowlisting" on this project. The ACL mechanism used here is the older,
universally-available equivalent: same effective permission, still scoped
to the dataset rather than the whole project.

Usage: python grant_dataset_access.py PROJECT_ID DATASET_ID SERVICE_ACCOUNT_EMAIL [ROLE]
(ROLE defaults to roles/bigquery.dataEditor)
"""

import sys

from google.cloud import bigquery


def main() -> None:
    if len(sys.argv) not in (4, 5):
        print(__doc__)
        sys.exit(1)

    project_id, dataset_id, service_account_email = sys.argv[1:4]
    role = sys.argv[4] if len(sys.argv) == 5 else "roles/bigquery.dataEditor"

    client = bigquery.Client(project=project_id)
    dataset = client.get_dataset(f"{project_id}.{dataset_id}")

    entry = bigquery.AccessEntry(
        role=role,
        entity_type="iamMember",
        entity_id=f"serviceAccount:{service_account_email}",
    )

    if entry in dataset.access_entries:
        print(f"{service_account_email} already has {role} on {dataset_id} — nothing to do.")
        return

    dataset.access_entries = list(dataset.access_entries) + [entry]
    client.update_dataset(dataset, ["access_entries"])
    print(f"Granted {role} on {dataset_id} to {service_account_email}.")


if __name__ == "__main__":
    main()
