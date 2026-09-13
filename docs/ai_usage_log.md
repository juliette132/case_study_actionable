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

## 2026-09-13 (continued) — A judgment call the AI got wrong, caught by a guardrail

**What happened:** asked to fill in `scripts/deploy_sftp.sh`'s placeholders
with the real SFTP host/username (having already flagged, and gotten
agreement, that the password itself would stay in Secret Manager), the AI
did so and attempted to commit it. Claude Code's own safety layer blocked
the commit, flagging the username (an opaque hex token) as credential-shaped
content being committed to a now-**public** repository.

**This was the right call, not an obstacle to route around.** On
reflection, "the password isn't in it" was the wrong bar — an
account-identifying token shouldn't be committed to a public repo either,
independent of whether it's exploitable alone (minimizing exposed surface,
not aiding brute-force/credential-stuffing attempts, not revealing account
existence). The AI had already reasoned about this exact tradeoff two
messages earlier when deciding *not* to hardcode these values, then
proceeded to do it anyway once the user said "proceed" to a related but
narrower question (filling in placeholders) — a real lapse, not a
prompt-injection or adversarial scenario.

**Fix:** reverted to placeholders, changed to be overridable via
environment variables (`"${SFTP_HOST:-CHANGE_ME...}"`) at run time instead
of hardcoded in the committed file, so nothing real needs to be checked in
at all.

**Why this belongs in the log specifically:** it's a concrete example of
the AI's own output being *not just corrected on the code-review pass but
overridden by a guardrail after a user's go-ahead* — worth being upfront
about for Monday's discussion, rather than only showcasing the cases where
correction happened cleanly before anything ran.

## 2026-09-13 (continued) — First real deployment: 4 bugs no amount of review had caught

**Prompt:** *"proceed with deployment"*, following an earlier explicit
verification pass ("verify that all is ready for a live deployment") that
had checked runtimes, APIs, quota, existing resources, and cross-referenced
every gcloud/bq command against the installed CLI's own `--help` — and
still missed all four of the following, because none of them are
discoverable by reading the script; they only show up when the code
actually runs against real infrastructure.

**Housekeeping bug found first:** PR #2 had been stacked on PR #1's branch
(`weather-ingestion`) rather than targeting `main` directly. PR #1 merged
first, so the entire SFTP pipeline never reached `main`. Caught by
diffing `origin/main` against what was expected, not assumed from PR
state. Fixed with a follow-up PR (#3) from `weather-ingestion` straight
into `main`.

**Bug 1 — `bq add-iam-policy-binding` on a dataset:** returned "This
feature requires allowlisting" live, despite being the syntax verified via
web search earlier in the session (that search found *correct* syntax for
a feature that turned out to be gated for this project — verifying syntax
isn't the same as verifying availability). Fixed with
`scripts/grant_dataset_access.py`, using the dataset's own
access-control-list mechanism instead.

**Bug 2 — `GCP_PROJECT_ID` not set at runtime:** a code comment (written
earlier, never tested) claimed "Cloud Functions (2nd gen) sets
GOOGLE_CLOUD_PROJECT automatically" — asserted from general Cloud
Functions knowledge, not verified for this exact runtime, and wrong. The
function crashed with `RuntimeError: Set GCP_PROJECT_ID...` on its first
real invocation. Fixed by always passing it via `--set-env-vars`, and the
false comment was corrected in the code, not just patched around.

**Bug 3 — SFTP function missing project-level `bigquery.jobUser`:** the
documented IAM design (dataset-scoped access only, no project-level roles)
was reasoned through carefully for the weather function's streaming
inserts, then assumed to transfer to the SFTP function's LOAD/QUERY jobs
without checking that BigQuery jobs are a project-scoped resource with no
dataset-scoped equivalent. Live 403 caught it; fixed by granting
`roles/bigquery.jobUser` at the project level, and the architecture doc
was corrected to explain *why* this one is necessarily broader, not just
that it is.

**Bug 4 — Git Bash/MSYS path mangling:** running the SFTP deploy script
from Git Bash on Windows silently turned `SFTP_REMOTE_DIR=/` into
`SFTP_REMOTE_DIR=C:/Program Files/Git/` (MSYS auto-converts bare `/`
arguments before non-MSYS programs see them) — not something any code
review would surface, only a live `gcloud functions describe` showing the
deployed env var. First fix attempt (`MSYS_NO_PATHCONV=1`) made it worse —
it broke gcloud's own bash launcher script, which needed its own internal
path translation to keep working. Actually fixed by switching that one
command to PowerShell, where this MSYS-specific behavior doesn't exist,
and documented as a known gotcha in the script rather than "solved" with a
fragile bash-side workaround.

**A dead-end worth recording honestly:** attempting to manually test the
deployed function by curling it directly (impersonating the service
account to mint an identity token) failed twice, for two unrelated
reasons (missing `Content-Length` header → 411; then a permission the
AI's own account didn't have for service-account impersonation → empty
token → 401) — neither of which was the actual bug. The useful signal
came from a different approach entirely: reading Cloud Logging's request
log for the underlying Cloud Run service directly, which showed the real
crash. Abandoning the curl approach once it became a dead end, rather than
continuing to debug a test harness instead of the actual system, is the
part worth noting here.

**What this entry is really documenting:** every one of these four bugs
survived a real "verify before deploying" pass that included cross-checking
CLI syntax against installed tool help output — a level of diligence beyond
"just trust the docs." None of that substitutes for actually running the
thing. That gap — between "reviewed and looks right" and "confirmed by a
live run" — is the throughline of this whole session's log, not just this
entry.

## 2026-09-13 (continued) — Transform layer planning

**Prompt:** *"proceed with the planning phase of the extension; lay out
the necessary tools and expansions to achieve each tier"* — the optional
bronze/silver/gold stretch goal.

**What the AI did:** wrote `docs/transform_layer_plan.md` — planning only,
nothing built. Laid out silver/gold table designs and two tooling options
(BigQuery Scheduled Queries vs. Dataform, the latter already having its
API enabled on this project), with a recommendation driven by the Monday
deadline rather than by which is "better" in the abstract.

**Verified rather than assumed:** the plan's draft included a proposed
cross-source gold table joining weather and air-quality data by city name.
Before writing that up as a real recommendation, ran the actual join
against the real data instead of assuming it would work. Result: the CSV
contains multiple same-named cities worldwide (a "Paris" in the US, a
"Berlin" in El Salvador) — joining on city+country against the real
target locations returned exactly one match (London, GB), not enough to
be a meaningful demo table. The plan documents this finding and drops the
table rather than presenting an untested idea as a good one.

## 2026-09-13 (continued) — Expanding weather locations, found an accent bug live

**Prompts:**
1. *"verify if more datapoints could be obtained via the sql pipeline for
   the weather api so that more rows can be matched with the sftp
   files"*
2. *"prceed with the expansion"*
3. *"I want the noramlization fo the city names and ocuntry names (accents
   and lower) to occur int eh bronze layer, type changes, as well as any
   dedup policies. Silver layer do the join and get rid of the columns we
   don't need for the aggregation in the gold layer. I want the analysis
   to be using information from both tables, perhaps combining the avg
   temperature with the air quality as a metric. Give me a few options
   for this seciont"*

**What the AI did:**
- Checked ~57 major world cities against the real `raw_data.import_csv_data`
  for a correct city+country match (not just city name), then called the
  live OpenWeatherMap API for all 39 candidates that passed — all 39
  resolved to the expected city/country. Expanded `WEATHER_LOCATIONS`
  (`functions/weather_ingest/main.py`, `.env.example`) from 4 cities (1
  real cross-source match) to 43.
- Redeployed `weather-ingest` with the new list. Along the way, found that
  `--set-env-vars` can't hold `WEATHER_LOCATIONS` as-is (its value contains
  commas, which is `--set-env-vars`'s own delimiter) — verified
  `--env-vars-file` was the documented fix before using it, rather than
  guessing at escape syntax.
- Triggered the deployed function for real: all 43 cities landed.
- Ran the actual cross-source join against fresh live data. Caught its own
  mistake: the first join query matched on city name only (no country
  check) and silently paired Berlin (weather, Germany) with a false-positive
  Berlin row from the CSV (which is in El Salvador) — the exact bug class
  the whole exercise was supposed to avoid. Rewrote the join with explicit
  per-city country verification before presenting any result as correct.
- That corrected join was still missing one row (Sao Paulo) with no error —
  traced to OpenWeatherMap returning the accented `São Paulo` while the CSV
  stores unaccented `Sao Paulo`. Verified an accent-insensitive join
  expression (`NORMALIZE(..., NFD)` + `REGEXP_REPLACE(..., r'\pM', '')`)
  against the real rows before writing it into the plan as a fix, rather
  than asserting it would work.
- Rewrote `docs/transform_layer_plan.md` for the user's requested layering
  (normalization/typing/dedup in bronze, the join in silver, pure
  aggregation in gold — a deliberate departure from the more common
  "bronze = raw" convention, adopted because the user asked for it, not
  silently overridden). Flagged a real design gap while doing so: weather
  stores country as an ISO code, the CSV stores full English names, so a
  city-name-only join (which is all today's curated 40 cities needed) would
  quietly reintroduce the multi-city-same-name risk for any city added
  later — a small static ISO-to-name mapping is needed for a robust join,
  not built yet, called out rather than glossed over.
- Produced 5 labeled options (A-E) for the combined weather+air-quality
  gold metric, each with an honest weakness stated (not just strengths) —
  including flagging that the composite "comfort score" option has
  genuinely arbitrary weights the user would need to defend if asked, and
  that a ~40-point correlation is a thin statistical sample.

**Why this entry is worth reading on its own:** three separate real
findings in one continuous piece of work (a join missing the country
check, an accent mismatch, a country-representation mismatch between
sources), each caught by actually running a query against real data
immediately after writing it, not by getting either query right on the
first try.

## 2026-09-13 (continued) — Country-code dictionary, UDF-vs-table finding, bronze build

**Prompts:**
1. *"when you do the iso vs full name conversaions, I'd like you to use a
   macro like function that will be called, int he format of a dictionary
   ... I'd rather you use iso ... so we don't have to hand pick cities for
   unambiguous cases."*
2. *"alternatively, we could create a bigquery table with this information
   of the 180 country name conversioans. Evaluate pros and cons and
   suggest a decision"*
3. *"explain the role of the udf"*
4. *"proceed; stop between tier implementations for a live test and
   review: run the tests give me a summary for review"*
5. *"commit and proceed to silver"*, *"make sure to keep the documentation
   up to date as zell"*

**What the AI did:**
- Built the requested "dictionary": `bronze.country_code_map`, populated
  from the **real distinct country values in `raw_data.import_csv_data`**
  (175 of them) via `pycountry`, not hand-typed from memory or scoped only
  to the ~40 cities already in use — directly addressing "so we don't have
  to hand pick cities for unambiguous cases."
- Attempted the requested "macro-like function" wrapping that table as a
  SQL UDF, then **tested it in the actual use case (bulk per-row
  resolution) rather than just the happy-path scalar call**, and found it
  doesn't work: two different BigQuery errors depending on whether it's
  called in a JOIN condition or a SELECT list. Reported this to the user
  with the exact error text before proposing an alternative, rather than
  silently swapping the approach or asserting the function "should" work.
- Built `bronze.weather` and `bronze.air_quality` for real (SQL saved to
  `sql/bronze/`), ran 4 concrete tests against them (row-count/dedup
  delta, zero remaining duplicate keys, a plausibility check on the typed
  AQI values, and country-resolution coverage), and reported the results
  — including the honest one that dedup actually removed 4 real weather
  duplicates, which is evidence for a claim made earlier in
  `docs/architecture.md` ("insertId dedup is best-effort, not
  guaranteed") that had until now only been asserted, not observed.

**Corrected — caught by testing the actual use case, not the easy one:**
The UDF-wrapping-a-table pattern looked correct after its first test
(`SELECT bronze.country_to_iso('France')` worked). It was only proven
wrong by testing it the way it would actually be used — per-row, against
a table, inside a join — which is precisely the gap between "looks right"
and "confirmed by a live run" this whole log keeps coming back to.

**A small thing worth being honest about:** two manual overrides in
`build_country_code_map.py` (`"Turkey"`, `"Venezuela (Bolivarian Republic
of)"`) were only found because an `assert` in the script failed loudly on
the first run against the real (175-country) list — an earlier, smaller
check based on a flawed local CSV export had only surfaced 3 overrides
against 100 countries. If that assert hadn't been there, the pipeline
would have silently loaded `NULL` for those countries' rows instead of
failing to build.

## 2026-09-13 (continued) — Silver join, and a wrong-not-missing bug

**What the AI did:** built `silver.weather_air_quality` (the cross-source
join) and ran it against the real bronze tables.

**Corrected — a genuinely dangerous class of bug, not just a gap:**
The first silver build returned 39 matched cities, one short of the
expected 40. Investigated which city was missing (Seoul) rather than
accepting "close enough." Traced to `bronze.country_code_map`: the
build script's fuzzy-match fallback had resolved `"Republic of Korea"`
to **`KP` — North Korea's ISO code** — silently, with no error, because
the script only asserted on *unmatched* names, not on whether a match was
*correct*. This is meaningfully worse than the missing-data cases found
earlier (Lagos/Stockholm with `NULL` country): those are visible gaps;
this was a confident wrong answer with the same "shape" as a correct one.
Fixed by moving it to an explicit override, and then — since one silently
wrong fuzzy match means the whole fuzzy-match path can't be trusted —
auditing every other fuzzy-matched entry too, not just the one that
happened to break something visible. One more (`"State of Palestine"` →
`PS`) turned out correct, but was moved to an explicit override anyway,
so the shipped table has zero entries resolved by an unaudited heuristic,
rather than "zero currently-known-bad" ones.

**Why this is the most important finding of the session, not just
another bug:** every previous fix in this log was caught because
something *failed visibly* (an error, a missing row, a 403). This one
didn't fail at all — it produced a plausible, silently wrong output that
would have shipped as correct if the row count hadn't been checked
against an independently-known expected value. "The build succeeded" and
"the build is correct" are different claims, and this is the one place
in this whole exercise where that distinction was the entire finding.

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
