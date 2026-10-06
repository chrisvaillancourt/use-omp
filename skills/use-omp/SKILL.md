---
name: use-omp
description: "Delegate tasks to omp (Oh My Pi), preserve its normal tools and skills in headless calls, resume omp sessions, or troubleshoot a caller-agent's omp integration."
---
# Use omp from another agent

Run omp as a separate agent process, not as a bare model API. It can read and modify files, execute commands, and use configured external services. A call does not inherit your conversation or your tool restrictions automatically.

## 1. Establish the execution contract

Before launching, identify the target workspace, task, permitted changes, expected deliverable, and verification. For a review, say explicitly whether files may change. For implementation, assign disjoint ownership if another agent is editing concurrently; use an isolated worktree when appropriate.

Resolve the installed executable with `command -v omp`, then read `omp --help` and `omp models --help`. Select an available model with `omp models` or `omp models --json`; use an exact `provider/model` when provider choice matters. Do not copy a model name from an example without checking availability. A catalog entry alone does not prove authentication or access.

Use the user's existing installation, profile, and authentication. If omp is absent, consult the [upstream installation instructions](https://github.com/can1357/oh-my-pi#install) and follow the host's installation policy. For authentication failures, use the installed `omp login --help` flow with the user; keep credential values out of prompts, command arguments, and logs.

Done when the executable, workspace, model, profile (if any), and authorized scope are known.

## 2. Preserve the normal capabilities

Use the same OS user, project working directory, relevant environment, and omp profile as the intended interactive session. Set `--cwd` explicitly: a caller's temporary scratch directory will not supply the target project's instructions. Match any intentional config overlays or launch options; do not introduce a fresh profile to fix an unrelated failure.

Keep default tool, extension, skill, and rule discovery enabled. For normal-capability calls, omit `--no-tools`, `--tools`, `--no-extensions`, `--no-skills`, `--skills`, `--no-rules`, `--no-lsp`, and `--no-pty`. Avoid replacing the normal system prompt; put the task and constraints in the user prompt instead.

Headless is not identical to interactive: `ask` is interactive-only, UI-dependent extensions may differ, and approval requests may not be answerable. In omp 18.6.3, print mode ignores `plan.defaultOnStartup`; an interactive plan-first setting is not a headless review gate. Preserve approval policy. `--auto-approve`, permissive approval overrides, and `--plan-yolo` require explicit authorization; they are not routine automation fixes.

The parent agent's permission policy is not a sandbox for the child. CLI tool filters and prompt instructions are not security boundaries. For enforced read-only or no-network work, use an independently enforced environment that also restricts credentials and external-service access. If that environment cannot be provided, report the limitation before running sensitive work.

Done when the launch preserves the intended configuration and any capability differences are explicit.

## 3. Launch and collect the result

For a disposable task, use print mode with a private UTF-8 task file. Set `workspace` to the actual project directory, `model` to an available provider/model, and `prompt_file` to an absolute path:

```sh
omp -p --cwd "$workspace" --model "$model" --no-session --max-time 10m "@$prompt_file" < /dev/null
```

Close unused stdin. Print mode reads non-terminal stdin until EOF before starting; an inherited open pipe can stall startup even when a prompt argument is present. Programmatic callers should use an argument array with stdin set to null/ignored (for example Python's `subprocess.DEVNULL`). For intentional stdin input, write the complete prompt and close the pipe.

Choose session behavior explicitly: `--no-session` for disposable work, or a dedicated `--session-dir` and exact `--resume` ID for durable work. Merely omitting `--continue` does not guarantee a fresh conversation: the user's `autoResume` setting may reuse one. Read [automation.md](references/automation.md) for the durable recipe.

The deadline is an example: choose one suitable for the task, and give the parent process a longer timeout for startup and cleanup. `--max-time` is not a spending cap. Keep the process handle and collect its exit status; do not abandon an untracked background process.

Pass task text through the file rather than interpolating it into shell code. Shell quoting does not stop omp from treating a leading `-` as an option or `@` as a file attachment. An absolute `@$prompt_file` keeps those characters inside the file as content. Keep secrets out of task files and remove temporary prompt files after completion. Include:

- Goal and acceptance criteria.
- Relevant context the new session cannot know.
- Allowed files/actions and concurrent-work boundaries.
- Whether additional delegation is allowed. For bounded consultation, request no recursive delegation back to the calling agent.
- Required evidence and output format.

Use `--mode json` for machine-readable events and resumable automation. Read [automation.md](references/automation.md) before parsing output, resuming, handling deadlines, or maintaining a long-lived process. `--no-session` disables session persistence, not all logging or other persisted state.

Done when the child exits and you have the output, diagnostics, and exit status—not merely a successful spawn or a streamed text fragment.

## 4. Verify and hand back

Treat the response as another agent's report, not proof of success. Check the requested evidence and any affected files or external state. Distinguish a completed task from partial work, a refusal, a timeout, or an authentication failure. Do not re-run a potentially mutating request blindly after a failed or interrupted call; first inspect what it already changed.

For empty responses, missing tools, or provider errors, read [troubleshooting.md](references/troubleshooting.md). That reference separates an observed historical Codex schema bug from general launch guidance; do not permanently disable capabilities based on an old workaround.

Return the useful result, verification performed, remaining blockers, and the session ID if follow-up is expected. Never claim that headless capabilities exactly match an interactive session without comparing the effective setup.
