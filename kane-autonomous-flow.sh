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
PROJECT_NAME=""
FOLDER_NAME=""
PARALLEL="${KANE_PARALLEL:-4}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)    SOURCE="$2";       MODE="assurance"; shift 2 ;;
    --objective) OBJECTIVE="$2";    MODE="direct";     shift 2 ;;
    --url)       URL="$2";          shift 2 ;;
    --project)   PROJECT_NAME="$2"; shift 2 ;;
    --folder)    FOLDER_NAME="$2";  shift 2 ;;
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

resolve_or_create() {
  # Generic "find by name, else create" for `kane-cli projects` / `folders`.
  # No manual CLI step needed, ever — reuses an existing project/folder by
  # exact name if one exists, creates it otherwise. Logs raw output so a
  # field-name mismatch is fixable from the log alone.
  local kind="$1" name="$2"   # kind = "projects" | "folders"
  local listing="$WORKDIR/.${kind}-list-$$.json"
  local created="$WORKDIR/.${kind}-create-$$.json"
  local id_expr='(.id // .project_id // .folder_id // .cid)'

  kane-cli "$kind" list --search "$name" --agent > "$listing" 2>>"$LOG" || true
  log "$kind list --search \"$name\" raw output:"
  cat "$listing" >> "$LOG"

  local id
  id=$(jq -s -r --arg name "$name" "[.[] | select(._meta != \"page\") | select(.name == \$name)] | .[0] | $id_expr // empty" "$listing")

  if [[ -n "$id" && "$id" != "null" ]]; then
    log "$kind '$name' already exists (id=$id) — reusing it."
  else
    log "$kind '$name' not found — creating it."
    kane-cli "$kind" create "$name" --agent > "$created" 2>>"$LOG"
    log "$kind create \"$name\" raw output:"
    cat "$created" >> "$LOG"
    id=$(jq -s -r "[.[] | select($id_expr != null)] | .[0] | $id_expr" "$created")
  fi

  rm -f "$listing" "$created"
  if [[ -z "$id" || "$id" == "null" ]]; then
    log "FATAL: could not resolve or create $kind '$name' — check the raw output above in $LOG."
    exit 1
  fi
  echo "$id"
}

configure_project_folder() {
  if [[ -n "$PROJECT_NAME" ]]; then
    log "Resolving project: $PROJECT_NAME"
    local pid
    pid=$(resolve_or_create projects "$PROJECT_NAME")
    kane-cli config project "$pid"
    log "Project set to '$PROJECT_NAME' (id=$pid)."

    if [[ -n "$FOLDER_NAME" ]]; then
      log "Resolving folder: $FOLDER_NAME"
      local fid
      fid=$(resolve_or_create folders "$FOLDER_NAME")
      kane-cli config folder "$fid"
      log "Folder set to '$FOLDER_NAME' (id=$fid)."
    fi
  fi
}

auto_approve_pending() {
  # Pulls every unreviewed node and approves it — this is the scripted
  # stand-in for the human checkpoint. Runs local + free (no AI call).
  local pending="$WORKDIR/.pending-$$.json"
  local verdicts="$WORKDIR/.verdicts-$$.json"
  kane-cli context list --json --inferred > "$pending"
  log "context list --json --inferred raw output:"
  cat "$pending" >> "$LOG"
  local count
  # kane-cli emits NDJSON (one JSON object per line), not a single array —
  # slurp with -s before treating it as one. The identifying field's exact
  # name isn't pinned by the docs, so try the plausible candidates in order.
  local REF_EXPR='(.ref // .logical_id // .node_ref // .id // .cid)'
  count=$(jq -s "[.[] | select($REF_EXPR != null)] | length" "$pending")
  if [[ "$count" -eq 0 ]]; then
    log "Nothing pending review."
    rm -f "$pending"
    return 0
  fi
  jq -s "[.[] | select($REF_EXPR != null) | {ref: $REF_EXPR, resolution: \"approved\"}]" "$pending" > "$verdicts"
  log "Auto-approving $count pending item(s)."
  kane-cli context review --verdicts "$verdicts" --json | tee -a "$LOG"
  rm -f "$pending" "$verdicts"
}

author_all_tests() {
  # Authors every .testmuai/tests/*_test.md file, one at a time. A single
  # flaky/buggy scenario (kane-cli's own bug-detection can fail a test on
  # a real app defect) must not take down every other test — so failures
  # here are logged and skipped, not fatal, unless ALL of them fail.
  local extra_args=("$@")
  local total=0 passed=0 failed=0
  local failed_names=()
  : > "$WORKDIR/.authored-tests.list"
  # generate --save nests files under a per-request subfolder
  # (.testmuai/tests/<slug>-<id>/*_test.md), not directly in tests/ — find
  # recurses, a bare glob doesn't.
  while IFS= read -r f; do
    [[ -e "$f" ]] || continue
    total=$((total + 1))
    log "Authoring: $f"
    set +e
    kane-cli testmd run "$f" --agent --headless "${extra_args[@]}" 2>&1 | tee -a "$LOG"
    local code=${PIPESTATUS[0]}
    set -e
    if [[ $code -eq 0 ]]; then
      passed=$((passed + 1))
      echo "$f" >> "$WORKDIR/.authored-tests.list"
    else
      failed=$((failed + 1))
      failed_names+=("$f")
      log "Authoring FAILED for $f (exit $code) — continuing with the rest."
    fi
  done < <(find .testmuai/tests -type f -name '*_test.md' | sort)
  log "Authoring summary: $passed/$total passed, $failed failed."
  if [[ $failed -gt 0 ]]; then
    log "Failed tests: ${failed_names[*]}"
  fi
  if [[ $total -gt 0 && $passed -eq 0 ]]; then
    log "FATAL: every test failed to author — nothing to replay."
    exit 1
  fi
}

design_all_use_cases() {
  # Runs `design tests` once per trusted use-case ref (passed as args).
  # A single use-case can fail on a kane-cli-side validation error (seen in
  # practice: "every AC must be claimed by the step that proves it") — that
  # must not kill designing for every other use-case. Only a genuine pause
  # (exit 3, a high-risk question) or total failure stops the whole flow.
  local total=0 designed=0 failed=0
  local failed_names=()
  for uc in "$@"; do
    total=$((total + 1))
    log "Designing tests for use-case: $uc"
    set +e
    kane-cli design tests --use-case "$uc" --mode agent --max 8 2>&1 | tee -a "$LOG"
    local code=${PIPESTATUS[0]}
    set -e
    if [[ $code -eq 0 ]]; then
      designed=$((designed + 1))
    elif [[ $code -eq 3 ]]; then
      failed=$((failed + 1))
      failed_names+=("$uc (paused on a question no human is here to answer)")
      log "Design PAUSED for $uc (exit 3) — skipping it, continuing with the rest."
    else
      failed=$((failed + 1))
      failed_names+=("$uc")
      log "Design FAILED for $uc (exit $code) — continuing with the rest."
    fi
  done
  log "Design summary: $designed/$total use-cases designed, $failed failed."
  if [[ $failed -gt 0 ]]; then
    log "Failed use-cases: ${failed_names[*]}"
  fi
  if [[ $total -gt 0 && $designed -eq 0 ]]; then
    log "FATAL: every use-case failed to design — nothing to author."
    exit 1
  fi
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

configure_project_folder

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
  author_all_tests --url "$URL"

  log "Batch replay..."
  if [[ -s "$WORKDIR/.authored-tests.list" ]]; then
    mapfile -t AUTHORED_FILES < "$WORKDIR/.authored-tests.list"
    kane-cli testrun run "${AUTHORED_FILES[@]}" --headless --parallel "$PARALLEL" | tee -a "$LOG"
  else
    log "No successfully authored tests to replay — skipping batch replay."
  fi

else
  # ================= Path B: requirement doc / Jira / Confluence =================
  log "Ingesting + extracting use-cases from: $SOURCE"
  run_stage_exit3_is_fatal "context ingest" \
    kane-cli context ingest "$SOURCE" --mode agent

  auto_approve_pending

  log "Designing tests for every now-trusted use-case..."
  UC_REFS=$(kane-cli context list --json | jq -r -s '.[] | select(.trust=="trusted") | (.ref // .logical_id // .node_ref // .id // .cid)')
  design_all_use_cases $UC_REFS

  auto_approve_pending

  log "Authoring each designed test once (real browser)..."
  if [[ -n "$URL" ]]; then
    author_all_tests --url "$URL"
  else
    author_all_tests
  fi

  log "Batch replay..."
  kane-cli testrun run --match 't-' --headless --parallel "$PARALLEL" | tee -a "$LOG"

  log "Coverage report (requirement -> test -> proven)..."
  kane-cli cover gaps --json > "$WORKDIR/coverage.json"
  log "Coverage written to $WORKDIR/coverage.json"

  log "Traceability graph (visual HTML, requirement -> use-case -> test)..."
  kane-cli context view --no-open --out "$WORKDIR/traceability.html" 2>&1 | tee -a "$LOG" || true
  log "Traceability graph written to $WORKDIR/traceability.html"
fi

log "Flow complete. Full log: $LOG"
