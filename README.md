# Kane-CLI Autonomous Flow

A fully autonomous, end-to-end test flow built **only on [kane-cli](https://testmuai.com)** — no external AI agent (no Claude, no ChatGPT, no custom orchestrator) and no human checkpoints in the happy path.

Give it a requirement doc, a Jira/Confluence link, or just a one-line objective — it authors tests in a real browser, runs them, and (when given a requirement source) reports exactly what's proven vs. still owed.

## How it works

Two paths, picked automatically by which flag you pass:

**Path A — bare objective, no requirement doc**
```
generate → generate --save → testmd run (author) → testrun run (batch replay)
```

**Path B — requirement doc / Jira / Confluence**
```
context ingest → context review (auto-approved) → design tests
  → context review (auto-approved) → testmd run → testrun run → cover gaps
```

In Path B, kane-cli normally pauses twice for a human to approve what it proposed. This script removes both pauses by pulling the pending items (`context list --json --inferred`) and auto-approving them itself — that's what makes the whole thing hands-off.

**The one thing that never runs unattended:** if a requirement is later *deleted* from a source doc, retiring the tests built on it (`maintain reconcile`'s ARCHIVE step) always needs an interactive session — kane-cli refuses to do this headless, by design. This flow doesn't hit that case in normal use; it only matters the day a requirement gets removed.

## Requirements

- [kane-cli](https://testmuai.com) `>= 0.7.1`, logged in (`kane-cli whoami`)
- `jq`
- A TestmuAI account with credentials (Settings → Keys)
- For Jira/Confluence sources: that site already connected under LambdaTest → Integrations

## Run it locally

```bash
chmod +x kane-autonomous-flow.sh

# Path A — objective only
./kane-autonomous-flow.sh --objective "Login to {{url}} and verify dashboard loads" --url https://your-app.com

# Path B — requirement doc
./kane-autonomous-flow.sh --source ./demo-prd.md

# Path B — Jira / Confluence
./kane-autonomous-flow.sh --source "https://yoursite.atlassian.net/browse/PROJ-123"
```

Windows: run it from **Git Bash** or **WSL** — it's a bash script, so it won't run by double-clicking.

Optional tuning (env vars): `KANE_PARALLEL` (default `4`) — parallel browser workers; `KANE_RETRIES` (default `3`) — retries on a flaky step.

## Run it from CI/CD (GitHub Actions)

This works from Windows, Mac, or Linux equally — the run itself happens on GitHub's own server, not your machine.

1. Add two repo secrets (**Settings → Secrets and variables → Actions**): `KANE_USERNAME`, `KANE_ACCESS_KEY` (from your TestmuAI dashboard → Settings → Keys)
2. Push `kane-autonomous-flow.sh` and `.github/workflows/kane-autonomous-flow.yml` to the repo
3. Go to the **Actions** tab → **Kane-CLI Autonomous Flow** → **Run workflow**
4. Fill in **either** `objective` + `url` (Path A) **or** `source` (Path B) — leave the other set blank
5. Download results from the **Artifacts** section once the run finishes

## Output

| File | What it is |
|---|---|
| `kane-flow-<timestamp>.log` | Every stage the run entered, in order |
| `.testmuai/tests/*_test.md` | The authored tests — plain text, safe to commit |
| `coverage.json` | Path B only — which requirement lines are proven vs. still owed |
| `.context/` | Path B only — kane-cli's own store; never hand-edit, gitignore it |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Completed clean |
| `1` | A stage failed outright — check the log line above `FATAL` |
| `3` | Path B only — paused on a question it wouldn't answer unattended; resolve it in the source doc and re-run |

## Demo

`demo-prd.md` in this repo is a ready-to-use example against [saucedemo.com](https://www.saucedemo.com) (a public site built for test automation demos). Run:

```bash
./kane-autonomous-flow.sh --source demo-prd.md
```
