#!/usr/bin/env bash
# Free tests for the use-omp skill: no model calls, a few seconds to run.
# Usage: scripts/test-offline.sh
#   1. summarize-events.jq against event fixtures (real omp 18.10.3 runs plus edge cases)
#   2. report.sh against a ledger fixture
#   3. run-omp.sh mechanics with a stub omp on PATH
#   4. verify-skill.sh usage errors and its declined-task pattern, without model calls
#   5. omp CLI facts the skill relies on, checked without sending a prompt (skipped if omp is absent)
# Run after any skill edit; scripts/verify-skill.sh runs it before its live checks.
set -uo pipefail

repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
skill="$repo/skills/use-omp"
fixtures="$repo/tests/fixtures"
work=$(CDPATH= cd -- "$(mktemp -d "${TMPDIR:-/tmp}/use-omp-offline.XXXXXX")" && pwd)
failures=0 skipped=0

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }
skip() { printf 'SKIP  %s\n' "$1"; skipped=$((skipped + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

# expect <fixture> <jq boolean expression over the summary> <description>
expect() {
  local summary
  summary=$(jq -s -f "$skill/scripts/summarize-events.jq" "$fixtures/events/$1.jsonl" 2> /dev/null) \
    || { fail "$1: summarize-events.jq failed"; return; }
  if printf '%s' "$summary" | jq -e "$2" > /dev/null 2>&1; then pass "$1: $3"; else fail "$1: $3"; fi
}

echo "== summarize-events.jq"
expect normal '.is_event_stream and .looks_complete and .session_id != null and .tool_calls.read >= 1
  and .tool_errors == [] and (.models | length) == 1 and .tokens > 0 and .primary_cost_usd > 0' \
  "a completed run with a file read is complete, with model, tokens, and cost"
expect deadline '.looks_complete == false and .assistant_messages == 0 and .final_text_chars == 0' \
  "a deadline before the first answer is not complete (omp exits 0 here)"
expect approval '.looks_complete and ([.tool_errors[] | select(.error | test("requires approval"))] | length) >= 1' \
  "a refused bash call under always-ask shows in tool_errors while the run looks complete"
expect subagent '.subagent_tasks >= 1 and .background_jobs == 0 and .subagent_failures == 0 and .subagent_cost_usd > 0' \
  "an inline subagent (async off) reports its cost and no background jobs"
expect background-job '.background_jobs == 1 and .background_job_types.task == 1 and .looks_complete' \
  "a background subagent is counted even though the run looks complete"
expect bash-background '.background_jobs == 1 and .background_job_types.bash == 1' \
  "a backgrounded bash command is counted"
expect edge-stop-with-toolcall '.looks_complete == false' "a stop that still carries a tool call is not final"
expect edge-pause-turn '.looks_complete == false' "a pause_turn stop is not final"
expect edge-no-agent-end '.looks_complete == false and .agent_end_seen == false' "a stream without agent_end is not complete"
expect edge-empty-text '.looks_complete == false' "an empty final answer is not complete"
expect edge-odd-records '.looks_complete' "non-object and untyped records are ignored, not fatal"
expect edge-edits '.write_targets == ["?", "agent://Helper", "lib/b.py", "lib/c.py", "src/**/*.ts", "src/a.ts"]' \
  "write targets parse hashline and apply_patch edits, keep ast_edit paths, and drop refused writes"
expect edge-session-transcript '.is_event_stream == false and .looks_complete == false' \
  "a session transcript is recognized as the wrong file"
expect edge-fallback '.final_model == "z/final" and .models == ["a/first", "z/final"]' \
  "final_model names the model of the final message when several answered"
expect edge-subagent-failure '.subagent_failures == 1 and .subagent_cost_usd == 0.005' \
  "aborted or failed subagents are counted and their cost included"
private_pattern='/Users/|-Users-|/home/|/root/|/var/folders/|claude-[0-9]+/|resp_[A-Za-z0-9]|[A-Za-z]:\\+Users|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,}'
check "the skill, scripts, fixtures, and docs contain no local paths, emails, or account-linked IDs (the repository is public)" \
  '! grep -rEq -e "$private_pattern" "$skill" "$fixtures" "$repo/docs" "$repo/README.md" "$repo/AGENTS.md" "$repo/scripts/verify-skill.sh"'
if git -C "$repo" rev-parse --git-dir > /dev/null 2>&1; then
  check "commit messages contain no local paths, emails, or account-linked IDs" \
    '! git -C "$repo" log --format=%B | grep -Eq -e "$private_pattern"'
fi
check "edge-truncated: a truncated last line makes the filter fail" \
  '! jq -s -f "$skill/scripts/summarize-events.jq" "$fixtures/events/edge-truncated.jsonl" > /dev/null 2>&1'

echo "== report.sh"
report() { USE_OMP_STATE_DIR="$fixtures/ledger" bash "$skill/scripts/report.sh" "$@"; }
report --json > "$work/report.json" 2> "$work/report.err" || fail "report.sh --json exited nonzero: $(cat "$work/report.err")"
rj() { jq -e "$1" "$work/report.json" > /dev/null 2>&1; }
check "malformed lines and non-ISO dates are skipped and counted" 'rj ".ledger_lines_skipped == 2 and .overall.runs == 6"'
check "completion and nonzero exits are counted" 'rj ".overall.complete == 5 and .overall.nonzero_exit == 1"'
check "runs with tool errors and runs with unexpected refusals are counted; read-only refusals and non-numeric fields count as neither" \
  'rj ".overall.with_tool_errors == 2 and .overall.refusal_runs == 1"'
check "the median ignores non-numeric durations and averages the middle pair" 'rj ".overall.median_duration_s == 250"'
check "costs sum primary and inline-subagent spend separately" 'rj ".overall.primary_cost_usd == 1 and .overall.subagent_cost_usd == 0.25"'
check "a null model is grouped under ?" 'rj ".by_model | has(\"?\")"'
check "runs are grouped by ISO week" 'rj ".by_week | keys == [\"2026-W42\", \"2026-W43\"]"'
check "problems list failures, background jobs, and unexpected refusals, oldest first, but not ordinary tool errors" \
  'rj "[.recent_problems[].label] == [\"failed\", \"background\", \"refused\"]"'
check "--since filters by UTC date" '[ "$(report --since 2026-10-14 --json | jq .overall.runs)" = 3 ]'
check "--since rejects a non-date with exit 2" 'report --since --json > /dev/null 2>&1; [ $? = 2 ]'
check "the text report renders" 'report | grep -q "^  overall: 6 runs"'

echo "== run-omp.sh with a stub omp"
stub="$work/stub-bin"; mkdir -p "$stub"
cat > "$stub/omp" <<'STUB'
#!/usr/bin/env bash
# Lookups the wrapper makes before a run: the catalog (STUB_MODELS, a file) and two settings.
empty_object='{}'
case ${1:-} in models|config) [ -n "${STUB_LOOKUP_LOG:-}" ] && echo "lookup=$1 pwd=$PWD configs=${PI_CONFIG_FILES:-}" >> "$STUB_LOOKUP_LOG" ;; esac
case ${1:-} in
  --version) echo omp/stub; exit 0 ;;
  models) if [ -n "${STUB_MODELS:-}" ]; then cat "$STUB_MODELS"; else echo '{"models":[]}'; fi; exit 0 ;;
  config)
    case ${3:-} in
      modelProviderOrder) echo "${STUB_PROVIDER_ORDER:-[]}" ;;
      modelRoles) echo "${STUB_ROLES:-$empty_object}" ;;
      *) echo null ;;
    esac
    exit 0 ;;
esac
{ echo "umask=$(umask)"; echo "pwd=$PWD"; printf 'arg=%s\n' "$@"; } > "$STUB_LOG"
# STUB_FAIL: fail at launch with this error and no events, then a hint line, as omp does for a bad --resume.
[ -n "${STUB_FAIL:-}" ] && { echo "$STUB_FAIL" >&2; echo "Run omp --resume without an argument to pick a session." >&2; exit 1; }
[ -n "${STUB_SLEEP:-}" ] && { trap 'exit 143' TERM; sleep "$STUB_SLEEP" & wait $!; }
# STUB_STREAM adds the progress-only events a real run streams.
[ -n "${STUB_STREAM:-}" ] && jq -cn '{type: "message_update", delta: "o"}, {type: "tool_execution_update", partial: "x"},
  {type: "tool_stream_update", chunk: "y"}'
# STUB_FALLBACK adds an earlier assistant message from another model, which sorts before stub/stub.
[ -n "${STUB_FALLBACK:-}" ] && jq -cn '{type: "message_end", message: {role: "assistant", provider: "a", model: "first", stopReason: "toolUse", content: [{type: "toolCall", id: "t1"}]}}'
# STUB_ANSWER names a file whose text becomes the final answer; the default answer is "ok".
jq -cn --arg text "$(if [ -n "${STUB_ANSWER:-}" ]; then cat "$STUB_ANSWER"; else echo ok; fi)" \
  '{type: "session", id: "stub-session"}, {type: "agent_start"},
   {type: "message_end", message: {role: "assistant", provider: "stub", model: "stub", stopReason: "stop", content: [{type: "text", text: $text}]}},
   {type: "agent_end"}'
STUB
chmod +x "$stub/omp"
stub_state="$work/stub-state"
printf 'stub task\n' > "$work/stub.task.md"
stub_run() {
  PATH="$stub:$PATH" STUB_LOG="$work/stub.log" USE_OMP_STATE_DIR="$stub_state" USE_OMP_SESSION_DIR="$work/stub-sessions" \
    bash "$skill/scripts/run-omp.sh" --workspace "$repo" --model stub/stub --prompt-file "$work/stub.task.md" "$@"
}
overlay_file() { grep -A1 -x "arg=--config" "$work/stub.log" | tail -1 | sed "s/^arg=//"; }
caller_umask=$(umask)
(cd "$work" && stub_run --label "stub normal" > "$work/stub.summary.json" 2> /dev/null)
check "omp inherits the caller's umask ($caller_umask), not the records' 077" 'grep -qx "umask=$caller_umask" "$work/stub.log"'
check "omp starts in the workspace (so .env matches an interactive launch)" 'grep -qx "pwd=$repo" "$work/stub.log"'
check "wrapper passes --cwd, --session-dir, --mode json, and an absolute @prompt" \
  'grep -qx "arg=--cwd" "$work/stub.log" && grep -qx "arg=--session-dir" "$work/stub.log" && grep -qx "arg=json" "$work/stub.log" && grep -q "^arg=@/.*/prompt.md$" "$work/stub.log"'
check "wrapper follows the @prompt with the typed task line, after --" \
  'grep -A2 "^arg=@/.*/prompt.md$" "$work/stub.log" | sed -n 2p | grep -qx "arg=--" \
   && grep -A2 "^arg=@/.*/prompt.md$" "$work/stub.log" | sed -n 3p | grep -qxF "arg=The attached file is my task for you. Carry it out."'
check "wrapper adds no approval flag without --read-only" '! grep -q "approval-mode" "$work/stub.log"'
async_overlay=$(printf "async:\n  enabled: false\nbash:\n  autoBackground:\n    enabled: false")
memory_overlay=$(printf "memory:\n  backend: off")
both_overlays="$async_overlay
$memory_overlay"
check "the overlay turns off async subagents, bash auto-backgrounding, and memory" \
  '[ "$(cat "$(overlay_file)")" = "$both_overlays" ]'
check "the ledger records that the wrapper turned memory off" \
  'jq -e "select(.label == \"stub normal\") | .memory_off == true" "$stub_state/runs.jsonl" > /dev/null'
check "the summary names the run directory and session file" \
  'jq -e ".run_dir != null and .session_file == null and .looks_complete" "$work/stub.summary.json" > /dev/null'
check "the ledger line carries the caller and the summary" \
  'jq -e "select(.label == \"stub normal\") | .exit == 0 and .looks_complete and .caller.cwd == \"$work\" and .async == false" "$stub_state/runs.jsonl" > /dev/null'
check "record files are private" '[ "$(ls -l "$stub_state/runs.jsonl" | cut -c1-10)" = "-rw-------" ]'
stub_run --label "stub read-only" --read-only > /dev/null 2>&1
check "--read-only adds --approval-mode always-ask" 'grep -qx "arg=always-ask" "$work/stub.log"'
stub_run --label "stub allow-async" --allow-async > /dev/null 2>&1
check "--allow-async leaves omp's background-job settings alone and still turns memory off" \
  '[ "$(cat "$(overlay_file)")" = "$memory_overlay" ]'
stub_run --label "stub memory" --memory > /dev/null 2>&1
check "--memory leaves omp's memory setting alone" \
  '[ "$(cat "$(overlay_file)")" = "$async_overlay" ] && jq -e "select(.label == \"stub memory\") | .memory_off == false" "$stub_state/runs.jsonl" > /dev/null'
: > "$work/stub.log"; stub_run --label "stub allow-async memory" --allow-async --memory > /dev/null 2>&1
check "--allow-async with --memory passes no overlay" 'grep -qx "pwd=$repo" "$work/stub.log" && ! grep -qx "arg=--config" "$work/stub.log"'
stub_run --label "stub resume" --resume stub-session > /dev/null 2>&1
check "--resume passes the session ID with the session dir" 'grep -A1 -x "arg=--resume" "$work/stub.log" | tail -1 | grep -qx "arg=stub-session"'
printf 'memory:\n  backend: mnemopi\n' > "$work/extra.yml"
stub_run --label "stub extra config" --config "$work/extra.yml" > /dev/null 2>&1
check "--config adds an overlay after the wrapper's overlay (so it wins) and is recorded in the ledger" \
  '[ "$(grep -A1 -x "arg=--config" "$work/stub.log" | grep -c "^arg=/")" = 2 ] && [ "$(grep -A1 -x "arg=--config" "$work/stub.log" | tail -1)" = "arg=$work/extra.yml" ] \
   && jq -e "select(.label == \"stub extra config\") | .extra_configs == [\"$work/extra.yml\"]" "$stub_state/runs.jsonl" > /dev/null'
check "a missing --config file is a usage error" 'stub_run --config "$work/nope.yml" > /dev/null 2>&1; [ $? = 2 ]'
stub_run --label "stub no-record" --no-record > /dev/null 2>&1
check "--no-record uses --no-session and writes no ledger line" \
  'grep -qx "arg=--no-session" "$work/stub.log" && ! grep -q "stub no-record" "$stub_state/runs.jsonl"'
# Background run-omp.sh itself (env execs bash), so $! is the wrapper's PID, not a subshell's.
env PATH="$stub:$PATH" STUB_LOG="$work/stub.log" STUB_SLEEP=30 USE_OMP_STATE_DIR="$stub_state" \
  USE_OMP_SESSION_DIR="$work/stub-sessions" bash "$skill/scripts/run-omp.sh" --workspace "$repo" --model stub/stub \
  --prompt-file "$work/stub.task.md" --label "stub signal" > /dev/null 2>&1 &
wrapper_pid=$!
sleep 2; kill -TERM "$wrapper_pid"; wait "$wrapper_pid"
check "a TERM to the wrapper stops omp and still writes the ledger line" \
  '[ "$(jq -s "map(select(.label == \"stub signal\")) | .[0].exit" "$stub_state/runs.jsonl")" = 143 ]'
STUB_FAIL='Error: Session "s1" belongs to a directory that no longer exists (/gone); run interactively to move it into the current project.' \
  stub_run --label "stub launch failure" --resume s1 > "$work/fail.summary.json" 2> /dev/null
check "a launch failure with no events takes final_error from stderr's last Error: line, not the hint after it" \
  'jq -e ".final_error | startswith(\"Error: Session \\\"s1\\\" belongs to a directory\")" "$work/fail.summary.json" > /dev/null \
   && jq -e "select(.label == \"stub launch failure\") | .exit == 1 and (.final_error | startswith(\"Error: Session\"))" "$stub_state/runs.jsonl" > /dev/null'
STUB_FALLBACK=1 stub_run --label "stub fallback" > /dev/null 2>&1
check "the ledger's model is the one that gave the final answer, not the first in sorted order" \
  'jq -e "select(.label == \"stub fallback\") | .model == \"stub/stub\" and .models == [\"a/first\", \"stub/stub\"]" "$stub_state/runs.jsonl" > /dev/null'
STUB_STREAM=1 stub_run --label "stub stream" > "$work/stream.summary.json" 2> /dev/null
check "progress-only events are dropped from the saved events file; the rest stay" \
  'f="$(jq -r .run_dir "$work/stream.summary.json")/events.jsonl"; ! grep -qE "\"type\":\"(message_update|tool_execution_update|tool_stream_update)\"" "$f" \
   && grep -q "\"type\":\"message_end\"" "$f" && jq -e .looks_complete "$work/stream.summary.json" > /dev/null'
check "usage errors exit 2" 'bash "$skill/scripts/run-omp.sh" --workspace > /dev/null 2>&1; [ $? = 2 ]'
check "an empty prompt file is a usage error" \
  ': > "$work/empty.md"; stub_run --prompt-file "$work/empty.md" > /dev/null 2>&1; [ $? = 2 ]'

echo "== run-omp.sh model selection"
# The same model ID under two providers (the catalog lists p2 first), one unique ID, and a longer ID
# that contains it.
cat > "$work/models.json" <<'JSON'
{"models": [{"id": "m1", "provider": "p2", "selector": "p2/m1"}, {"id": "m1", "provider": "p1", "selector": "p1/m1"},
  {"id": "solo", "provider": "p2", "selector": "p2/solo"}, {"id": "solo-1m", "provider": "p2", "selector": "p2/solo-1m"}]}
JSON
# model_run [run-omp.sh options...]: a stub run without the default --model. Set order (modelProviderOrder),
# roles (modelRoles), and env_model (USE_OMP_MODEL) before calling; the caller's own USE_OMP_MODEL is ignored.
no_roles='{}'
model_run() {
  : > "$work/stub.log"; : > "$work/lookup.log"
  (cd "$work" && env -u USE_OMP_MODEL STUB_LOOKUP_LOG="$work/lookup.log" ${env_model:+USE_OMP_MODEL="$env_model"} PATH="$stub:$PATH" STUB_LOG="$work/stub.log" \
    STUB_MODELS="$work/models.json" STUB_PROVIDER_ORDER="${order:-[]}" STUB_ROLES="${roles:-$no_roles}" \
    USE_OMP_STATE_DIR="$stub_state" USE_OMP_SESSION_DIR="$work/stub-sessions" \
    bash "$skill/scripts/run-omp.sh" --workspace "$repo" --prompt-file "$work/stub.task.md" "$@" > "$work/model.summary.json" 2> "$work/model.err")
}
model_arg() { grep -A1 -x "arg=--model" "$work/stub.log" | sed -n 2p | sed "s/^arg=//"; }
ledger_for() { jq -c "select(.label == \"$1\")" "$stub_state/runs.jsonl" | tail -1; }
order='["p1", "p2"]' roles= env_model=
model_run --model m1 --label "bare model"
check "a bare model ID offered by several providers resolves by modelProviderOrder, not catalog order" \
  '[ "$(model_arg)" = p1/m1 ] && grep -q "model=p1/m1" "$work/model.err"'
order='["P1"]'; model_run --model m1:high
check "the resolved selector keeps a :level suffix, and provider names match case-insensitively" '[ "$(model_arg)" = p1/m1:high ]'
model_run --model M1
check "bare IDs match case-insensitively, as omp's do" '[ "$(model_arg)" = p1/m1 ]'
roles='{"m1": "p2/solo"}'; model_run --model m1
check "an exact model ID wins over a role of the same name, as in omp" '[ "$(model_arg)" = p1/m1 ]'
roles=; model_run --model m1 --config "$work/extra.yml"
check "lookups run in the workspace with the caller's --config overlays, as the run itself does" \
  'grep -q "lookup=config pwd=$repo configs=$work/extra.yml" "$work/lookup.log" && ! grep -qv "pwd=$repo " "$work/lookup.log"'
order='[]'; model_run --model m1; rc=$?
check "an ambiguous bare ID with no modelProviderOrder is a usage error naming the candidates, before any run" \
  '[ $rc = 2 ] && grep -q "p1/m1" "$work/model.err" && grep -q "p2/m1" "$work/model.err" && [ ! -s "$work/stub.log" ]'
model_run --model solo
check "a bare ID offered by one provider resolves to it, not to a longer ID that contains it" '[ "$(model_arg)" = p2/solo ]'
model_run --model nope; rc=$?
check "an unknown bare ID is a usage error, before any run" '[ $rc = 2 ] && [ ! -s "$work/stub.log" ] && grep -q "Similar: none" "$work/model.err"'
model_run --model m9
check "an unknown bare ID suggests IDs with the same words" 'grep -q "Similar: .*p1/m1" "$work/model.err" && ! grep -qE "p2/solo(,|$)" "$work/model.err"'
roles='{"slow": "p1/m1:xhigh"}'; model_run --model slow
check "a configured role name passes through for omp to resolve" '[ "$(model_arg)" = slow ]'
roles=; model_run --model @slow
check "an @role alias passes through" '[ "$(model_arg)" = @slow ]'
model_run --model p9/anything
check "a provider/model selector passes through unchanged" '[ "$(model_arg)" = p9/anything ]'
model_run --label "omp default"
check "without --model or USE_OMP_MODEL, omp's default role picks the model; the ledger records the one that answered" \
  '! grep -qx "arg=--model" "$work/stub.log" && ledger_for "omp default" | jq -e ".model == \"stub/stub\" and .model_requested == null and .model_source == \"omp-default\"" > /dev/null'
env_model=p1/m1:high; model_run --label "env model"
check "USE_OMP_MODEL supplies the default model" \
  '[ "$(model_arg)" = p1/m1:high ] && ledger_for "env model" | jq -e ".model_requested == \"p1/m1:high\" and .model_source == \"env\"" > /dev/null'
model_run --model p2/solo --label "flag beats env"
check "--model overrides USE_OMP_MODEL" '[ "$(model_arg)" = p2/solo ] && ledger_for "flag beats env" | jq -e ".model_source == \"flag\"" > /dev/null'
env_model=

echo "== verify-skill.sh (no model calls)"
# A usage error must stop the live tier before it runs anything, so the stub omp records no call.
# If a parsing bug let verify-skill.sh start, it would run this script again; the guard skips this section
# in that nested run so it cannot recurse.
if [ -n "${USE_OMP_OFFLINE_NESTED:-}" ]; then
  echo "(skipped: started by verify-skill.sh, which this section launched)"
else
  verify_usage() {
    : > "$work/stub.log"
    USE_OMP_OFFLINE_NESTED=1 PATH="$stub:$PATH" STUB_LOG="$work/stub.log" USE_OMP_STATE_DIR="$work/verify-state" \
      USE_OMP_SESSION_DIR="$work/verify-sessions" bash "$repo/scripts/verify-skill.sh" "$@" > /dev/null 2>&1
  }
  check "verify-skill.sh without a model is a usage error (exit 2)" 'verify_usage; [ $? = 2 ] && [ ! -s "$work/stub.log" ]'
  check "verify-skill.sh rejects an unknown --probe (exit 2)" 'verify_usage --probe nope stub/stub; [ $? = 2 ] && [ ! -s "$work/stub.log" ]'
  check "verify-skill.sh rejects a second model argument (exit 2)" 'verify_usage stub/stub other/model; [ $? = 2 ] && [ ! -s "$work/stub.log" ]'
  check "verify-skill.sh rejects several probe names in one --probe (exit 2)" \
    'verify_usage --probe "approval subagent" stub/stub; [ $? = 2 ] && [ ! -s "$work/stub.log" ]'
  # verify_probe <answer fixture>: the approval probe against a stub that answers with the fixture's text
  # and makes no tool call.
  verify_probe() {
    USE_OMP_OFFLINE_NESTED=1 PATH="$stub:$PATH" STUB_LOG="$work/probe-stub.log" STUB_ANSWER="$1" \
      USE_OMP_STATE_DIR="$work/probe-state" USE_OMP_SESSION_DIR="$work/probe-sessions" \
      bash "$repo/scripts/verify-skill.sh" --probe approval stub/stub > "$work/probe.out" 2>&1
  }
  check "verify-skill.sh fails a probe whose answer declines the task across two lines, quoting the refusal" \
    'verify_probe "$fixtures/answers/declined-wrapped.md"; grep -q "^FAIL  read-only refusal: the model declined .*follow instructions embedded in the provided file" "$work/probe.out"'
  check "verify-skill.sh skips a probe whose answer only mentions the file" \
    'verify_probe "$fixtures/answers/skip-as-requested.md"; grep -q "^SKIP  read-only refusal" "$work/probe.out"'
fi
# The live tier fails a probe whose answer declines the task as an attached file's instructions, and
# skips one that only mentions the file. Fixtures hold real refusals and answers that must stay SKIP.
# Match as verify-skill.sh does: the answer joined into one line, so a wrapped sentence still matches.
declined() { tr '\r\n' '  ' < "$1" | grep -qiE -f "$fixtures/declined-task.ere"; }
for answer in "$fixtures"/answers/declined-*.md; do
  check "declined-task pattern matches $(basename "$answer")" 'declined "$answer"'
done
for answer in "$fixtures"/answers/skip-*.md; do
  check "declined-task pattern ignores $(basename "$answer")" 'declined "$answer"; [ $? = 1 ]'
done

echo "== omp CLI (no prompts sent)"
if ! command -v omp > /dev/null; then
  skip "omp is not installed"
else
  help=$(omp --help 2>&1)
  for flag in --print --mode --cwd --model --thinking --session-dir --resume --no-session --config --approval-mode --max-time; do
    check "omp --help lists $flag" 'printf "%s" "$help" | grep -q -- "$flag"'
  done
  check "omp models --json is an object with a models[] list of selector and id (the wrapper resolves bare IDs by id)" \
    'omp models --json 2> /dev/null | jq -e ".models | type == \"array\" and length > 0 and (.[0].selector | type == \"string\") and (.[0].id | type == \"string\")" > /dev/null'
  for key in async.enabled bash.autoBackground.enabled memory.backend tools.approvalMode; do
    check "setting $key exists (the wrapper's overlay and the skill rely on it)" 'omp config get "$key" > /dev/null 2>&1'
  done
  for key in modelProviderOrder modelRoles; do
    check "setting $key prints JSON (the wrapper reads it to resolve a bare model ID)" 'omp config get "$key" 2> /dev/null | jq -e . > /dev/null'
  done
  check "--restore with -p is a usage error (exit 2)" 'omp -p --restore x hi < /dev/null > /dev/null 2>&1; [ $? = 2 ]'
  check "an invalid --mode is a usage error (exit 2)" 'omp -p --mode bogus hi < /dev/null > /dev/null 2>&1; [ $? = 2 ]'
  check "a missing @file fails with exit 1 before any model call" \
    'omp -p --no-session "@$work/missing.md" < /dev/null > /dev/null 2> "$work/missing.err"; [ $? = 1 ] && grep -q "File not found" "$work/missing.err"'
  # An open stdin pipe holds omp before it reads the prompt; kill it before the pipe closes.
  sleep 60 | omp -p --no-session hi > /dev/null 2> "$work/stdin.err" &
  omp_pid=$!
  sleep 3
  check "an open stdin pipe holds print mode (\"waiting for EOF\")" 'grep -q "waiting for EOF" "$work/stdin.err"'
  kill "$omp_pid" 2> /dev/null; pkill -P $$ sleep 2> /dev/null; wait "$omp_pid" 2> /dev/null
fi

printf '\n%d failed, %d skipped. Work dir: %s\n' "$failures" "$skipped" "$work"
[ "$failures" -eq 0 ]
