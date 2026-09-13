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

## 2026-09-13 (continued) — GitHub workflow, SFTP ingestion script

**Prompts, close to verbatim:**
1. *"no, i want you to follow a teamwork style; keep separate branches,
   expect PRs for merges; set u^a github ruleset for the repo that
   disallows merging into main without a pr"*
2. *"whats next? help me plan out the next steps of the assignement"*, then,
   answering follow-up questions: SFTP account not started yet; hold off on
   actually running deploy commands, prepare them for review instead.

**What the AI produced or did:**
- Installed the GitHub CLI (`gh`), authenticated it, pushed
  `weather-ingestion`, and opened PR #1 into `main`.
- Attempted a GitHub repository ruleset requiring PRs into `main` — blocked
  by GitHub: rulesets (and, tried as a fallback, classic branch protection)
  are Pro-only for private repos on a free personal account. Surfaced this
  as an explicit choice rather than silently picking one; the user chose to
  make the repo **public** to unlock it. Ruleset created and confirmed
  active via the API response.
- Attempted to verify the ruleset with a live direct push to `main` — this
  specific action was blocked by Claude Code's own safety layer (flagged as
  a "CI bypass" pattern) before it reached GitHub. Not worked around;
  reported to the user as-is. The ruleset's active state was still
  confirmed from the creation API response.
- `functions/sftp_ingest/main.py`: lists CSVs on an SFTP server, dedups by
  SHA-256 content hash against a `_ingested_files` control table, and loads
  new files into BigQuery via a `LOAD` job with `autodetect=True` (BigQuery's
  own CSV parser, not a hand-rolled one).
- `scripts/deploy_weather.sh` / `scripts/deploy_sftp.sh`: turned the
  previously-inline `docs/architecture.md` deploy commands into actual
  scripts, per the user's choice to review before any deploy runs.

**Trusted as-is:**
- The `paramiko` connection/key-loading pattern and the BigQuery `LOAD` job
  API usage — standard, well-documented library usage, not exercised against
  a real SFTP server in this session (none exists yet).

**Corrected / questioned:**
- Nothing was silently worked around when blocked (the ruleset's plan
  restriction, the direct-push test) — both were surfaced to the user with
  the actual tradeoff/reason rather than the AI picking a path unasked.

**Not yet independently verified:**
- `functions/sftp_ingest/main.py` compiles and imports cleanly and its
  hashing/control-table logic was reasoned through, but the actual SFTP
  connection and CSV load path have not been exercised against a real
  server — there's no SFTP account yet to test against.

## 2026-09-13 (continued) — First live SFTP connection test

**Context:** the user created an SFTPCloud instance (`cozy-penguin`,
`eu-west-1.sftpcloud.io`) and pasted its host/username/password directly
into chat.

**What the AI did:**
- Created the `sftp-password` secret in Secret Manager by piping the value
  straight into `gcloud secrets create ... --data-file=-`, so the plaintext
  never touched a file on disk.
- Ran `functions/sftp_ingest/main.py` against the real instance.

**Corrected — caught by running it, not by inspection:**
- First attempt failed authentication entirely. Root cause: piping a string
  to a native command's stdin in PowerShell (`"x" | gcloud ... --data-file=-`)
  appends a trailing newline, so the stored secret was the password plus
  `\n`, not the exact password the user provided. Fixed by writing the
  value to a temp file with `[System.IO.File]::WriteAllText` (which adds no
  trailing newline), adding it as a new secret version via
  `--data-file=<path>`, then deleting the temp file. Re-running confirmed
  authentication, SFTP listing, and the BigQuery control-table setup all
  work end-to-end — only 0 files were found, expected since no CSV has
  been uploaded to the instance yet.

**Note on handling the credential itself:** the raw password appeared in
the user's chat message (unavoidable — that's how it was shared) but was
never written into any file in this repo or the scratchpad; it went
directly from the conversation into Secret Manager and is referenced
everywhere else in code/docs only by the secret's *name*, not its value.

## 2026-09-13 (continued) — Real CSV loaded, second bug caught live

**Context:** the user picked a Kaggle dataset
([Global Air Pollution](https://www.kaggle.com/datasets/hasibalmuzdadid/global-air-pollution-dataset)),
downloaded it, and gave the AI a local file path.

**What the AI did:**
- Wrote a one-off upload helper (not part of the repo/pipeline — the
  pipeline only pulls) using the same paramiko credentials already verified,
  and uploaded the CSV to the SFTPCloud instance directly, rather than
  asking the user to do it manually through a GUI.
- Ran the ingestion script against the real file.

**Corrected — caught by running it, not by inspection:**
- The load failed: `Field name 'PM2.5 AQI Value' is not supported by the
  current character map`. BigQuery's default (STRICT/V1) column-naming
  rules reject periods/spaces in autodetected CSV headers — a real dataset
  with a real header like `PM2.5 AQI Value` hits this immediately, while
  the earlier offline sanity-check payload never exercised a header with
  unusual characters. Fixed by setting
  `LoadJobConfig.column_name_character_map="V2"`, which normalizes invalid
  characters (`PM2.5 AQI Value` → `PM2_5 AQI Value`) instead of rejecting
  the load. Confirmed via a targeted web search of Google's own client
  library docs before using the exact field name, not from memory.
- Re-ran and confirmed: 23,463 rows loaded on the first pass, and a second
  run correctly reported the file as `skipped_already_ingested` with zero
  new rows — the content-hash dedup claim in `docs/architecture.md` is now
  verified live, not just reasoned about.

**Note on the credential handling pattern established earlier:** the SFTP
password was reused here (read back from Secret Manager by the one-off
upload script, not retyped or re-pasted), consistent with never having it
live in a file.

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
