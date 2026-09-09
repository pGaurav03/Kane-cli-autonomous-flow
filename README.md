# Kane-CLI Autonomous Flow

A fully autonomous, end-to-end test flow built **only on [kane-cli](https://testmuai.com)** — no external AI agent (no Claude, no ChatGPT, no custom orchestrator) and no human checkpoints in the happy path.

Give it a requirement doc, a Jira/Confluence link, or just a one-line objective — it authors tests in a real browser, runs them, and (when given a requirement source) reports exactly what's proven vs. still owed.

## Three ways to run it

There are **two GitHub Actions workflows** in this repo. Pick based on what you need:

| Workflow | When to use | Speed | Reliability |
|---|---|---|---|
| **Kane-CLI Quick Run** (`kane-quick-run.yml`) | A single, one-off browser check — a login, a page-load check, a quick sanity test | ~1–2 min | Highest — no template variables, no multi-scenario generation, nothing to misconfigure |
| **Kane-CLI Autonomous Flow — objective mode** (`kane-autonomous-flow.yml`, `objective` + `url` fields) | You want kane-cli to generate *several* test cases (positive/negative/security) from one description, author, and batch-replay them | ~5–10 min | Good, once you follow the objective-writing rule below |
| **Kane-CLI Autonomous Flow — source mode** (`kane-autonomous-flow.yml`, `source` field) | You have a requirement doc/PRD/Jira ticket and want full traceability — every test cited back to the exact requirement line, plus a coverage report | 15–30+ min (scales with how many use-cases the doc yields) | Good, but slowest — each use-case is designed and authored one at a time |

**Start with Quick Run** to prove the pipeline works, then move to the fuller flows.

## How to run each, step by step

1. Go to the repo on GitHub → **Actions** tab
2. Click the workflow name in the left sidebar (**Kane-CLI Quick Run** or **Kane-CLI Autonomous Flow**)
3. Click **Run workflow** (top right) → fill in the fields → **Run workflow** (green button)
4. Wait for the green checkmark. Click into the run to see live logs.

**Quick Run** — only one field:
```
objective: Go to https://the-internet.herokuapp.com/login, log in with username "tomsmith"
           and password "SuperSecretPassword!", and verify the message
           "You logged into a secure area!" is displayed
```

**Autonomous Flow, objective mode** — fill `objective` + `url`, leave `source` blank:
```
objective: Login to https://www.saucedemo.com as user "standard_user" with password
           "secret_sauce" and verify the Products page is displayed
url:       https://www.saucedemo.com
```

**Autonomous Flow, source mode** — fill `source`, leave `objective`/`url` blank:
```
source: demo-prd.md
```

`project` / `folder` (optional, both modes): a Test Manager project/folder name. If it already exists it's reused; if not, it's created automatically. Leave blank to let kane-cli auto-pick one.

## ⚠️ The one rule that matters most: never write `{{url}}` literally in an objective

Write the real address directly in the objective text — `Go to https://example.com and ...` — never the placeholder `{{url}}`. `{{...}}` syntax is for *data* variables kane-cli should treat as reusable inputs (like `{{username}}`); when the *entry URL itself* gets turned into `{{url}}`, kane-cli's variable resolution isn't reliable across every generated scenario, and a run can silently land on kane-cli's own sandbox site instead of yours. This bit us twice while building this repo — every reliable run here writes the URL out in full.

## Where results actually live

**If you ran it locally** (`./kane-autonomous-flow.sh …` on your own machine): everything is written to your working directory —
```
.testmuai/tests/*_test.md   ← the authored tests
.context/                   ← Path B only, kane-cli's requirement↔test store
coverage.json                ← Path B only, the traceability report
kane-flow-<timestamp>.log    ← full run log
```
These stay on your disk until you commit or delete them.

**If you ran it via GitHub Actions**: the run happens on a temporary GitHub server that's destroyed right after — nothing lands on your own machine automatically. Two places to find the actual output:

1. **Artifacts (files)** — open the finished run → scroll to the bottom → **Artifacts** → download `kane-flow-output.zip`. Inside: the run log, every authored `_test.md`, and (source mode only) `coverage.json`.
2. **TestmuAI Test Manager (the live dashboard)** — every authored/replayed test also uploads to your TestmuAI account automatically, regardless of local vs. CI. Each test's summary line in the run log carries a `share_url` — open it and you get a hosted dashboard page per test (steps, screenshots, pass/fail, credits used). This is the same dashboard your team would use day to day; it doesn't require downloading anything.

Authored tests are **not** auto-committed back into the git repo by these workflows — they only exist in the Artifacts zip and on the Test Manager dashboard unless you manually copy them in and commit.

## Where to see the traceability report

Traceability (which requirement line is proven by which test) only exists for **source mode** (a real requirement doc was ingested — Quick Run and objective mode have no requirement to trace back to). Two ways to read it:

- **`coverage.json`** in the Artifacts zip — the full nested JSON: designed % × proven % + per-use-case debt, each with a `ready_command` for what to do next.
- **`kane-cli cover gaps`** — if you ever run the flow locally, this prints the same data as a human-readable dual-axis tree straight to the terminal.

## Requirements

- [kane-cli](https://testmuai.com) `>= 0.7.1`, logged in (`kane-cli whoami`)
- `jq`
- A TestmuAI account with credentials (Settings → Keys)
- For Jira/Confluence sources: that site already connected under LambdaTest → Integrations
- Repo secrets for CI: `KANE_USERNAME`, `KANE_ACCESS_KEY` (**Settings → Secrets and variables → Actions**)

## Run it locally

```bash
chmod +x kane-autonomous-flow.sh

# Path A — objective only (write the real URL directly in the objective, see rule above)
./kane-autonomous-flow.sh --objective "Go to https://your-app.com and verify dashboard loads" --url https://your-app.com

# Path B — requirement doc
./kane-autonomous-flow.sh --source ./demo-prd.md

# Path B — Jira / Confluence
./kane-autonomous-flow.sh --source "https://yoursite.atlassian.net/browse/PROJ-123"

# Either path — pin a Test Manager project/folder (created if it doesn't exist)
./kane-autonomous-flow.sh --source ./demo-prd.md --project "My Project" --folder "Smoke Tests"
```

Windows: run it from **Git Bash** or **WSL** — it's a bash script, so it won't run by double-clicking.

Optional tuning (env var): `KANE_PARALLEL` (default `4`) — number of parallel browser workers during batch replay.

## What happens under the hood

**Path A (objective mode):**
```
generate → generate --save → testmd run (author, one test at a time) → testrun run (batch replay)
```

**Path B (source mode):**
```
context ingest → context review (auto-approved) → design tests (one use-case at a time)
  → context review (auto-approved) → testmd run (author) → testrun run (batch replay) → cover gaps
```

In Path B, kane-cli normally pauses twice for a human to approve what it proposed. This script removes both pauses by pulling the pending items (`context list --json --inferred`) and auto-approving them itself — that's what makes the whole thing hands-off.

**Resilience:** if one use-case fails to design, or one test fails to author (kane-cli's own bug-detection sometimes flags a real or suspected app defect, or hits a flaky click), the script logs it and moves on to the rest — it only stops completely if *everything* in that stage failed. Check the log's `Design summary:` / `Authoring summary:` lines for the pass/fail count.

**The one thing that never runs unattended:** if a requirement is later *deleted* from a source doc, retiring the tests built on it (`maintain reconcile`'s ARCHIVE step) always needs an interactive session — kane-cli refuses to do this headless, by design. This flow doesn't hit that case in normal use; it only matters the day a requirement gets removed.

## Output files reference

| File | Where | What it is |
|---|---|---|
| `kane-flow-<timestamp>.log` | local dir, or Artifacts zip | Every stage the run entered, in order — start here when debugging |
| `.testmuai/tests/*_test.md` | local dir, or Artifacts zip | The authored tests — plain text, safe to read/commit |
| `coverage.json` | local dir, or Artifacts zip | Source mode only — which requirement lines are proven vs. still owed |
| `.context/` | local dir only (gitignore this) | Source mode only — kane-cli's own store; never hand-edit |
| Test Manager dashboard (`share_url` in the log) | cloud, always | Per-test execution detail: steps, screenshots, pass/fail |

## Exit codes

| Code | Meaning |
|---|---|
| `0` | Completed clean |
| `1` | A stage failed outright — check the log line above `FATAL` |
| `3` | Source mode only — paused on a question it wouldn't answer unattended; resolve it in the source doc and re-run |

## Demo

`demo-prd.md` in this repo is a ready-to-use example against [saucedemo.com](https://www.saucedemo.com), covering login, product sorting, product details, and logout — deliberately **no cart/checkout interactions**, since those proved unreliable to automate headlessly in CI while building this repo. Run via **Actions → Kane-CLI Autonomous Flow → source: `demo-prd.md`**, or locally:

```bash
./kane-autonomous-flow.sh --source demo-prd.md
```

For the fastest possible green run, use **Kane-CLI Quick Run** instead with a simple login objective (see example above).
