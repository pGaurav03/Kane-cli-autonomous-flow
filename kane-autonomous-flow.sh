#!/usr/bin/env bash
#
# kane-autonomous-flow.sh — fully autonomous, human-free, AI-agent-free
# end-to-end test flow built ONLY on kane-cli.
#
# Requires: kane-cli >= 0.7.1, jq
#
# ---- INPUT FLEXIBILITY (pick one) ----
#
#   1) Plain objective + URL (no requirement doc at all):
#        ./kane-autonomous-flow.sh --objective "Login to {{url}} as demo user and verify dashboard loads" --url https://app.example.com
#
#   2) A requirement doc (PRD/spec — .md/.txt/.pdf/.docx):
#        ./kane-autonomous-flow.sh --source ./prd.md
#
#   3) A Jira issue or Confluence page URL (Atlassian integration must
#      already be connected in LambdaTest Integrations):
#        ./kane-autonomous-flow.sh --source "https://yoursite.atlassian.net/browse/PROJ-123"
#
# In modes 2/3, everything the tool proposes (use-cases, then designed
# tests) is auto-approved by this script — that's what makes it
# autonomous. No human ever has to look at anything for the flow to
# complete. (The ONE thing kane-cli itself refuses to auto-apply, ever,
# is retiring/archiving a use-case whose requirement text was deleted
# from a later doc version during `maintain reconcile` — that is not
# part of this flow, only of handling requirement deletions later.)

set -euo pipefail

MODE=""
SOURCE=""
OBJECTIVE=""
URL=""
PARALLEL="${KANE_PARALLEL:-4}"
RETRIES="${KANE_RETRIES:-3}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)    SOURCE="$2";    MODE="assurance"; shift 2 ;;
    --objective) OBJECTIVE="$2"; MODE="direct";     shift 2 ;;
    --url)       URL="$2";       shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "Usage: $0 (--objective \"<text>\" --url <url>) | (--source <file-or-jira/confluence-url>)" >&2
  exit 1
fi

export KANE_CLI_USER_AGENT="autonomous-flow"
WORKDIR="$(pwd)"
LOG="$WORKDIR/kane-flow-$(date +%Y%m%d-%H%M%S).log"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

auto_approve_pending() {
  # Pulls every unreviewed node and approves it — this is the scripted
  # stand-in for the human checkpoint. Runs local + free (no AI call).
  local pending="$WORKDIR/.pending-$$.json"
  local verdicts="$WORKDIR/.verdicts-$$.json"
  kane-cli context list --json --inferred > "$pending"
  local count
  count=$(jq 'length' "$pending")
  if [[ "$count" -eq 0 ]]; then
    log "Nothing pending review."
    rm -f "$pending"
    return 0
  fi
  jq '[.[] | {ref: .ref, resolution: "approved"}]' "$pending" > "$verdicts"
  log "Auto-approving $count pending item(s)."
  kane-cli context review --verdicts "$verdicts" --json | tee -a "$LOG"
  rm -f "$pending" "$verdicts"
}

run_stage_exit3_is_fatal() {
  # For assurance commands, exit 3 = paused on a high-risk question.
  # With no human to answer it, we cannot proceed — fail loudly instead
  # of hanging or guessing.
  local desc="$1"; shift
  set +e
  "$@" 2>&1 | tee -a "$LOG"
  local code=${PIPESTATUS[0]}
  set -e
  if [[ $code -eq 3 ]]; then
    log "FATAL: '$desc' paused on a high-risk question it needs a human to answer — cannot continue autonomously. See $LOG."
    exit 3
  elif [[ $code -ne 0 ]]; then
    log "FATAL: '$desc' failed (exit $code). See $LOG."
    exit $code
  fi
}

if [[ "$MODE" == "direct" ]]; then
  # ================= Path A: objective-only, no requirement doc =================
  log "Generating test cases from objective..."
  kane-cli generate "$OBJECTIVE" --agent | tee "$WORKDIR/generate.ndjson" >> "$LOG"
  REQ_ID=$(grep -o '"request_id":"[^"]*"' "$WORKDIR/generate.ndjson" | head -1 | cut -d'"' -f4)
  if [[ -z "$REQ_ID" ]]; then
    log "FATAL: could not read request_id from generate output."
    exit 1
  fi

  log "Saving generated Functional cases as runnable _test.md..."
  kane-cli generate --save --req "$REQ_ID" --agent | tee -a "$LOG"

  log "Authoring each saved test in a real browser..."
  for f in .testmuai/tests/*_test.md; do
    [[ -e "$f" ]] || continue
    kane-cli testmd run "$f" --agent --headless --url "$URL" --retry --retry-count "$RETRIES"
  done

  log "Batch replay..."
  kane-cli testrun run .testmuai/tests --agent --headless --parallel "$PARALLEL" --retry | tee -a "$LOG"

else
  # ================= Path B: requirement doc / Jira / Confluence =================
  log "Ingesting + extracting use-cases from: $SOURCE"
  run_stage_exit3_is_fatal "context ingest" \
    kane-cli context ingest "$SOURCE" --mode agent

  auto_approve_pending

  log "Designing tests for every now-trusted use-case..."
  UC_REFS=$(kane-cli context list --json | jq -r '.[] | select(.trust=="trusted") | .ref')
  for uc in $UC_REFS; do
    run_stage_exit3_is_fatal "design tests ($uc)" \
      kane-cli design tests --use-case "$uc" --mode agent --max 8
  done

  auto_approve_pending

  log "Authoring each designed test once (real browser)..."
  for f in .testmuai/tests/*_test.md; do
    [[ -e "$f" ]] || continue
    kane-cli testmd run "$f" --agent --headless --retry --retry-count "$RETRIES"
  done

  log "Batch replay..."
  kane-cli testrun run --match 't-' --agent --headless --parallel "$PARALLEL" --retry | tee -a "$LOG"

  log "Coverage report (requirement -> test -> proven)..."
  kane-cli cover gaps --json > "$WORKDIR/coverage.json"
  log "Coverage written to $WORKDIR/coverage.json"
fi

log "Flow complete. Full log: $LOG"
