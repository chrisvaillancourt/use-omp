# Summarize an omp `--mode json` event file (verified against omp 18.10.3).
# Usage: jq -s -f summarize-events.jq events.jsonl
# A truncated final line makes jq fail; a stream cut at a line boundary shows agent_end_seen: false.
# primary_cost_usd covers the primary agent. subagent_cost_usd adds direct subagents that returned inline
# (async off); nested and background subagents and the advisor report their spend elsewhere.
def text_of: [.content[]? | select(.type == "text") | .text // ""] | add // "";
def assistant: select(.type == "message_end" and .message.role? == "assistant") | .message;
# Best-effort targets of a write/edit/ast_edit call: `path`, `paths` (may be globs or directories),
# or the file headers inside a patch-style `input` (hashline `[path#TAG]`, apply_patch `*** ... File: path`).
def write_targets:
  if .args.path? then .args.path
  elif .args.paths? then .args.paths[]
  elif (.args.input? | type) == "string" then
    ([.args.input | scan("(?m)^\\[([^#\\]\\n]+)#"), scan("(?m)^\\*\\*\\* (?:Add|Update|Delete) File: ([^\\n]+)") | .[0]]
      | if length > 0 then .[] else "?" end)
  else "?" end;
[.[] | objects | select((.type | type) == "string")] as $events
| [$events[] | select(.type == "tool_execution_end" and .isError == true) | .toolCallId] as $failed
| [$events[] | assistant] as $msgs
| ($msgs | last) as $final
| ($final // {} | text_of) as $final_text
| any($events[]; .type == "agent_end") as $agent_end_seen
| {
    is_event_stream: any($events[]; .type == "agent_start"),
    session_id: ([$events[] | select(.type == "session") | .id] | first),
    models: ($msgs | map("\(.provider)/\(.model)") | unique),
    assistant_messages: ($msgs | length),
    agent_end_seen: $agent_end_seen,
    final_stop_reason: $final.stopReason,
    final_error: $final.errorMessage,
    final_text_chars: ($final_text | length),
    tool_calls: ([$events[] | select(.type == "tool_execution_start") | .toolName]
      | group_by(.) | map({key: .[0], value: length}) | from_entries),
    tool_errors: [$events[] | select(.type == "tool_execution_end" and .isError == true)
      | {tool: .toolName, error: ((.result | if type == "object" then text_of else tostring end) | .[0:200])}],
    write_targets: ([$events[] | select(.type == "tool_execution_start")
      | select(.toolName == "write" or .toolName == "edit" or .toolName == "ast_edit")
      | select(.toolCallId as $id | $failed | index($id) | not)
      | write_targets] | unique),
    subagent_tasks: ([$events[] | select(.type == "tool_execution_start" and .toolName == "task")] | length),
    # Tool calls that started background jobs: task subagents (async.enabled) and bash commands moved to
    # the background (bash.autoBackground). Print mode cancels jobs still running when the primary turn
    # ends, so a nonzero count means checking that their results arrived.
    background_jobs: ([$events[] | select(.type == "tool_execution_end")
      | .result.details.async? | objects | select(.state == "running")] | length),
    background_job_types: ([$events[] | select(.type == "tool_execution_end")
      | .result.details.async? | objects | select(.state == "running") | .type // "?"]
      | group_by(.) | map({key: .[0], value: length}) | from_entries),
    subagent_cost_usd: ([$events[] | select(.type == "tool_execution_end" and .toolName == "task")
      | .result.details.results[]? | .usage.cost.total // 0] | add // 0),
    subagent_failures: ([$events[] | select(.type == "tool_execution_end" and .toolName == "task")
      | .result.details.results[]? | select(.aborted == true or ((.exitCode // 0) != 0))] | length),
    retries_or_fallbacks: [$events[] | select(.type | test("^(auto_retry|retry_fallback|auto_compaction)")) | .type],
    tokens: ($msgs | map(.usage.totalTokens // 0) | add // 0),
    primary_cost_usd: ($msgs | map(.usage.cost.total // 0) | add // 0),
    looks_complete: ($agent_end_seen
      and $final != null
      and $final.stopReason == "stop"
      and ($final.stopDetails.type? != "pause_turn")
      and ([$final.content[]? | select(.type == "toolCall")] | length) == 0
      and ($final_text | length) > 0)
  }
