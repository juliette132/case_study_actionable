# Project guidelines

GCP-native ingestion pipeline for Actionable's take-home exercise. Read
`README.md` for setup/status and `docs/architecture.md` +
`docs/transform_layer_plan.md` for design. This file is standing
conventions for anyone (human or AI) continuing work here — re-read it,
don't just skim once.

## Hard constraints (from the brief)

- GCP-native end-to-end. No turnkey/low-code ingestion tools. Cloud
  Functions, Cloud Run, Scheduler, BigQuery Scheduled Queries, Dataform —
  all fine; anything that replaces writing the pipeline logic yourself
  isn't.
- Documenting AI tool usage is **mandatory**, not optional polish. Every
  AI-assisted change gets an entry in `docs/ai_usage_log.md`: prompts,
  what was produced, and specifically **where output was trusted as-is
  vs. corrected** — the corrections matter more than the successes.

## Git workflow

- **Never create a branch unless explicitly asked for one.** Do not
  proactively branch "to be safe" or "per house style" before making
  changes. Commit locally on whatever branch is currently checked out.
  The GitHub ruleset already blocks pushing/merging straight to `main`
  without a PR, so this can't silently corrupt `main` — it just means
  branching and opening a PR are things the user asks for, not things
  that happen automatically alongside every change.
- **When a branch is explicitly requested: it targets `main` directly.
  Never branch off another unmerged feature branch**, even when the new
  work genuinely needs files that only exist there. This was gotten wrong
  four times in a row on this repo (stacking plan→bronze→silver→gold
  branches on each other), and one instance actually merged into the
  wrong branch before being caught, silently leaving `main` without an
  entire tier of work. If work truly depends on another branch's unmerged
  content, wait for that branch to merge first, or accept the PR's diff
  will look bundled until it does — don't chain branches to work around it.
- One PR per logical unit of work, always into `main`. This repo uses a
  GitHub ruleset blocking direct pushes/merges to `main` without a PR.
- **Separate commits for source/code changes vs. documentation changes**,
  even when they land in the same turn. Don't mix them in one commit.
- Merging a PR requires the user (or their explicit go-ahead) — Claude
  Code's own safety layer blocks self-merging without review, correctly.
  Don't try to route around that block.
- This repo is **public**. Never commit secrets, or anything
  credential-shaped (tokens, account IDs, connection strings) even if the
  actual password/key lives elsewhere (e.g. Secret Manager). If a commit
  gets blocked as a credential-leakage risk, that's very likely correct —
  revert to a placeholder/env-var pattern rather than push past it.

## Verification philosophy — the thing this project keeps re-learning

Every real bug found in this project's history was caught by **actually
running something against real infrastructure**, not by code review:
schema-mutation logic that silently no-op'd, a BigQuery platform
limitation (REQUIRED columns can't be added post-creation), a missing
env var Cloud Functions doesn't auto-populate despite docs suggesting
otherwise, a Git-Bash path-mangling bug, a fuzzy-matched country code
that was confidently wrong (Korea → KP instead of KR) with zero error
raised, and the four-times-repeated branch-targeting mistake above.

The standing rule this implies: **"it ran without an error" and "it's
correct" are different claims.** Before treating any new script, query,
or config as done:
- Run it against the real project (`case-study-act`), not just against
  assumptions about how a platform behaves.
- Check the actual output against an independently-known expectation
  (a row count, a specific value, a regression check on a previous fix) —
  not just "did it execute."
- When a heuristic or library call "succeeds" (returns a non-null/non-error
  result), that is not the same as it being *correct* — audit what it
  actually produced, especially for anything with real-world semantic
  weight (country codes, geographic matches, financial figures).

## Architecture summary

- `raw_data.*` — ingestion landing tables (bronze, informally), built by
  `functions/weather_ingest` and `functions/sftp_ingest`, deployed as
  Cloud Functions on hourly Cloud Scheduler jobs in `europe-west1`.
- `bronze.*` — normalized/typed/deduplicated (`sql/bronze/`). Country-code
  resolution is a **table + plain JOIN** (`bronze.country_code_map`,
  built by `scripts/build_country_code_map.py`), not a UDF — BigQuery
  can't call a table-referencing SQL UDF per-row against another table
  (confirmed live, not assumed).
- `silver.*` — the one cross-source join (`sql/silver/`), pruned to what
  gold needs.
- `analytics.*` — gold aggregates (`sql/gold/`).
- Deploy scripts (`scripts/deploy_*.sh`) are written for review, not
  auto-run — always get an explicit go-ahead before executing a deploy.

## Local environment notes

- `gcloud`/`bq` aren't reliably on PATH in a fresh shell on this machine —
  the working pattern (Bash/Git Bash) is:
  ```
  export PATH="/c/Program Files/Python314:$PATH:/c/Users/julie/AppData/Local/Google/Cloud SDK/google-cloud-sdk/bin"
  export CLOUDSDK_PYTHON="/c/Program Files/Python314/python.exe"
  ```
  (PowerShell instead just needs the Machine+User PATH re-read into
  `$env:Path` each call.)
- Git Bash on Windows (MSYS) silently rewrites a bare `/` argument into a
  Windows path when passed to a non-MSYS executable like `gcloud` — if a
  value that should be `/` comes out wrong after a Bash-run command,
  that's why; redo the specific call from PowerShell instead.
