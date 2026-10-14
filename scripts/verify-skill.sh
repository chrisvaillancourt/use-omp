#!/usr/bin/env bash
# Re-check the omp behaviors that skills/use-omp documents against the installed omp.
# Usage: scripts/verify-skill.sh <provider/model>      (a cheap tool-capable model is enough)
# Runs scripts/test-offline.sh first (free), then six short model calls at --thinking low through the
# skill's run-omp.sh, recording into a throwaway directory (not the user's ledger or `omp stats`).
# Run after every omp upgrade. For skill edits alone, scripts/test-offline.sh is usually enough.
set -uo pipefail

model=${1:?usage: scripts/verify-skill.sh <provider/model>}
repo=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
skill="$repo/skills/use-omp"
verified_version=$(sed -n 's/.*last verified against omp \*\*\([0-9.]*\)\*\*.*/\1/p' "$skill/SKILL.md")
work=$(CDPATH= cd -- "$(mktemp -d "${TMPDIR:-/tmp}/use-omp-verify.XXXXXX")" && pwd)
export USE_OMP_STATE_DIR="$work/state" USE_OMP_SESSION_DIR="$work/sessions"
failures=0
inconclusive=0

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; failures=$((failures + 1)); }
skip() { printf 'SKIP  %s\n' "$1"; inconclusive=$((inconclusive + 1)); }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

echo "== free tier (scripts/test-offline.sh)"
if bash "$repo/scripts/test-offline.sh" > "$work/offline.txt" 2>&1; then
  pass "offline tests ($(grep -c '^PASS' "$work/offline.txt") checks)"
else
  fail "offline tests: $(grep -c '^FAIL' "$work/offline.txt") failed (see $work/offline.txt)"
  grep '^FAIL' "$work/offline.txt"
fi
echo "== live tier"

# Probes run with memory off: with a memory backend enabled, omp reads and writes the workspace's memory
# bank, so earlier runs could answer a probe (a resume check could pass from memory) and test runs would
# add entries to the user's real bank.
printf 'memory:\n  backend: off\n' > "$work/no-memory.yml"

# run <name> <prompt text> [run-omp.sh options...]: one recorded run through the wrapper.
run() {
  local name=$1 prompt=$2; shift 2
  printf '%s\n' "$prompt" > "$work/$name.task.md"
  bash "$skill/scripts/run-omp.sh" --workspace "$repo" --model "$model" --thinking low --label "verify $name" \
    --prompt-file "$work/$name.task.md" --config "$work/no-memory.yml" "$@" > "$work/$name.summary.json" 2> "$work/$name.stderr.txt"
  echo $? > "$work/$name.exit"
  jq -e . "$work/$name.summary.json" > /dev/null 2>&1 || echo '{}' > "$work/$name.summary.json"
}
field() { jq -r "$2" "$work/$1.summary.json"; }
# exit 1 exactly when the final stop reason is error/aborted (SKILL.md section 4; no launch failures expected here).
check_exit_predicate() {
  local run_name=$1  # check() evals its test in its own scope, where $1 is the description
  check "$run_name: exit code matches the final stop reason" \
    '[ "$(cat "$work/$run_name.exit")" = "$(field "$run_name" "if .final_stop_reason == \"error\" or .final_stop_reason == \"aborted\" then 1 else 0 end")" ]'
}

echo "omp: $(command -v omp) $(omp --version)"
echo "work dir: $work"

installed=$(omp --version | sed 's/^omp\/v\{0,1\}//')
check "installed omp ($installed) matches the version SKILL.md was verified against ($verified_version)" \
  '[ "$installed" = "$verified_version" ]'
# Strip a trailing :<thinking level> the way omp does; other colons belong to the model ID.
case ${model##*:} in
  off|minimal|low|medium|high|xhigh|max|auto) selector=${model%:*} ;;
  *) selector=$model ;;
esac
check "omp models --json is an object with a models[].selector list containing $selector" \
  'omp models --json | jq -e --arg m "$selector" "[.models[].selector] | index(\$m) != null" > /dev/null'

# 1. Normal-capability run: reads a file through default tools and answers.
canary="use-omp-canary-$RANDOM$RANDOM"
printf '%s\n' "$canary" > "$work/canary.txt"
run normal "Read the file $work/canary.txt with your read tool and reply with exactly its first line, nothing else." --max-time 3m
check "normal run exits 0" '[ "$(cat "$work/normal.exit")" = 0 ]'
check "normal run has a session header id" '[ "$(field normal .session_id)" != null ]'
check "normal run used a tool" '[ "$(field normal ".tool_calls | length")" -gt 0 ]'
check "normal run looks_complete" '[ "$(field normal .looks_complete)" = true ]'
check "normal run answered with the canary" 'grep -qF "$canary" "$(field normal .run_dir)/answer.md"'
check "normal run reports token usage" '[ "$(field normal .tokens)" -gt 0 ]'
check "normal run has no write targets" '[ "$(field normal ".write_targets | length")" = 0 ]'
check_exit_predicate normal
check "normal run kept its transcript in USE_OMP_SESSION_DIR" \
  '[ -f "$(field normal .session_file)" ] && grep -qF "$canary" "$(field normal .session_file)"'

# 2. Resume the recorded session: the transcript carries the conversation.
run resume "Repeat the exact line you replied with in your previous answer, nothing else." \
  --max-time 3m --resume "$(field normal .session_id)"
check "resumed run continues the same session" '[ "$(field resume .session_id)" = "$(field normal .session_id)" ]'
check "resumed run recalls the canary" 'grep -qF "$canary" "$(field resume .run_dir)/answer.md"'

# 3. A deadline ends the run without a complete answer. Depending on startup time it lands before the
#    first answer (exit 0, no assistant message) or mid-turn (exit 1, aborted); both are documented.
run deadline "Count slowly from one to fifty, one number per line." --max-time 1s
check "1s deadline is not looks_complete" '[ "$(field deadline .looks_complete)" = false ]'
check_exit_predicate deadline
if [ "$(cat "$work/deadline.exit")" = 0 ]; then
  check "1s deadline exited 0 with no final answer (exit is not completion)" '[ "$(field deadline .final_text_chars)" = 0 ]'
else
  pass "1s deadline interrupted a model turn (exit 1, $(field deadline .final_stop_reason))"
fi

# 4. --read-only (always-ask) refuses exec-tier tools without a UI; the process still exits 0.
run approval "Call your bash tool exactly once with the command printf APPROVAL_PROBE, even if you expect the call to be refused. Then quote the tool's response." --max-time 3m --read-only
check "read-only run exits 0" '[ "$(cat "$work/approval.exit")" = 0 ]'
if [ "$(field approval '.tool_calls.bash // 0')" = 0 ]; then
  skip "read-only refusal: the model never called bash, so the probe is inconclusive"
elif [ "$(field approval '[.tool_errors[] | select(.error | test("requires approval"))] | length')" -gt 0 ]; then
  pass "read-only run records a refused bash call"
  check "ledger counts the expected approval refusal" \
    '[ "$(jq -s "map(select(.label == \"verify approval\")) | .[0].approval_refusals" "$work/state/runs.jsonl")" -ge 1 ]'
else
  fail "always-ask let bash run: check tools.approval and bash.patterns allow rules ($(omp config get tools.approval 2>&1 | tr -d '\n'), $(omp config get bash.patterns 2>&1 | tr -d '\n'))"
fi

# 5. Subagents return inline: the wrapper turns async off for the run, so a subagent finishes before exit
#    even when the parent does not wait (with async on, print mode cancels it; see docs/decisions.md).
run subagent "Call your task tool exactly once to start one subagent with this assignment: run the shell command \`sleep 10; echo SUBAGENT-FINISHED\` with bash, then reply with the single word SUBAGENT-DONE. Do not call any wait tool. As soon as the task tool returns, reply PARENT-DONE." --max-time 4m
if [ "$(field subagent .subagent_tasks)" = 0 ]; then
  skip "subagent probe: the model never called the task tool, so the probe is inconclusive"
else
  check "subagent ran inline, not as a background job" '[ "$(field subagent .background_jobs)" = 0 ]'
  check "subagent finished and returned its result" \
    '[ "$(field subagent .subagent_failures)" = 0 ] && jq -r "select(.type == \"tool_execution_end\" and .toolName == \"task\") | .result | tostring" "$(field subagent .run_dir)/events.jsonl" | grep -q SUBAGENT-DONE'
  check "summary reports the subagent's cost" '[ "$(field subagent "(.subagent_cost_usd > 0)")" = true ]'
fi


# 6. Long bash commands block: the overlay's bash.autoBackground.enabled false keeps a command past the
#    60-second auto-background threshold inline (otherwise it becomes a job that print mode cancels).
run bash "Run exactly this shell command with your bash tool: sleep 65; echo BASH-FINISHED. Then reply with its output only." --max-time 4m
if [ "$(field bash '.tool_calls.bash // 0')" = 0 ]; then
  skip "long bash probe: the model never called bash, so the probe is inconclusive"
else
  check "a 65-second bash command ran inline, not as a background job" \
    '[ "$(field bash .background_jobs)" = 0 ] && grep -q BASH-FINISHED "$(field bash .run_dir)/answer.md" \
     && jq -e "select(.type == \"tool_execution_start\" and .toolName == \"bash\") | .args.command | test(\"sleep 65\")" "$(field bash .run_dir)/events.jsonl" > /dev/null \
     && [ "$(jq -s "map(select(.label == \"verify bash\")) | .[0].duration_s" "$work/state/runs.jsonl")" -ge 65 ]' \
    || echo "      (a timeout under 65 s kills the command; tools.maxTimeout is $(omp config get tools.maxTimeout 2>&1 | tr -d '\n'))"
fi

# 7. Records: one ledger line per run, readable by report.sh.
check "ledger has one line per run (6)" '[ "$(wc -l < "$work/state/runs.jsonl" | tr -d " ")" = 6 ]'
check "ledger lines link run directories that exist" \
  '[ "$(jq -r .run_dir "$work/state/runs.jsonl" | while read -r d; do [ -d "$d" ] && echo ok; done | wc -l | tr -d " ")" = 6 ]'
check "report.sh counts the runs" '[ "$(bash "$skill/scripts/report.sh" --json | jq .overall.runs)" = 6 ]'

for name in normal resume deadline approval subagent bash; do
  printf '\n%s: exit=%s %s\n' "$name" "$(cat "$work/$name.exit")" \
    "$(jq -c '{models, final_stop_reason, tool_calls, tool_errors: (.tool_errors | length), primary_cost_usd, looks_complete}' "$work/$name.summary.json")"
done
printf '\n%d check(s) failed, %d inconclusive. Artifacts: %s\n' "$failures" "$inconclusive" "$work"
[ "$failures" -eq 0 ]
