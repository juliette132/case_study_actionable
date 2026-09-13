# AI usage log

The brief for this exercise requires documenting AI tool usage throughout:
which prompts, on which parts, and where the output was trusted as-is vs
corrected or questioned. This is that log. Add a new dated entry each time
you use AI tooling on this repo — don't rewrite history, append.

Tool used throughout: **Claude Code** (Anthropic), model Claude Sonnet 5.

---

## 2026-09-12/13 — GCP console setup (prior session — not captured here)

Project creation, enabling the BigQuery / Cloud Functions / Cloud Scheduler /
Secret Manager APIs, creating the `openweather-api-key` secret, and creating
the `raw_data` dataset with an empty `import_weather` table were done in an
earlier AI-assisted session. That session's prompt history wasn't carried
forward — only a summary handoff document was. **If a complete log matters
for the discussion, pull the actual prompts from that session and replace
this note before Monday.**

---

## 2026-09-13 — Weather ingestion script, tooling, first live run (this session)

**Starting context handed to the AI:** the handoff markdown above,
summarizing progress and naming the immediate next step (OpenWeatherMap →
Secret Manager → BigQuery script).

**Prompts, close to verbatim:**
1. *"i want to continue work started in a separate task. here is the md
   file."* (pasted the handoff doc)
2. *"install the latest python"*, then *"make it a machine wide
   installation, proceed with standard settings"*
3. *"proceed with the gcloud cli installation. how do i find the sharing
   options for the gcp project and the secret api key?"*
4. *"is the script finalised? if so proceed with a test run, let me inspect
   the imported data"*
5. *"proceed with the documentation"*

**What the AI produced or did:**
- `functions/weather_ingest/main.py` — fetches the OpenWeatherMap key from
  Secret Manager, calls the current-weather endpoint for a configurable list
  of locations, flattens the response, and streams rows into BigQuery.
  Written to run both as a local script and as an HTTP Cloud Function.
- Installed Python 3.14 and the Google Cloud SDK (`gcloud`/`bq`), both
  machine-wide via `winget`, since neither was present on this machine.
- Ran `gcloud auth login` and `gcloud auth application-default login`
  (interactive browser sign-in, done by the human) and set the active
  project to `case-study-act`.
- Ran the script against the real project and queried the resulting rows
  back out of BigQuery to confirm what actually landed.
- Wrote this log and `docs/architecture.md`.

**Trusted as-is, no independent check:**
- The overall pipeline shape (Secret Manager → API → flatten → BigQuery) and
  the functions-framework-compatible entry point signature.
- `winget` package IDs (`Python.Python.3.14`, `Google.CloudSDK`) — confirmed
  to exist via `winget search` before installing, but the install itself
  wasn't inspected beyond checking the resulting `--version` output.

**Corrected — caught by actually running it, not by reading the code:**
- First draft of `ensure_table()` used `create_table(table, exists_ok=True)`,
  which silently does nothing if the table already exists. The real
  `import_weather` table already existed (empty, no schema), so this would
  have quietly never applied the intended schema — only surfaced by running
  the script against the real table and getting an insert failure.
  Rewritten to detect an existing-but-empty table and patch its schema in.

**Corrected — caught by reasoning about a platform constraint, before running:**
- First draft of the schema marked `location_query` and `ingested_at` as
  `REQUIRED`. BigQuery does not allow adding `REQUIRED` columns to an
  existing table via a schema update (only `NULLABLE` columns can be added
  after creation), which would have made the fix above fail too. Every
  column was made `NULLABLE` instead — also arguably better practice for a
  raw landing table, since a field missing from the source API shouldn't
  cause the whole row to be rejected.

**Verified rather than assumed:**
- The `bq add-iam-policy-binding <project>:<dataset>` syntax used in
  `docs/architecture.md` was cross-checked with a web search rather than
  relied on from memory, since it's documentation someone will run as-is.
  Source: [datasunrise.com BigQuery security overview](https://www.datasunrise.com/knowledge-center/bigquery-security/)
  and related results, not Google's own reference page directly — worth a
  second check against the official IAM docs before relying on it in a
  presentation.
- Whether Python 3.14 (very recently released at time of writing) would have
  working prebuilt wheels for `grpcio` and the other GCP client library
  C-extensions was a real risk, not assumed — resolved by running
  `pip install` for real and confirming every package installed cleanly.

**Not yet independently verified — flagged, not claimed as tested:**
- The `gcloud functions deploy`, `gcloud functions add-invoker-policy-binding`
  and `gcloud scheduler jobs create` commands in `docs/architecture.md` are
  written from documented syntax but have not been executed. `gcloud`/`bq`
  were only used in this session to authenticate and to inspect/query
  existing resources, not to deploy anything.

## Template for the next entry

```
## YYYY-MM-DD — <what this session covered>

**Prompts:**
- ...

**What the AI produced or did:**
- ...

**Trusted as-is:**
- ...

**Corrected / questioned:**
- ...
```
