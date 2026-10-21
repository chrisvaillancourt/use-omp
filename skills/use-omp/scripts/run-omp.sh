#!/usr/bin/env bash
# Run one headless omp task, keep a durable record of it, and print a run summary.
#
# Usage: run-omp.sh --workspace DIR --prompt-file FILE [--model MODEL] [options]
#   --model MODEL      provider/model[:level], a bare model ID[:level], or an omp role (slow, @slow).
#                      Default: $USE_OMP_MODEL, else omp's own `default` role. A bare ID that several
#                      providers offer resolves by omp's modelProviderOrder setting, read in the workspace with
#                      any --config overlays; with no order set, or an ID omp does not list, the wrapper exits 2
#                      and names the candidates.
#   --thinking LEVEL   off|minimal|low|medium|high|xhigh|max|auto (default: omp's own resolution)
#   --max-time DUR     omp deadline, e.g. 600, 10m, 1h (default 30m)
#   --label TEXT       short purpose, recorded in the ledger and the run directory name
#   --read-only        opt-in: add --approval-mode always-ask, which refuses bash, eval, edits, MCP tools
#                      and subagents, so the child cannot run tests or reproduce issues
#   --allow-async      keep omp's background-job settings; by default a config overlay sets async.enabled
#                      and bash.autoBackground.enabled to false for the run, so subagents and long bash
#                      commands block until they finish instead of running as background jobs that
#                      print mode cancels when it exits
#   --memory           keep omp's memory setting; by default the overlay sets memory.backend to off, so the
#                      run neither reads nor adds to a memory bank and its answer is independent of earlier runs
#   --config FILE      add an omp config overlay for this run (repeatable); later overlays win, so these
#                      override the wrapper's own
#   --resume ID        continue an earlier recorded run's omp session
#   --no-record        disposable run: --no-session, temporary run directory, no ledger line
#
# Records (override with environment variables):
#   USE_OMP_SESSION_DIR  omp transcripts; default <omp sessions root>/--agent-delegations--, which
#                        `omp stats` reports as its own folder (subagent and advisor transcripts included).
#                        With OMP_PROFILE or an XDG layout, point it at a folder inside that profile's
#                        sessions root, e.g. <root>/--agent-delegations--.
#   USE_OMP_STATE_DIR    run directories and runs.jsonl ledger; default ${XDG_STATE_HOME:-~/.local/state}/use-omp
#   USE_OMP_MODEL        default --model, in any form --model accepts
#
# omp starts in the workspace (so it loads that directory's .env, as an interactive launch would).
# Stop a running wrapper with TERM: it stops omp and still writes the record. INT may be ignored
# when the wrapper was started as a background job.
# Writes `model=<selector>` to stderr when it resolved a bare ID, and `run_dir=<path>` at start, then prints
# the summary JSON (plus run_dir and session_file) to stdout. Progress-only events (message_update,
# tool_execution_update, tool_stream_update) are dropped from the saved events file after omp exits.
# Exits with omp's exit code (2 for usage errors). Exit 0 is not completion: check `looks_complete` and
# `tool_errors` in the summary.
set -uo pipefail

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }
die() { echo "run-omp.sh: $*" >&2; exit 2; }
need() { [ $# -ge 2 ] && [ -n "$2" ] || die "$1 needs a value"; }

workspace= model= prompt_file= thinking= max_time=30m label= read_only=no resume= record=yes allow_async=no memory=no
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
    --memory) memory=yes; shift ;;
    --no-record) record=no; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[ -n "$workspace" ] && [ -n "$prompt_file" ] || { usage >&2; exit 2; }
[ -d "$workspace" ] || die "workspace is not a directory: $workspace"
[ -s "$prompt_file" ] || die "prompt file is missing or empty: $prompt_file"
[ "$record" = yes ] || [ -z "$resume" ] || die "--resume needs a recorded session; drop --no-record"
command -v omp > /dev/null || die "omp is not on PATH"
command -v jq > /dev/null || die "jq is not on PATH"


skill_dir=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
workspace=$(CDPATH= cd -- "$workspace" && pwd)

# The model: --model, else USE_OMP_MODEL, else none (omp's `default` role decides).
model_requested=$model model_source=flag
if [ -z "$model_requested" ]; then model_requested=${USE_OMP_MODEL:-} model_source=env; fi
[ -n "$model_requested" ] || model_source=omp-default
# Lookups see the settings the run will: the workspace's project config and the caller's overlays.
lookup_configs=${PI_CONFIG_FILES:-}
for overlay in ${extra_configs[@]+"${extra_configs[@]}"}; do lookup_configs=${lookup_configs:+$lookup_configs:}$overlay; done
omp_lookup() { (cd "$workspace" && PI_CONFIG_FILES=$lookup_configs exec omp "$@" 2> /dev/null); }
# resolve_model SPEC: print the selector to pass. omp itself would resolve a bare ID by recent use first
# and only then by modelProviderOrder, so a provider the user tried once can win; resolve it here instead.
# As in omp, an exact model ID (matched case-insensitively) wins over a role of the same name.
resolve_model() {
  local spec=$1 base=$1 level= catalog candidates count order pick
  case $spec in */*|@*|'*'|'*:'*) printf '%s' "$spec"; return ;; esac
  case ${spec##*:} in
    off|minimal|low|medium|high|xhigh|max|auto) [ "$spec" != "${spec%:*}" ] && base=${spec%:*} level=${spec##*:} ;;
  esac
  catalog=$(omp_lookup models --json)
  candidates=$(printf '%s' "$catalog" | jq -r --arg id "$base" '.models[]? | select((.id // "" | ascii_downcase) == ($id | ascii_downcase)) | .selector')
  count=$(printf '%s' "$candidates" | grep -c .)
  if [ "$count" = 0 ]; then
    # A configured role name (for example `slow`) is omp's to resolve, with the role's own level.
    if omp_lookup config get modelRoles | jq -e --arg r "$base" 'type == "object" and has($r)' > /dev/null 2>&1; then
      printf '%s' "$spec"; return
    fi
    # Similar: selectors whose ID has every word of the requested one (gpt-9-x suggests gpt-8-x).
    die "no model with ID '$base' in \`omp models\`; pass provider/model. Similar: $(printf '%s' "$catalog" \
      | jq -r --arg id "$base" '($id | ascii_downcase | [scan("[a-z]+")]) as $words
        | [.models[]? | select((.id // "" | ascii_downcase) as $m | $words != [] and all($words[]; . as $w | $m | contains($w))) | .selector][:8]
        | if . == [] then "none (see omp models)" else join(", ") end')"
  elif [ "$count" = 1 ]; then
    pick=$candidates
  else
    order=$(omp_lookup config get modelProviderOrder)
    printf '%s' "$order" | jq -e 'type == "array"' > /dev/null 2>&1 || order='[]'
    pick=$(jq -rn --argjson order "$order" --arg c "$candidates" \
      'first($order[] | strings | ascii_downcase as $p | $c | split("\n")[] | select(ascii_downcase | startswith($p + "/"))) // empty')
    [ -n "$pick" ] || die "several providers offer '$base' ($(printf '%s' "$candidates" | tr '\n' ' ' | sed 's/ $//')) and omp's \
modelProviderOrder names none of them; pass provider/model, or set it (omp config set modelProviderOrder '[\"provider\", ...]')"
  fi
  printf '%s%s' "$pick" "${level:+:$level}"
  echo "model=$pick${level:+:$level} (resolved from $spec)" >&2
}
model=
if [ -n "$model_requested" ]; then
  model=$(resolve_model "$model_requested") || exit 2
fi
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

args=(-p --cwd "$workspace" --mode json --max-time "$max_time")
[ -n "$model" ] && args+=(--model "$model")
[ -n "$thinking" ] && args+=(--thinking "$thinking")
[ "$read_only" = yes ] && args+=(--approval-mode always-ask)
# The wrapper's overlay goes first, so the caller's --config overlays (merged in order) override it.
overlay=
[ "$allow_async" = no ] && overlay='async:\n  enabled: false\nbash:\n  autoBackground:\n    enabled: false\n'
[ "$memory" = no ] && overlay="${overlay}memory:\n  backend: off\n"
if [ -n "$overlay" ]; then
  printf '%b' "$overlay" > "$run_dir/omp-overlay.yml"
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
# omp sends the file as a <file> block. Alone, it reads as file content, and a model can decline its
# instructions as untrusted; the typed line after it makes the file the user's request.
(cd "$workspace" && exec omp "${args[@]}" "@$run_dir/prompt.md" -- "The attached file is my task for you. Carry it out.") \
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

# Progress-only events repeat partial tool output and message deltas; they were most of a run's bytes and
# nothing reads them after exit. Every event line starts with its type. grep exits 1 when nothing is left.
LC_ALL=C grep -v -E '^\{"type":"(message_update|tool_execution_update|tool_stream_update)"' "$run_dir/events.jsonl" \
  > "$run_dir/events.tmp"
if [ $? -le 1 ]; then mv "$run_dir/events.tmp" "$run_dir/events.jsonl"; else rm -f "$run_dir/events.tmp"; fi

jq -s -f "$skill_dir/scripts/summarize-events.jq" "$run_dir/events.jsonl" > "$run_dir/summary.json" 2> "$run_dir/summary-error.txt" \
  || jq -n --rawfile e "$run_dir/summary-error.txt" '{parse_error: $e, looks_complete: false}' > "$run_dir/summary.json"
[ -s "$run_dir/summary-error.txt" ] || rm -f "$run_dir/summary-error.txt"
# A launch failure (a missing @file, a --resume omp refuses) exits before any event; its reason is in stderr.
if [ "$rc" != 0 ] && [ "$(jq -r '(.assistant_messages // 0) == 0 and .final_error == null' "$run_dir/summary.json")" = true ]; then
  # omp prints `Error: …` and may follow it with a hint; keep the error. Colors are stripped if present.
  clean_stderr=$(LC_ALL=C sed $'s/\033\\[[0-9;]*m//g' "$run_dir/stderr.txt" | grep -v '^[[:space:]]*$')
  launch_error=$(printf '%s\n' "$clean_stderr" | grep '^Error:' | tail -1)
  [ -n "$launch_error" ] || launch_error=$(printf '%s\n' "$clean_stderr" | tail -1)
  [ -n "$launch_error" ] && jq --arg e "$launch_error" '.final_error = $e' "$run_dir/summary.json" > "$run_dir/summary.tmp" \
    && mv "$run_dir/summary.tmp" "$run_dir/summary.json"
fi
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
    --arg model_requested "$model_requested" --arg model_source "$model_source" --arg memory "$memory" \
    --arg read_only "$read_only" --arg allow_async "$allow_async" --argjson extra_configs "$(printf '%s\n' ${extra_configs[@]+"${extra_configs[@]}"} | jq -R . | jq -s 'map(select(. != ""))')" --arg resumed "$resume" --arg max_time "$max_time" \
    --arg omp_version "$(omp --version 2> /dev/null)" --arg run_dir "$run_dir" --arg session_file "$session_file" \
    --arg caller_session "${CLAUDE_CODE_SESSION_ID:-}" --arg caller_cwd "$PWD" \
    '$s[0] as $s | {
      started: $started, duration_s: $duration, label: $label, workspace: $workspace,
      model: ($s.final_model // $s.models[0]? // ($model | select(. != "")) // null),
      model_requested: ($model_requested | select(. != "") // null), model_source: $model_source,
      thinking: ($thinking | select(. != "") // null), read_only: ($read_only == "yes"), async: ($allow_async == "yes"),
      memory_off: ($memory == "no"), extra_configs: $extra_configs,
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
