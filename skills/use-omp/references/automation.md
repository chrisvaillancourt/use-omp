# Automation and session continuity

## Choose the interface

- `omp -p`: one task, final text on stdout, process exits.
- `omp -p --mode json`: one task, newline-delimited JSON events on stdout, process exits. Prefer for orchestration.
- `omp --mode rpc`: a persistent protocol process for integrations that need commands, cancellation, or live events. Read the [RPC protocol documentation](https://github.com/can1357/oh-my-pi/blob/main/docs/rpc.md), selecting the installed version's revision when available, before implementing; print-mode event parsing is not an RPC client.
- Interactive `omp`: a human-facing terminal session, not a batch interface.

Verify interface flags with the installed `omp --help`. Protocol fields can change across versions; inspect a harmless local run before relying on a parser.

## Capture JSON without losing failure information

For a fresh, resumable task, create a private session directory outside the source tree and retain its path. An explicit `--session-dir` without `--resume` or `--continue` creates a new session even if `autoResume` is enabled. This isolates conversation storage without changing the workspace's capabilities or credentials.

Set `workspace`, `model`, and literal task text `prompt` first, then launch with the intended profile/configuration:

```sh
session_dir=$(mktemp -d "${TMPDIR:-/tmp}/omp-session.XXXXXX")
omp -p --cwd "$workspace" --model "$model" --session-dir "$session_dir" \
  --mode json --max-time 10m -- "$prompt" < /dev/null
```

The `--` separator makes a leading `-` or `@` in task text literal rather than CLI syntax. For an intentional file attachment, use an absolute `"@$prompt_file"` before `--` instead. Close unused stdin as shown (or use the process runner's null-input option); an open inherited pipe can block startup before the task deadline begins.

Keep the session directory until all follow-ups finish. Temporary directories can be cleaned by the OS; use a private durable directory for longer-lived work. Remove only task-owned temporary files when the conversation is no longer needed. Do not delete user-managed session stores.

Use your process runner to capture stdout and stderr separately and retain the process exit code. Store transcripts in a private location: events can contain prompts, source code, tool results, and sensitive external data. Do not combine stderr into a JSON stream or assume the last line is the answer. If piping through another command, preserve omp's status rather than treating the parser's success as omp's success.

Current print-mode events include:

- `type: "session"`: header; `id` is the session identifier.
- `type: "message_update"`: incremental output, not an authoritative complete message.
- `type: "message_end"`: complete message; filter `message.role == "assistant"` for assistant messages.
- `type: "agent_end"`: end-of-agent data; not a substitute for process completion or checking errors.

For a captured JSONL file, extract the session ID:

```sh
jq -r 'select(.type == "session") | .id' "$events_file"
```

Print text from every completed assistant message (including intermediate commentary):

```sh
jq -r 'select(.type == "message_end" and .message.role == "assistant") | .message.content[]? | select(.type == "text") | .text' "$events_file"
```

To inspect the last completed assistant message, including its status:

```sh
jq -s '[.[] | select(.type == "message_end" and .message.role == "assistant") | .message] | last' "$events_file"
```

The last example loads the whole transcript into memory; use incremental parsing for large runs. Handle a missing message, malformed/truncated JSON, `errorMessage`, and `stopReason` values such as `error`, `aborted`, or `length`. A `toolUse` message is not a final answer. Even exit code zero and a normal stop do not establish that the requested task succeeded: inspect the result. Earlier omp versions may differ in how JSON-mode failures affect exit status.

## Resume the exact session

Keep session persistence enabled on the first call. On follow-up:

```sh
omp -p --cwd "$workspace" --model "$model" --session-dir "$session_dir" \
  --resume "$session_id" --mode json --max-time 10m -- "$follow_up" < /dev/null
```

Keep the same profile, session storage, and intended configuration. Use the ID returned by that particular child, rather than `--continue`, which can select an unrelated recent session when agents run concurrently. A new omp process does not inherit the parent's conversation; an explicit resume restores omp's saved conversation, not the parent's new findings. Include those findings in the follow-up prompt.

Do not run concurrent writers against the same session. Use separate sessions and disjoint workspaces for independent tasks. If persistence failed, a printed session ID is not proof that the conversation can be resumed; report the storage error.

## Deadlines and cancellation

Set the outer process timeout longer than omp's `--max-time`. On cancellation, stop the owned process using the caller's process-management interface, wait for exit, and inspect partial results. Do not start a duplicate request while the original may still be running. Child tools can create external jobs or side effects; killing omp does not prove that those jobs were cancelled or changes rolled back.

For ongoing interaction, use a documented RPC client rather than repeatedly sending data to print mode's stdin. If an approval or human answer is needed, return that blocker to the user instead of silently switching to automatic approval.
