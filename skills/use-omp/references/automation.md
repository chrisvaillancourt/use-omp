# Automation and session continuity

## Choose the interface

- `omp -p`: one task, final text on stdout, process exits. Stdout shows nothing until the end, so a stall or deadline leaves only a saved transcript (if persistence is on) to inspect.
- `omp -p --mode json`: one task, newline-delimited JSON events on stdout, process exits. Prefer for orchestration and for any run you may need to inspect.
- `omp --mode rpc`: a persistent protocol process for integrations that need commands, cancellation, or live events. Read the [RPC protocol documentation](https://github.com/can1357/oh-my-pi/blob/main/docs/rpc.md), selecting the installed version's revision when available, before implementing; print-mode event parsing is not an RPC client.
- Interactive `omp`: a human-facing terminal session, not a batch interface. `--restore` (recover an interrupted turn and its subagents) is available only here; it rejects `-p` and `--mode`.

Verify interface flags with the installed `omp --help`. Protocol fields can change across versions; inspect a harmless local run before relying on a parser.

## Records and metrics

`scripts/run-omp.sh` keeps two records per run. Environment variables override both locations:

- **Transcript:** `USE_OMP_SESSION_DIR`, default `<omp sessions root>/--agent-delegations--`. The sessions root is `~/.omp/agent/sessions` unless `PI_CODING_AGENT_DIR` moves it. With `OMP_PROFILE` set or an XDG layout, the wrapper's `omp` uses that profile, so set `USE_OMP_SESSION_DIR` to a folder inside that profile's sessions root. Because the folder sits inside the sessions root, `omp stats` reports it as its own folder (`byFolder` in `omp stats --json`), including nested subagent and advisor transcripts. `omp --export` and `omp gc` work on it as on any session. `omp gc --archive` moves cold sessions out of the sessions root, so older ledger `session_file` paths can go stale. The resume picker's default per-project list leaves these runs out, but its all-sessions view includes them. Print mode never generates session titles; the ledger's `label` names the run instead.
- **Run directory and ledger:** `USE_OMP_STATE_DIR`, default `${XDG_STATE_HOME:-~/.local/state}/use-omp`. Each run gets `runs/<UTC time>-<label>.XXXX/` holding `prompt.md`, `events.jsonl`, `stderr.txt`, `exit.txt`, `summary.json`, `answer.md`, and `ledger-line.json`. The ledger is kept outside the sessions root so `omp stats` does not read it as a transcript.

Each `runs.jsonl` line has `started`, `duration_s`, `label`, `workspace`, `model`, `thinking`, `read_only`, `resumed_session`, `max_time`, `omp_version`, `exit`, `looks_complete`, `final_stop_reason`, `final_error`, `session_id`, `models`, `assistant_messages`, `tool_calls`, `tool_errors`, `approval_refusals` (tool errors from approval checks, expected under `--read-only`), `write_targets`, `subagent_tasks`, `background_jobs` (task and bash), `subagent_failures`, `subagent_cost_usd`, `retries`, `tokens`, `primary_cost_usd`, `async` (true only with `--allow-async`), `extra_configs` (overlays passed with `--config`), `caller` (`claude_session_id` from `CLAUDE_CODE_SESSION_ID` when set, and `cwd`), `run_dir`, and `session_file`. `--no-record` runs write neither record.

To keep a run out of omp's memory (an independent review, a test), pass an overlay:

```sh
overlay_dir=$(mktemp -d "${TMPDIR:-/tmp}/omp-overlay.XXXXXX")
printf 'memory:\n  backend: off\n' > "$overlay_dir/no-memory.yml"
bash "$skill_dir/scripts/run-omp.sh" ... --config "$overlay_dir/no-memory.yml"
```

Read the metrics with:

```sh
bash "$skill_dir/scripts/report.sh" [--since 2026-10-01] [--json]   # completion, failures, duration, primary cost
omp stats --summary                                             # tokens, latency, cost incl. subagents, per folder
```

The records hold prompts, source code, and tool output, as the user's own sessions do. Keep them private, and delete a run directory or session file when its content should not be kept.

## Capture JSON without the wrapper

Use this when the host cannot run `run-omp.sh`. For a fresh, resumable task, create a private session directory outside the source tree and retain its path. An explicit `--session-dir` without `--resume` or `--continue` creates a new session even if `autoResume` is enabled. This isolates conversation storage without changing the workspace's capabilities or credentials.

Set `workspace`, `model`, and literal task text `prompt` first, then launch with the intended profile/configuration:

```sh
session_dir=$(mktemp -d "${TMPDIR:-/tmp}/omp-session.XXXXXX")
run_dir=$(mktemp -d "${TMPDIR:-/tmp}/omp-run.XXXXXX")
# Subagents and long bash commands finish before exit instead of becoming cancelled background jobs:
printf 'async:\n  enabled: false\nbash:\n  autoBackground:\n    enabled: false\n' > "$run_dir/omp-overlay.yml"
omp -p --cwd "$workspace" --model "$model" --session-dir "$session_dir" \
  --config "$run_dir/omp-overlay.yml" --mode json --max-time 30m -- "$prompt" \
  < /dev/null > "$run_dir/events.jsonl" 2> "$run_dir/stderr.txt"
echo "exit=$?" > "$run_dir/exit.txt"
```

The `--` separator makes a leading `-` or `@` in task text literal rather than CLI syntax. For an intentional file attachment, use an absolute `"@$prompt_file"` before `--` instead. Close unused stdin as shown (or use the process runner's null-input option); an open inherited pipe blocks startup before the task deadline begins, and after one second omp prints a "waiting for EOF" notice to stderr.

Keep the session directory until all follow-ups finish. Temporary directories can be cleaned by the OS; use a private durable directory for longer-lived work. Remove only task-owned temporary files when the conversation is no longer needed. Do not delete user-managed session stores.

Capture stdout and stderr separately and retain the process exit code. Store transcripts in a private location: events can contain prompts, source code, tool results, and sensitive external data. Do not combine stderr into a JSON stream or assume the last line is the answer. If piping through another command, preserve omp's status rather than treating the parser's success as omp's success.

## Read the event stream

The first line is a `session` header (`version`, `id`, `cwd`, `timestamp`). Events that matter to a caller (omp 18.10.3):

- `message_update`: incremental deltas only, with no message snapshot. Not an authoritative message.
- `message_end`: complete message. For `message.role == "assistant"`, it carries `content[]` (`text`, `thinking`, and `toolCall` blocks), `provider`, `model`, `stopReason`, optional `errorMessage`, and `usage` (`input`, `output`, `cacheRead`, `cacheWrite`, `totalTokens`, `cost.total`).
- `tool_execution_start`: `toolCallId`, `toolName`, `args`. `tool_execution_end`: `toolName`, `result`, `isError`.
- `auto_retry_*`, `retry_fallback_*`, `auto_compaction_*`: retries, provider fallbacks, and compaction.
- `agent_end`: end-of-agent data. It has no aggregate cost, and it is not a substitute for process completion or checking errors.

`scripts/summarize-events.jq` (in this skill's directory, `skill_dir`) reduces a captured file to the session ID, models used, final stop reason and error, final text length, tool calls by name, tool errors, best-effort write targets (successful `write`/`edit`/`ast_edit` calls only; `bash` writes are not visible), subagent task count, background jobs started (with their types), subagent failures, retries, tokens, primary-agent and inline-subagent cost, and a `looks_complete` verdict:

```sh
jq -s -f "$skill_dir/scripts/summarize-events.jq" "$run_dir/events.jsonl"
```

`-s` loads the whole file into memory, which suits typical runs. A truncated last line makes jq fail; treat that as an incomplete run, not as an empty result. A stream cut at a line boundary still parses but shows `agent_end_seen: false`. `is_event_stream: false` means the file is not print-mode output (a session transcript uses different record types) or the run failed before the agent started; check stderr and `exit.txt`.

`primary_cost_usd` covers the primary agent. `subagent_cost_usd` adds the direct subagents that returned inline, which is every direct subagent under the wrapper's default overlay; the task tool's result carries each one's `usage`. Nested subagents (a subagent's own subagents), background subagents, and the advisor report their spend in their own transcripts; `omp stats` totals them from the saved transcripts. Compare against the provider's usage view when the bill matters.

Extract only the session ID:

```sh
jq -r 'select(.type == "session") | .id' "$run_dir/events.jsonl"
```

Print the text of the final assistant message:

```sh
jq -rs '[.[] | select(.type == "message_end" and .message.role == "assistant") | .message] | last | .content[]? | select(.type == "text") | .text' "$run_dir/events.jsonl"
```

Earlier assistant messages hold intermediate commentary. Print every assistant message's text:

```sh
jq -r 'select(.type == "message_end" and .message.role == "assistant") | .message.content[]? | select(.type == "text") | .text' "$run_dir/events.jsonl"
```

## Exit status and completion

In both text and JSON print modes (18.10.3), exit 1 means the last assistant message ended with `stopReason` `error` or `aborted`, a strict MCP startup failure, a session-store durability failure, or a launch failure before the model is called (for example `Error: File not found` for a missing `@file`). Usage errors exit 2. Signals exit 130, 143, or 129. Everything else exits 0, including:

- A `--max-time` deadline that expires between turns or before the first answer. A 1-second deadline exited 0 with no assistant message. A deadline that interrupts a model turn records `aborted` and exits 1.
- `stopReason` `length`.
- Tool calls refused for lack of approval, or that failed for any other reason.

So check the final message, not the exit code: complete means the stream reached `agent_end` and the final assistant message has `stopReason` `stop`, non-empty text, no `toolCall` blocks, and no `stopDetails.type` of `pause_turn`. omp keeps working after a `stop` that carries tool calls or a `pause_turn`. A `toolUse` message is not a final answer. Even a normal stop does not establish that the requested task succeeded; inspect the result.

## Inspect a run after the fact

- **Events file:** the primary record for `--no-session` runs. Look at the last event of a stalled run to see whether it was waiting on a tool, the model, or a retry.
- **Session files:** with `--session-dir`, the transcript is `<dir>/<timestamp>_<id>.jsonl`, and a sibling directory of the same name holds artifacts such as subagent logs. Without it, sessions go to a cwd-derived bucket under `~/.omp/agent/sessions/` (or the active profile's equivalent). `--no-session` writes no transcript.
- **HTML export:** `omp --export <session.jsonl> [out.html]` writes a standalone page for human review.
- **Shareable copy:** `omp anonymize [SESSION] -o <empty-dir>` redacts turn contents and keeps metadata, usage, and tool names. Inspect it before sharing.
- **Process logs:** `~/.omp/logs/omp.<date>.<pid>.log`, one file per process. All levels through `debug` are written by default; `OMP_LOG_LEVEL` (`error`, `warn`, `info`, or `debug`) limits them. For a startup hang, rerun with `PI_DEBUG_STARTUP=1` to see the last startup phase reached.
- **Startup diagnostics:** stderr reports extension load failures, MCP readiness failures, plan-mode suppression, and slow startup. Neither stderr nor the event stream lists every loaded skill, tool, or extension. To check a specific capability, ask the child to report it and confirm with a tool call in the events.

## Resume the exact session

Keep session persistence enabled on the first call. On follow-up:

```sh
omp -p --cwd "$workspace" --model "$model" --session-dir "$session_dir" \
  --resume "$session_id" --mode json --max-time 30m -- "$follow_up" \
  < /dev/null > "$run_dir/events-2.jsonl" 2> "$run_dir/stderr-2.txt"
```

Keep the same profile, session storage, and intended configuration. Use the ID returned by that particular child, rather than `--continue`, which can select an unrelated recent session when agents run concurrently. A new omp process does not inherit the parent's conversation; an explicit resume restores omp's saved conversation, not the parent's new findings. Include those findings in the follow-up prompt.

Do not run concurrent writers against the same session. Use separate sessions and disjoint workspaces for independent tasks. If persistence failed, a printed session ID is not proof that the conversation can be resumed; report the storage error.

## Deadlines and cancellation

Set the outer process timeout longer than omp's `--max-time`. The deadline is set after stdin is read, during session setup, and it aborts the agent loop. It does not cover time spent waiting for stdin, and it is not a spending cap. If the host limits a foreground command's duration (for example to 10 minutes), run omp as a background job the host tracks and wait for its completion notice. macOS has no GNU `timeout`; rely on `--max-time` plus the host's job control.

On cancellation, stop the owned process using the caller's process-management interface, wait for exit, and inspect partial results. Do not start a duplicate request while the original may still be running. Child tools can create external jobs or side effects; killing omp does not prove that those jobs were cancelled or changes rolled back.

For ongoing interaction, use a documented RPC client rather than repeatedly sending data to print mode's stdin. If an approval or human answer is needed, return that blocker to the user instead of silently switching to automatic approval.
