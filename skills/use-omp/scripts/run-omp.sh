#!/usr/bin/env bash
# Run one headless omp task, keep a durable record of it, and print a run summary.
#
# Usage: run-omp.sh --workspace DIR --model PROVIDER/MODEL --prompt-file FILE [options]
#   --thinking LEVEL   off|minimal|low|medium|high|xhigh|max|auto (default: omp's own resolution)
#   --max-time DUR     omp deadline, e.g. 600, 10m, 1h (default 30m)
#   --label TEXT       short purpose, recorded in the ledger and the run directory name
#   --read-only        opt-in: add --approval-mode always-ask, which refuses bash, eval, edits, MCP tools
#                      and subagents, so the child cannot run tests or reproduce issues
#   --allow-async      keep omp's background-job settings; by default a config overlay sets async.enabled
#                      and bash.autoBackground.enabled to false for the run, so subagents and long bash
#                      commands block until they finish instead of running as background jobs that
#                      print mode cancels when it exits
#   --config FILE      add an omp config overlay for this run (repeatable), e.g. `memory:\n  backend: off`
#                      so the run neither reads nor adds to the workspace's memory bank
#   --resume ID        continue an earlier recorded run's omp session
#   --no-record        disposable run: --no-session, temporary run directory, no ledger line
#
# Records (override with environment variables):
#   USE_OMP_SESSION_DIR  omp transcripts; default <omp sessions root>/--agent-delegations--, which
#                        `omp stats` reports as its own folder (subagent and advisor transcripts included).
#                        With OMP_PROFILE or an XDG layout, point it at a folder inside that profile's
#                        sessions root, e.g. <root>/--agent-delegations--.
#   USE_OMP_STATE_DIR    run directories and runs.jsonl ledger; default ${XDG_STATE_HOME:-~/.local/state}/use-omp
#
# omp starts in the workspace (so it loads that directory's .env, as an interactive launch would).
# Stop a running wrapper with TERM: it stops omp and still writes the record. INT may be ignored
# when the wrapper was started as a background job.
# Writes `run_dir=<path>` to stderr at start, then prints the summary JSON (plus run_dir and
# session_file) to stdout. Exits with omp's exit code (2 for usage errors). Exit 0 is not completion:
# check `looks_complete` and `tool_errors` in the summary.
set -uo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die() { echo "run-omp.sh: $*" >&2; exit 2; }
need() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }

workspace= model= prompt_file= thinking= max_time=30m label= read_only=no resume= record=yes allow_async=no
extra_configs=()
while [ $# -gt 0 ]; do
  case $1 in
    --workspace) need "$@"; workspace=$2; shift 2 ;;
    --model) need "$@"; model=$2; shift 2 ;;
    --prompt-file) need "$@"; prompt_file=$2; shift 2 ;;
    --thinking) need "$@"; thinking=$2; shift 2 ;;
    --max-time) need "$@"; max_time=$2; shift 2 ;;
    --label) need "$@"; label=$2; shift 2 ;;
    --resume) need "$@"; resume=$2; shift 2 ;;
    --config) need "$@"; [ -f "$2" ] || die "config overlay not found: $2"; extra_configs+=("$(CDPATH= cd -- "$(dirname "$2")" && pwd)/$(basename "$2")"); shift 2 ;;
    --read-only) read_only=yes; shift ;;
    --allow-async) allow_async=yes; shift ;;
    --no-record) record=no; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -n "$workspace" ] && [ -n "$model" ] && [ -n "$prompt_file" ] || { usage >&2; exit 2; }
[ -d "$workspace" ] || die "workspace is not a directory: $workspace"
[ -s "$prompt_file" ] || die "prompt file is missing or empty: $prompt_file"
[ "$record" = yes ] || [ -z "$resume" ] || die "--resume needs a recorded session; drop --no-record"
command -v omp > /dev/null || die "omp is not on PATH"
command -v jq > /dev/null || die "jq is not on PATH"

skill_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
workspace=$(CDPATH= cd -- "$workspace" && pwd)
state_dir=${USE_OMP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/use-omp}
session_dir=${USE_OMP_SESSION_DIR:-${PI_CODING_AGENT_DIR:-$HOME/.omp/agent}/sessions/--agent-delegations--}
slug=$(printf '%s' "${label:-run}" | tr -cs 'A-Za-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-40)

# Records are private; omp itself keeps the caller's umask so files it creates in the workspace are normal.
caller_umask=$(umask)
umask 077
if [ "$record" = yes ]; then
  mkdir -p "$state_dir/runs" "$session_dir" || die "cannot create $state_dir or $session_dir"
  run_dir=$(mktemp -d "$state_dir/runs/$(date -u +%Y%m%dT%H%M%SZ)-${slug:-run}.XXXX") || die "cannot create a run directory"
else
  run_dir=$(mktemp -d "${TMPDIR:-/tmp}/omp-run.XXXXXX") || die "cannot create a run directory"
fi
echo "run_dir=$run_dir" >&2
cp "$prompt_file" "$run_dir/prompt.md"
: > "$run_dir/events.jsonl"; : > "$run_dir/stderr.txt"

args=(-p --cwd "$workspace" --model "$model" --mode json --max-time "$max_time")
[ -n "$thinking" ] && args+=(--thinking "$thinking")
[ "$read_only" = yes ] && args+=(--approval-mode always-ask)
if [ "$allow_async" = no ]; then
  printf 'async:\n  enabled: false\nbash:\n  autoBackground:\n    enabled: false\n' > "$run_dir/omp-overlay.yml"
  args+=(--config "$run_dir/omp-overlay.yml")
fi
for overlay in ${extra_configs[@]+"${extra_configs[@]}"}; do args+=(--config "$overlay"); done
if [ "$record" = yes ]; then
  args+=(--session-dir "$session_dir")
  [ -n "$resume" ] && args+=(--resume "$resume")
else
  args+=(--no-session)
fi

started=$(date -u +%Y-%m-%dT%H:%M:%SZ); start_s=$(date +%s)
umask "$caller_umask"
(cd "$workspace" && exec omp "${args[@]}" "@$run_dir/prompt.md") \
  < /dev/null >> "$run_dir/events.jsonl" 2>> "$run_dir/stderr.txt" &
omp_pid=$!
# If the host stops this script, stop omp and still write the record.
trap 'kill -TERM "$omp_pid" 2> /dev/null' TERM INT HUP
wait "$omp_pid"; rc=$?
while kill -0 "$omp_pid" 2> /dev/null; do wait "$omp_pid"; rc=$?; done
trap - TERM INT HUP
umask 077
end_s=$(date +%s)
echo "$rc" > "$run_dir/exit.txt"

jq -s -f "$skill_dir/scripts/summarize-events.jq" "$run_dir/events.jsonl" > "$run_dir/summary.json" 2> "$run_dir/summary-error.txt" \
  || jq -n --rawfile e "$run_dir/summary-error.txt" '{parse_error: $e, looks_complete: false}' > "$run_dir/summary.json"
[ -s "$run_dir/summary-error.txt" ] || rm -f "$run_dir/summary-error.txt"
jq -rs '[.[] | objects | select(.type == "message_end" and .message.role? == "assistant") | .message] | last
  | [.content[]? | select(.type == "text") | .text] | join("\n")' "$run_dir/events.jsonl" > "$run_dir/answer.md" 2> /dev/null || : > "$run_dir/answer.md"

session_file=
if [ "$record" = yes ]; then
  session_id=$(jq -r '.session_id // empty' "$run_dir/summary.json")
  [ -n "$session_id" ] && session_file=$(ls "$session_dir"/*_"$session_id".jsonl 2> /dev/null | head -1)
  jq -c -n \
    --slurpfile s "$run_dir/summary.json" \
    --arg started "$started" --argjson duration "$((end_s - start_s))" --argjson exit "$rc" \
    --arg label "$label" --arg workspace "$workspace" --arg model "$model" --arg thinking "$thinking" \
    --arg read_only "$read_only" --arg allow_async "$allow_async" --argjson extra_configs "$(printf '%s\n' ${extra_configs[@]+"${extra_configs[@]}"} | jq -R . | jq -s 'map(select(. != ""))')" --arg resumed "$resume" --arg max_time "$max_time" \
    --arg omp_version "$(omp --version 2> /dev/null)" --arg run_dir "$run_dir" --arg session_file "$session_file" \
    --arg caller_session "${CLAUDE_CODE_SESSION_ID:-}" --arg caller_cwd "$PWD" \
    '$s[0] as $s | {
      started: $started, duration_s: $duration, label: $label, workspace: $workspace,
      model: $model, thinking: ($thinking | select(. != "") // null), read_only: ($read_only == "yes"), async: ($allow_async == "yes"), extra_configs: $extra_configs,
      resumed_session: ($resumed | select(. != "") // null), max_time: $max_time, omp_version: $omp_version,
      exit: $exit, looks_complete: $s.looks_complete, final_stop_reason: $s.final_stop_reason,
      final_error: ($s.final_error // null | if . == null then null else .[0:300] end),
      session_id: $s.session_id, models: $s.models, assistant_messages: $s.assistant_messages,
      tool_calls: ($s.tool_calls // {} | add // 0), tool_errors: ($s.tool_errors // [] | length),
      approval_refusals: ($s.tool_errors // [] | map(select(.error | test("requires approval"))) | length),
      write_targets: ($s.write_targets // [] | length), subagent_tasks: $s.subagent_tasks, background_jobs: $s.background_jobs,
      subagent_failures: $s.subagent_failures, subagent_cost_usd: $s.subagent_cost_usd,
      retries: ($s.retries_or_fallbacks // [] | length), tokens: $s.tokens, primary_cost_usd: $s.primary_cost_usd,
      caller: {claude_session_id: ($caller_session | select(. != "") // null), cwd: $caller_cwd},
      run_dir: $run_dir, session_file: ($session_file | select(. != "") // null)
    }' > "$run_dir/ledger-line.json" \
    && cat "$run_dir/ledger-line.json" >> "$state_dir/runs.jsonl"
fi

jq --arg run_dir "$run_dir" --arg session_file "$session_file" \
  '. + {run_dir: $run_dir, session_file: ($session_file | select(. != "") // null)}' "$run_dir/summary.json"
exit "$rc"
