---
name: use-omp
description: "Consult another model through omp (Oh My Pi) for an independent second opinion, or delegate a task to it. Use when the user asks to consult, ask, or have another model review or double-check work; at a high-stakes checkpoint (a plan before implementing, a hard-to-reverse decision, a conclusion others will rely on) when the user has asked for such consultations; or to resume an omp session or troubleshoot an omp integration. Not for routine edits or facts you can check directly."
---
# Use omp from another agent

Run omp as a separate agent process, not as a bare model API. It can read and modify files, execute commands, and use configured external services. A call does not inherit your conversation or your tool restrictions automatically.

## When to consult without being asked

Use this skill when the user asks you to consult, ask, or delegate to omp or to a model omp provides. Consulting on your own initiative is opt-in: do it only when the user's instructions or memory ask for second opinions at checkpoints, and follow any frequency or model they set there. Otherwise, at a checkpoint that qualifies, offer a consultation in one line and carry on.

A checkpoint qualifies when a mistake would be costly and the work is ready to judge:

- a plan or design, before implementation starts;
- a decision that is hard to reverse, such as a migration, a deletion, a merge, or a published change;
- a conclusion, data claim, or deliverable that someone else will rely on.

Skip routine edits, questions that a test or a source check settles, and work that has not changed since the last consultation. Consult once per checkpoint. Before launching, say in one line what you are consulting on and with which model, so the user can stop it. Run it in the background when the host allows, and keep working on whatever does not depend on the answer.

## 1. Establish the execution contract

Before launching, identify the target workspace, task, permitted changes, expected deliverable, and verification. For a review, say explicitly whether files may change. For implementation, assign disjoint ownership if another agent is editing concurrently; use an isolated worktree when appropriate.

Resolve the installed executable with `command -v omp` and check `omp --version`. This skill was last verified against omp **18.22.2**; on a different version, read `omp --help` before relying on the flags below.

Choose the model from what the user said:

- **No model named:** omit `--model`. The wrapper uses `USE_OMP_MODEL` when it is set, and otherwise lets omp's `default` role decide. If the user named only an effort ("with xhigh reasoning"), pass `--thinking` alone.
- **A bare model ID** (`some-model`, or `some-model:high`): pass it as given. The same ID can appear under several providers. The wrapper then picks by omp's `modelProviderOrder` setting, read the way the run will read it (the workspace's config plus any `--config` overlays), and prints `model=<selector>` to stderr. With no order set, it exits 2 and lists the candidates: show them to the user and ask which provider to use. If the user wants that choice to stick, suggest `omp config set modelProviderOrder '["provider-a", "provider-b"]'`. Never take the first entry from `omp models`: that order is the catalog's, not the user's preference.
- **A `provider/model` selector or an omp role name** (`slow`, `@slow`): pass it as given. omp resolves a role with the role's own effort.

If a bare ID matches no available model, the wrapper exits 2 and lists similar selectors. A `provider/model` selector goes to omp unchecked; omp requires an exact ID or alias, and an unknown one exits 1 with `Model "…" not found` and a near match if it has one. `omp models find <pattern>` searches the catalog. Neither the wrapper nor omp checks that the effort suits the model. Show the alternatives and ask, or state the substitution in your reply. Never substitute silently. Do not copy a model name from an example without checking availability. To list exact selectors yourself, use `omp models --json | jq -r '.models[].selector'` (the output is an object with a `models` array, not a bare array). A catalog entry alone does not prove authentication or access.

Use the user's existing installation, profile, and authentication. If omp is absent, consult the [upstream installation instructions](https://github.com/can1357/oh-my-pi#install) and follow the host's installation policy. For authentication failures, use the installed `omp login --help` flow with the user; keep credential values out of prompts, command arguments, and logs.

Done when the executable, workspace, model (or the decision to use the default), reasoning effort, profile (if any), and authorized scope are known.

## 2. Preserve the normal capabilities

Use the same OS user, project working directory, relevant environment, and omp profile as the intended interactive session. Set `--cwd` explicitly: a caller's temporary scratch directory will not supply the target project's instructions. Match any intentional config overlays or launch options; do not introduce a fresh profile to fix an unrelated failure.

Keep default tool, extension, skill, and rule discovery enabled. For normal-capability calls, omit `--no-tools`, `--tools`, `--no-extensions`, `--no-skills`, `--skills`, `--no-rules`, `--no-lsp`, and `--no-pty`. Avoid replacing the normal system prompt; put the task and constraints in the user prompt instead.

Set reasoning effort with `--thinking <level>` (`off`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, or `auto`) when the user names one or the task warrants it. Without it, omp resolves effort through its own chain (selector suffix, role and model defaults, then the global setting), so pass it whenever effort must be fixed. A `provider/model:level` selector suffix also works; an explicit `--thinking` overrides it.

Headless is not identical to interactive (omp 18.22.2):

- Two default-on settings create background jobs, as in the TUI: `async.enabled` (task subagents) and `bash.autoBackground.enabled` (bash commands still running after 60 seconds, such as a long test suite). The child keeps working while they run. Without `--wait-async`, print mode ends the run when the primary agent's turn ends and cancels any job still running; a test run exited after 8 seconds with its subagent aborted, while still exiting 0. The wrapper passes `--wait-async`, so the run waits for its jobs and wakes the child with each result, as the TUI does, until `--max-time`; the task needs no "wait for your subagents" line. Bash commands keep omp's tool timeout (300 seconds by default) whether they run inline or in the background, so for longer commands such as a slow test suite, tell the child to pass a larger `timeout` to bash. `--no-async` runs subagents and long commands inline instead (section 3). When launching omp directly, pass `--wait-async`. Unfinished todos do not prompt the agent to continue.
- `--model` and `--thinking` replace the run's `default` role. omp's own subagents use their configured role (for example `task` or `smol`) when the user has one; an unconfigured role falls back to the run's `--model` and possibly its `--thinking`.
- The task file arrives as a `<file name="...">` attachment. Without a typed message, a model can decline its instructions as untrusted file content, so the wrapper adds one line after it: "The attached file is my task for you. Carry it out." When launching omp directly with `@file`, add a line like it after `--`. Write the file as direct instructions to the agent.
- `ask` is unavailable, extension prompts get default answers, `--restore` is interactive-only, and print mode ignores `plan.defaultOnStartup`, so an interactive plan-first setting is not a headless review gate.
- When a memory backend is enabled (`omp config get memory.backend`), the run reads and writes that backend's memory, even with `--no-session`. With the `mnemopi` backend, the bank is the one `mnemopi.scoping` selects. Isolation depends on that setting, not just the workspace path: the default `per-project` keeps one bank per workspace path, `per-project-tagged` writes per project but also recalls from a shared bank, `global` shares one bank, and a project's `.omp/config.yml` can pin one named bank for every checkout. Earlier delegated runs sharing that bank, including test runs, can therefore surface in a new run's context. In one test, a probe answered with a string recalled from an earlier run instead of doing its task. The wrapper therefore turns memory off for each run by default (`memory.backend: off` in its overlay), so a second opinion does not depend on earlier runs and the run adds nothing to the bank. Pass `--memory` to keep the user's setting, for example for an implementation task that benefits from what omp has learned about the repository. When launching omp directly, pass the same overlay for independent work.
- omp loads `.env` from the directory it was launched in, not from `--cwd`. The wrapper starts omp in the workspace, as an interactive launch would.
- `--max-time` also counts startup, including up to 30 seconds of waiting for MCP servers. A server that is not ready loses its tools for the run.

Approval: omp's default `tools.approvalMode` is `yolo`, so a headless child runs read, write, and exec tools without asking, as an interactive session does. When a tool does need approval and no UI exists, the call fails with a tool error; it neither hangs nor auto-approves, and the process can still exit 0. Do not add `--auto-approve`, a more permissive `--approval-mode`, or `--plan-yolo` without explicit authorization.

Reviews keep full capabilities. Running tests, scripts, and commands is how a reviewer proves that an issue exists, so do not restrict tools for a review. Protect the user's files by isolating the review instead:

- Point the workspace at a copy of the code under review outside the user's checkout, not at a checkout with someone's uncommitted work. `git worktree add --detach <path> <commit>` gives separate files but shares the repository's branches, tags, stash, config, and hooks, so a child that runs `git stash`, `git branch -D`, or `git commit --amend` there still changes the user's repository. When the child may run git commands that change refs, use `git clone --no-local <repo> <path>` and check out the commit instead.
- A fresh worktree or clone has no untracked files: no `.env`, virtual environment, `node_modules`, or local config. Bootstrap dependencies the project's documented way and copy only the untracked files the review needs, so tests can run.
- To review uncommitted or untracked changes, carry them into the copy (for example `git -C <repo> diff HEAD | git -C <path> apply`, then copy the untracked files) and say in the result that the review covers that snapshot.
- Tell the child to leave tracked files unchanged and to keep scratch files and repro scripts in a temporary directory.
- Ask it to back each finding with evidence: the command it ran and the output, or a `file:line` citation.
- Compare `git status` in the user's checkout before and after.
- Keep one worktree or clone per review across rounds, and remove it (`git worktree remove <path>`) only after the last follow-up. Headless omp refuses to `--resume` a session whose workspace directory is gone. For a new round on a new commit, move the same copy to it (`git -C <path> checkout --detach <commit>`, then bootstrap again) instead of removing it and adding another.

`--read-only` is opt-in. Use it (it adds `--approval-mode always-ask`) only when the user asks for it or nothing may execute at all, such as untrusted code. Its effects and side effects:

- Only read-tier tools run. `bash`, `eval`, file writes and edits, MCP tools, and omp's own subagents fail with `requires approval but no interactive UI available`.
- The child can read and reason but cannot run tests or reproduce an issue, so its findings are unverified static analysis. Tell it this in the task so it does not waste turns on refused calls, and report the review as static.
- The refused calls appear in `tool_errors` (and as `approval_refusals` in the ledger), yet the run still exits 0 and can look complete.
- It is not a sandbox. Read tier still includes web search, URL reads, and `memory_edit`, and the user's `tools.approval` allowances and `bash.patterns` allow rules let matching calls through.

If the review cannot be isolated and the user's uncommitted work must not be touched, ask the user whether to isolate first or accept a static `--read-only` review.

The parent agent's permission policy is not a sandbox for the child. CLI tool filters, approval modes, and prompt instructions are not OS security boundaries. For enforced read-only or no-network work, use an independently enforced environment that also restricts credentials and external-service access. If that environment cannot be provided, report the limitation before running sensitive work. If the host's own safety checks refuse an omp launch, report the refusal; do not work around it.

Done when the launch preserves the intended configuration and any capability differences are explicit.

## 3. Launch and collect the result

Write the task to a private UTF-8 file and launch it with the bundled wrapper. Set `skill_dir` to the directory containing this SKILL.md, `workspace` to the project directory (or review worktree), and `prompt_file` to the task file's path. Add `--model` only when the user named a model (section 1). The wrapper runs print mode with JSON events and closed stdin, starting omp in the workspace. It keeps the events, stderr, exit code, summary, and final answer in a run directory, and stores omp's transcript for `omp stats`, `--export`, and `--resume`. It appends one line per run to a ledger and prints the run summary as JSON:

```sh
bash "$skill_dir/scripts/run-omp.sh" --workspace "$workspace" --thinking medium \
  --max-time 30m --label "short purpose" --prompt-file "$prompt_file"
```

The variables stand for values you fill in. Where the host checks shell commands against an allowlist, as Claude Code does, write the literal script path, workspace, and prompt file into the command instead of shell variables or `$(…)`: those forms can send an otherwise allowed command to extra review or be refused outright.

The answer is in `answer.md` in the run directory, next to `prompt.md`, `events.jsonl`, `stderr.txt`, `exit.txt`, and `summary.json`. It holds every message in which the model ended its turn normally, in order, because a run can end with a short addendum after the message that holds the verdict; the summary's `answer_messages` counts them. Narration between tool calls and partial attempts that a retry replaced stay out. The script prints `run_dir=<path>` to stderr as soon as it starts; read that run directory, not one found by a glob. Its exit code is omp's, and 2 means a usage error, including a model it could not resolve. Options:

- `--model MODEL` picks the model (section 1); without it, `USE_OMP_MODEL` or omp's `default` role decides.
- `--resume <session_id>` (from the summary) continues a recorded run. Pass the same `--workspace` and `--model`, `--thinking`, and any `--read-only`, `--memory`, `--no-async`, or `--config` again, since they apply per run; the label may differ. The follow-up task needs only what is new (your findings, what to reconsider, the result you need), not the original brief. The session's workspace directory must still exist (section 2).
- `--no-record` makes a disposable run that leaves no transcript or ledger line.
- `--memory` keeps the user's omp memory setting; by default the run has memory off (section 2).
- `--config FILE` adds an omp config overlay for the run (repeatable). Overlays merge in order after the wrapper's own, so a later one wins.
- `--no-async` runs subagents and long bash commands inline, blocking the child until each finishes (an overlay sets `async.enabled` and `bash.autoBackground.enabled` to `false`). By default they run in the background and the run waits for them. Inline subagents report their spend in `subagent_cost_usd`; background ones do not, and `omp stats` has it. `--allow-async` is accepted and means the default.
- `--read-only` is opt-in; see section 2 for what it blocks.

`bash "$skill_dir/scripts/report.sh"` summarizes the ledger: completion rate, failures, durations, and estimated cost by model, workspace, and week. The delegations folder in `omp stats` adds token, latency, and cost totals that include subagents. [automation.md](references/automation.md#records-and-metrics) gives the storage locations, the ledger fields, and the raw `omp` command for hosts that cannot run the script.

JSON mode matters even for one-off calls. The events file records each tool call, the edit targets, the model that answered, the stop reason, and the primary agent's token cost. A stalled run shows its last event. After omp exits, the wrapper drops the progress-only events (`message_update`, `tool_execution_update`, `tool_stream_update`) from the saved file. They repeat partial output, so they make up most of a run's size, and nothing reads them afterward. Plain `-p` prints only the final message to stdout, so a stall or deadline leaves nothing there to inspect.

Close unused stdin. Print mode reads non-terminal stdin until EOF before starting; an inherited open pipe stalls startup even when a prompt argument is present. Programmatic callers should use an argument array with stdin set to null/ignored (for example Python's `subprocess.DEVNULL`). For intentional stdin input, write the complete prompt and close the pipe.

When launching omp directly, choose session behavior explicitly: `--no-session` for disposable work, or a dedicated `--session-dir` and exact `--resume` ID for durable work. Merely omitting `--continue` does not guarantee a fresh conversation: the user's `autoResume` setting may reuse one.

The deadline and thinking level are examples: choose ones that suit the task. Typical delegations take a few minutes, a long tail takes 15 minutes or more, and some take over an hour, so leave headroom. `--max-time` accepts seconds or a duration such as `600`, `10m`, or `1h`; it is not a spending cap. If the deadline plus a minute of startup could reach the host's command timeout, or you do not know that timeout, start the wrapper as a background job the host tracks. To cancel it, send TERM: the wrapper stops omp and still writes the record. INT may be ignored when the wrapper was started in the background. How to wait depends on who launched the job:

- An agent the host wakes when a background job finishes (in Claude Code, the main session): wait for that notice and do other work meanwhile. Do not poll the run directory or the job's output file, and do not loop on `sleep`.
- An agent the host does not wake (in Claude Code, a subagent, whose run ends when its turn does): if the deadline plus startup fits under the host's foreground limit (600 s in Claude Code), run the wrapper in the foreground with the command timeout set above it. Otherwise start it in the background, keep working, then block once on `exit.txt` with a condition waiter that has its own timeout, such as `wait-for --file <run_dir>/exit.txt --timeout <max-time + 120 s>` where that helper is installed, or an `until [ -f <run_dir>/exit.txt ]` loop with a deadline. The wrapper writes `exit.txt` last, after `summary.json`, `answer.md`, and the ledger line, so they are complete once it exists.

`--max-time` is the deadline to rely on. GNU `timeout` is not part of stock macOS; where it is installed (for example from Homebrew coreutils), it can add an outer limit, but keep `--max-time` as the primary one. Keep the process handle and collect its exit status; do not abandon an untracked background process. Independent runs can execute in parallel; each wrapper call gets its own run directory and session.

Pass task text through the file rather than interpolating it into shell code. Shell quoting does not stop omp from treating a leading `-` as an option or `@` as a file attachment. When calling omp directly, use an absolute `@$prompt_file`; a relative one resolves against `--cwd` and can fail with `File not found`. Keep secrets out of task files: the wrapper keeps a copy of the task in the run directory. Include:

- Goal and acceptance criteria.
- Relevant context the new session cannot know.
- Allowed files/actions and concurrent-work boundaries.
- Whether additional delegation is allowed. For bounded consultation, request no recursive delegation back to the calling agent.
- Required evidence and output format. Ask for the verdict or result in one final message.

Write the brief so it does not narrow the child by accident:

- Point to sources (paths, links, ticket keys, commands) rather than pasting your own extracts, and call any list of sources a starting point. A reviewer told that every claim must be "supported by the sources" checked only the listed ones and flagged claims it could have verified elsewhere.
- Do not tell the child what it cannot do ("you likely can't read Slack"). It has its own tools, MCP servers, and credentials, which can differ from yours, and one such brief made a child skip sources it could reach. When a prohibition is about one resource, name it; keep a category-wide limit ("no network writes") only when you mean the whole category.

What works well:

- Ask for evidence the child produced, such as commands and their output, not only conclusions. omp can run tests, write repro scripts in a temporary directory, and use its own subagents to cover several areas in parallel.
- For adversarial reviews, a high effort level (`high` or `xhigh`) is worth the time. `xhigh` runs commonly take 15 minutes or more and sometimes 40, so give them a `--max-time` of 45m to 60m.
- Iterate in the same session with `--resume` instead of starting over. Send your verification results back and ask the child to confirm, revise, or withdraw each finding.
- Run independent lanes in parallel, each with its own task file and label, rather than one omnibus prompt.
- The child loads omp's own skills, rules, and project instructions, not the calling agent's. Name any convention it must follow in the task.

Read [automation.md](references/automation.md) before launching omp without the wrapper, writing your own event parser, handling deadlines, or maintaining a long-lived process. `--no-session` disables session persistence, not all logging or other persisted state.

Done when the child exits and you have the output, diagnostics, and exit status—not merely a successful spawn or a streamed text fragment.

## 4. Verify and hand back

Exit code 0 does not mean the task finished. A `--max-time` deadline can end the run with exit 0 and no final answer, and refused or failed tool calls also leave exit 0. Exit 1 covers a final `error` or `aborted` stop reason (including a deadline that interrupts a model turn, `Deadline exceeded`, and provider refusals or overloads, see [troubleshooting](references/troubleshooting.md#provider-refusals-and-overloads)) and also launch failures that never reach the model, such as a missing `@file` or a `--resume` whose workspace is gone. For those, `final_error` holds stderr's last line; the full text is in `stderr.txt`. Exit 3 means omp's cost cap (`session.maxCost`) stopped the run. After a deadline, `--resume` the same session with a larger `--max-time` and ask the child to finish from the evidence it already gathered, rather than starting over. The summary's `looks_complete` is true only when the stream reached a terminal `agent_end` and the final assistant message stopped normally with text and no pending tool calls, so it is also true when the child declines the task ([troubleshooting](references/troubleshooting.md#a-refusal-that-looks-complete)); read the answer. Check `tool_errors` too. Most are the child's own failed commands, such as a failing test or a missing path, and need no action. A refusal (`requires approval`) or a missing tool can leave a "complete" answer resting on evidence the child never got. `write_targets` is a best-effort hint: it lists targets of successful `write`/`edit`/`ast_edit` calls (`agent://` entries are messages to omp's own subagents) but misses files changed through `bash`. For a review, `git status` before and after is the authority. `subagent_failures` counts inline subagents that aborted or failed; it does not see background subagents, so check that their results appear in the answer. A nonzero `background_jobs` is expected, since the wrapper waits for them; after a direct launch without `--wait-async`, check that those jobs' results arrived before the run ended.

Treat the response as another agent's report, not proof of success. Check the requested evidence and any affected files or external state. For a review that should not change files, compare `git status` before and after. Distinguish a completed task from partial work, a refusal, a timeout, or an authentication failure. Do not re-run a potentially mutating request blindly after a failed or interrupted call; first inspect what it already changed.

For empty responses, stalls, missing tools, or provider errors, read [troubleshooting.md](references/troubleshooting.md). That reference separates an observed historical Codex schema bug from general launch guidance; do not permanently disable capabilities based on an old workaround.

Return the useful result, the verification you performed, the model that answered (`models` in the summary), remaining blockers, the run directory, and the session ID if follow-up is expected. Leave cost out unless the user asks for it. The summary's figures are omp's estimates at list prices, not charges, and subscription providers bill by plan usage. The ledger, `report.sh`, and `omp stats` keep them for whoever needs them. Never claim that headless capabilities exactly match an interactive session without comparing the effective setup.
