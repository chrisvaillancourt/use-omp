# Troubleshooting omp calls

## Stalls and silent deadlines

A plain text-mode run shows nothing on stdout until it ends. If the deadline interrupts a model turn, it prints only `Deadline exceeded` and exits 1; if the deadline expires between turns, it can exit 0 with no output. With `--no-session`, nothing records where it stopped; otherwise, inspect the saved transcript first. Observed 2026-10-13: a text-mode run on `github-copilot/gpt-6.1-sol` hit its 5-minute deadline with no output, and the same prompt in `--mode json` finished in about a minute. The cause was not found. Check what the run already changed before rerunning. Rerun in JSON mode with events and stderr captured to files, then read the last events: a pending `tool_execution_start`, a run of `auto_retry_*` events, or no `message_end` at all point to different causes. If nothing reaches stdout, check stderr for "waiting for EOF" (stdin left open) and rerun with `PI_DEBUG_STARTUP=1` to see the last startup phase.

A deadline can also end a run with exit 0 and no final answer. See [automation.md](automation.md#exit-status-and-completion).

## Subagent or command results missing, or a run that ends early

With `async.enabled: true` (omp's default), the task tool starts subagents as background jobs. With `bash.autoBackground.enabled: true` (also the default), a bash command still running after 60 seconds becomes a background job, and the agent sees `Backgrounded as job …` instead of the output. Print mode does not wait for either: when the primary agent ends its turn, shutdown cancels jobs still running and their results are lost. The run still exits 0 and can look complete. Observed 2026-10-13 on omp 18.10.3: a run exited after 8 seconds while its subagent's 45-second command was aborted (`Request was aborted` in the subagent transcript). Signs: `background_jobs` above 0 in the summary (`background_job_types` says `task` or `bash`), a tool result whose `details.async.state` is `running`, or a subagent transcript under the session's artifact directory ending in `aborted`. Fix: launch through `run-omp.sh` without `--allow-async`; it applies an overlay setting both `async.enabled` and `bash.autoBackground.enabled` to `false`. When calling omp directly, pass `--config` with that overlay.

## Refused or failing tools

`Tool "<name>" requires approval but no interactive UI available` means the effective approval mode or a per-tool policy needs a prompt for that call, and print mode cannot show one. The child sees a tool error and may answer without that evidence. Check `tool_errors` in the run summary. Under `--read-only` these refusals are expected, and the child's findings are static analysis it could not test; rerun without `--read-only` in an isolated worktree when findings need proof. Otherwise ask the user before raising the approval mode; do not add `--auto-approve` to get past it.

## Launch errors

- `File not found` for a prompt attachment: a relative `@prompt.md` resolves against `--cwd`, not the caller's directory. Use an absolute path.
- `Cannot index array with string ("selector")` from `omp models --json | jq '.[].selector'`: the output is an object with a `models` array; use `.models[].selector`.
- Exit 127 from `timeout`: macOS has no GNU `timeout`. Use `--max-time` and the host's background-job control.

## Missing capabilities or a different environment

Compare the actual executable/version, OS user, `--cwd`, profile, config overlays, and relevant environment with the intended interactive launch. Check installed help and startup diagnostics before changing flags. A different working directory can change project instructions, skills, and configuration. A fresh profile may have different credentials and settings. Parent-process sandboxing may limit filesystem, network, or executable access.

Skills provide instructions; they do not install all optional tools or grant service access. A tool's presence does not prove its credentials, browser connection, language server, or other dependencies work. Check the specific failing capability rather than claiming parity from a successful PONG response.

## Empty Codex `length` responses: historical schema trigger

Observed with omp **18.4.9** on macOS using `openai-codex/gpt-6.1-sol`. This is a configuration-specific diagnosis, not a claim that all current Codex failures have the same cause. The behavior has not been re-established for every later release.

Symptom:

```text
Length-stop recovery gave up after 3 consecutive `length` responses from openai-codex/<model> with no text or tool call. Try switching models or raising the model's max output tokens.
```

The backend emitted `response.incomplete`, reason `max_output_tokens`, with empty output and zero usage. In the affected installation, `--no-tools` still sent extension/MCP declarations. A `claude_task` extension included this constraint at `parameters.properties.model.pattern`:

```regex
^claude-[a-z][a-z0-9]*(?:-[a-z0-9]+)*-\d+(?:-[a-z0-9]+)*$
```

Live isolation showed:

| Outgoing declarations | Result |
| --- | --- |
| Original 62 extension/MCP tools | Empty failure |
| Only `claude_task`, original schema | Same failure |
| Other 61 tools, excluding `claude_task` | PONG |
| No tools | PONG |
| `claude_task` with only this `pattern` removed | PONG |
| All 62 tools with only this `pattern` removed | PONG |

The pattern was the isolated trigger; the internal backend mechanism remains unknown. Raising a token cap was not a demonstrated fix. The inspected Codex builder intentionally did not forward caller output caps.

A tested workaround was adding `--no-extensions` to the failing `--no-tools` invocation. That reduced capability: it still left 61 MCP tools available. In that installation, `--tools=read` also succeeded but exposed both `read` and `write`. Neither flag combination established a read-only or tool-free boundary.

For normal-capability delegation, use the normal launch described in SKILL.md rather than applying this workaround automatically. If diagnosing the same symptom, inspect sanitized outgoing tool declarations and raw response status, isolate the offending declaration, and change one variable at a time. Do not record authentication headers or private prompt contents. A response ID proves a request was assigned an ID, not that its inputs were valid.

The proposed extension fix is to omit the incompatible regex from the provider-facing schema while preserving exact local validation before executing Claude. This document does not assert that the extension or omp has shipped that fix. Keep the validation distinction; do not strip every tool's constraints as a generic workaround.

## Authentication, failures, and retries

Use the existing provider login flow; do not print tokens or change credential helpers to bypass errors. Capture the exit code, stderr, and final assistant status. For a failing request that could modify files or external state, inspect side effects before deciding whether it is safe to retry. Changing providers or models can change cost, privacy, and behavior; honor the user's selection rather than silently substituting one.
