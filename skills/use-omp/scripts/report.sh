#!/usr/bin/env bash
# Summarize recorded omp delegations from the run-omp.sh ledger.
# Usage: report.sh [--since YYYY-MM-DD (UTC)] [--json]
# Reads ${USE_OMP_STATE_DIR:-${XDG_STATE_HOME:-~/.local/state}/use-omp}/runs.jsonl.
# Costs: primary agent plus subagents that returned inline. For totals that include background subagents
# and the advisor, plus tokens and latency, see the delegations folder in `omp stats`.
set -uo pipefail

since= json=no
while [ $# -gt 0 ]; do
  case $1 in
    --since)
      [[ ${2:-} =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2} ]] || { echo "report.sh: --since needs a UTC date, YYYY-MM-DD" >&2; exit 2; }
      since=$2; shift 2 ;;
    --json) json=yes; shift ;;
    -h|--help) sed -n '2,5p' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "report.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
ledger=${USE_OMP_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/use-omp}/runs.jsonl
[ -s "$ledger" ] || { echo "report.sh: no ledger at $ledger" >&2; exit 1; }

# Malformed lines are skipped and counted rather than aborting the report.
report=$(jq -R -s --arg since "$since" '
  def num(f): (f | numbers) // 0;
  def pct(n; d): if d == 0 then null else (n * 1000 / d | round / 10) end;
  def median: sort | length as $n | if $n == 0 then null elif $n % 2 == 1 then .[($n - 1) / 2]
    else (.[$n / 2 - 1] + .[$n / 2]) / 2 end;
  # Refusals in --read-only runs are the expected effect of always-ask, not problems.
  def unexpected_tool_errors: num(.tool_errors) - (if .read_only == true then num(.approval_refusals) else 0 end);
  def week: (.started // "")[0:10] | (try (strptime("%Y-%m-%d") | strftime("%G-W%V")) catch "unknown");
  def stats: {
    runs: length,
    complete: map(select(.looks_complete == true)) | length,
    complete_pct: pct(map(select(.looks_complete == true)) | length; length),
    nonzero_exit: map(select(.exit != 0)) | length,
    with_tool_errors: map(select(unexpected_tool_errors > 0)) | length,
    median_duration_s: (map(.duration_s | numbers) | median),
    max_duration_s: (map(.duration_s | numbers) | max),
    primary_cost_usd: ((map(num(.primary_cost_usd)) | add // 0) * 100 | round / 100),
    subagent_cost_usd: ((map(num(.subagent_cost_usd)) | add // 0) * 100 | round / 100),
    background_job_runs: map(select(num(.background_jobs) > 0)) | length
  };
  (split("\n") | map(select(length > 0) | (try fromjson catch "bad"))) as $all
  | ($all | map(select(type == "object" and ((.started | strings) // "" | test("^[0-9]{4}-")) and .started >= $since))) as $runs
  | {
      ledger_lines_skipped: ($all | map(select(type != "object" or ((.started | strings) // "" | test("^[0-9]{4}-") | not))) | length),
      since: (if $since == "" then null else $since end),
      overall: ($runs | stats),
      by_model: ($runs | group_by(.model // "?") | map({key: (.[0].model // "?"), value: stats}) | from_entries),
      by_workspace: ($runs | group_by(.workspace // "?") | map({key: (.[0].workspace // "?"), value: stats}) | from_entries),
      by_week: ($runs | group_by(week) | map({key: (.[0] | week), value: stats}) | from_entries),
      recent_problems: ($runs | map(select(.looks_complete != true or .exit != 0 or unexpected_tool_errors > 0
          or num(.subagent_failures) > 0 or num(.background_jobs) > 0)) | sort_by(.started) | .[-10:]
        | map({started, label, model, exit, looks_complete, final_stop_reason, tool_errors, read_only,
            subagent_failures, background_jobs, run_dir}))
    }' "$ledger") || exit 1

if [ "$json" = yes ]; then
  printf '%s\n' "$report"
else
  printf '%s\n' "$report" | jq -r '
    def row(k; v): "  \(k): \(v.runs) runs, \(v.complete_pct // "-")% complete, \(v.nonzero_exit) nonzero exit, \(v.with_tool_errors) with unexpected tool errors, median \(v.median_duration_s // "-")s, $\(v.primary_cost_usd) primary + $\(v.subagent_cost_usd) inline-subagent cost" + (if v.background_job_runs > 0 then ", \(v.background_job_runs) with background jobs" else "" end);
    "omp delegations " + (if .since == null then "(all runs)" else "since \(.since)" end) + (if .ledger_lines_skipped > 0 then " (\(.ledger_lines_skipped) malformed ledger lines skipped)" else "" end),
    row("overall"; .overall),
    "By model:", (.by_model | to_entries[] | row(.key; .value)),
    "By workspace:", (.by_workspace | to_entries[] | row(.key; .value)),
    "By week:", (.by_week | to_entries[] | row(.key; .value)),
    "Recent problems:", (if (.recent_problems | length) == 0 then "  none" else (.recent_problems[] | "  \(.started) \(.label // "") \(.model) exit=\(.exit) complete=\(.looks_complete) stop=\(.final_stop_reason) tool_errors=\(.tool_errors)\(if .read_only then " read-only" else "" end)\(if (.subagent_failures // 0) > 0 then " subagent_failures=\(.subagent_failures)" else "" end)\(if (.background_jobs // 0) > 0 then " background_jobs=\(.background_jobs)" else "" end) \(.run_dir)") end)'
fi
