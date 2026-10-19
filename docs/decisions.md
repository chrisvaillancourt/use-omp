# Design decisions

Each entry records what was decided, why, the evidence, and when to revisit it. Evidence and experiments are described in [the 2026-10-13 audit](2026-10-13-audit.md). Behavior claims were verified against omp 18.10.3 unless noted, and rechecked against the 18.10.4 and 18.12.3 source diffs and live tiers.

## 1. JSON event mode is the default launch

**Decision:** Every launch uses `omp -p --mode json`, with events, stderr, and the exit code captured to files. Plain text mode is not recommended even for one-off calls.

**Why:** Text mode prints only the final message. When a run stalls or hits its deadline, nothing records where it stopped. Usage showed a text-mode run that hit a 5-minute deadline with no output, while the same prompt in JSON mode finished in about a minute. The event stream also records each tool call, the model that answered, stop reasons, and token cost, which the summary and ledger build on.

**Revisit if:** omp changes its event schema. `scripts/verify-skill.sh` and `summarize-events.jq` depend on the field names listed in [automation.md](../skills/use-omp/references/automation.md#read-the-event-stream).

## 2. Completion is judged by the final message, not the exit code

**Decision:** A run is complete only when the stream reached `agent_end` and the final assistant message has `stopReason: "stop"`, non-empty text, no pending `toolCall` blocks, and no `pause_turn`. `summarize-events.jq` reports this as `looks_complete`. Agents also check `tool_errors`, `subagent_failures`, and `background_jobs`.

**Why:** omp exits 1 only for a final `error`/`aborted` stop reason, strict MCP startup failure, session-store durability failure, or a launch failure. It exits 0 for a deadline that lands before the first answer (a 1-second probe exited 0 with no assistant message), for `length` stops (since 18.12.3, not when its length-stop recovery gives up), for refused or failed tool calls, and for runs whose background subagents were cancelled. omp continues after a `stop` that carries tool calls or a `pause_turn`, so those are not final.

## 3. A wrapper script instead of a hand-assembled recipe

**Decision:** Agents launch through `skills/use-omp/scripts/run-omp.sh`. It builds the omp command, captures the run, writes the summary and final answer, and records the run. The raw command stays documented for hosts that cannot run the script.

**Why:** The usage audit found recurring hand-assembly mistakes: a wrong `jq` path for `omp models --json`, a relative `@file` resolving against the wrong directory, open stdin, and missing completion checks. A script makes the launch consistent and is where recording happens.

**Details that matter:**

- omp starts in the workspace (`cd` before `exec omp`), because omp loads `.env` from its launch directory, not from `--cwd`. This matches an interactive launch.
- Record files are created with `umask 077`, but omp runs with the caller's umask. An earlier draft leaked 077 into omp, which would have made every file omp created in the workspace private.
- TERM, INT, and HUP are forwarded to omp and the record is still written (exit 143 on TERM). INT cannot be trapped when the wrapper itself was started as a background job, so hosts should cancel with TERM.
- Usage errors exit 2, distinct from omp's exit 1.

## 4. Record every delegated run (option C)

**Decision (user, 2026-10-13):** Each recorded run keeps:

- the omp transcript in `<sessions root>/--agent-delegations--` via `--session-dir` (override `USE_OMP_SESSION_DIR`);
- a run directory and one `runs.jsonl` ledger line under `${XDG_STATE_HOME:-~/.local/state}/use-omp` (override `USE_OMP_STATE_DIR`).

`--no-record` opts out for disposable runs.

**Why:** Before this, every delegation used `--no-session` and scratch directories, so nothing survived for auditing or metrics. This audit had to reconstruct runs from Claude Code transcripts.

**Alternatives considered:**

- **A. Run directories only (keep `--no-session`):** simple, but no transcripts, no resume, and no `omp stats`.
- **B. omp's default per-project session store:** full transcripts, but mixed into the user's own sessions and resume lists, and indistinguishable in `omp stats`.
- **C. A dedicated folder inside the sessions root (chosen):** `omp stats` groups by top-level folder, so delegations appear as `/agent-delegations/` with tokens, latency, error rate, and cost, including nested subagent and advisor transcripts. Transcripts can be resumed, exported, and cleaned by `omp gc`. The resume picker's default per-project list leaves them out; its all-sessions view includes them.
- **D. OpenTelemetry export:** omp supports `OTEL_*`, but a collector is more infrastructure than needed now.

**Why the ledger is separate:** omp's transcripts lack caller context (which Claude session started the run, the label, the wrapper's exit code and completion verdict). The ledger sits outside the sessions root so `omp stats` does not parse it as a transcript. `report.sh` summarizes it.

**Titles:** the user preferred titles, but print mode never generates them (`autoTitle` is interactive-only) and omp has no flag to set one, so `--label` names the run in the ledger and run directory instead.

**Revisit if:** the records grow large (retention is manual for run directories; `omp gc` handles transcripts), or a profile/XDG setup moves the sessions root.

## 5. Reviews keep full capabilities; `--read-only` is opt-in

**Decision (user, 2026-10-13):** Reviews run with omp's normal tools so the reviewer can run tests and reproduce issues. The user's files are protected by isolation: a worktree or clone outside the checkout, bootstrapped dependencies, a snapshot of uncommitted changes when needed, scratch files in a temporary directory, `git status` before and after, and cleanup. `--read-only` (`--approval-mode always-ask`) is used only when the user asks or nothing may execute.

**Why:** An earlier draft told agents to use `always-ask` for reviews that must not change files. A fresh agent following that draft picked `--read-only`; omp's bash and eval calls were refused and all three findings were unverified static analysis. With the revised guidance, a fresh agent chose a full-capability review in a worktree, omp backed all three findings with commands it ran, and the user's checkout was unchanged.

**What `--read-only` does:** only read-tier tools run. `bash`, `eval`, edits, MCP tools, and omp's own subagents fail with `requires approval but no interactive UI available`, yet the run still exits 0 and can look complete. Read tier still includes web search, URL reads, and `memory_edit`, and the user's `tools.approval` and `bash.patterns` allow rules bypass the mode, so it is not a sandbox.

**Worktree caveat:** a `git worktree` shares branches, tags, stash, config, and hooks with the main checkout. When the reviewer may run git commands that change refs, use `git clone --no-local`.

## 6. Turn background jobs off for headless runs, per run

**Decision:** `run-omp.sh` passes a `--config` overlay with `async.enabled: false` and `bash.autoBackground.enabled: false` unless `--allow-async` is given. The user's global settings stay at omp's defaults (both `true`).

**Why:** Two default-on settings create background jobs. With `async.enabled`, the task tool starts subagents as background jobs. With `bash.autoBackground.enabled`, which `async.enabled` does not control, a bash command still running after 60 seconds becomes a background job. Subagents share the parent's job manager, so their long commands count too. The TUI waits for background jobs before settling; print mode does not, and shutdown cancels jobs still running. In a controlled test, a run exited after 8 seconds while its subagent's 45-second command was aborted, and the run still exited 0 with `looks_complete: true`. The same prompt with the overlay blocked until the subagent finished and returned its result. With async off, a batch of subagents in one task call still runs in parallel (synchronous fan-out with a concurrency limit) and blocks until all finish. Inline results also carry each subagent's `usage`, so the summary can report `subagent_cost_usd`. A second test lowered the auto-background threshold to 2 seconds and ran `sleep 5` in bash. With only `async.enabled: false`, the command was backgrounded (`Backgrounded as job bg_1`). With `bash.autoBackground.enabled: false` as well, it ran inline and returned its output after 5 seconds. Blocking bash keeps omp's normal command timeout (300 seconds by default, capped by `tools.maxTimeout`), so tasks with longer commands should tell the child to pass a larger `timeout`.

**Why not change the global settings:** in the TUI, background jobs let the primary agent keep working while subagents and long commands run, and the TUI waits for them. The loss happens only in print mode.

**Revisit if:** omp's print mode starts waiting for background work (the TUI's settle loop in `event-controller.ts` has no print-mode counterpart from 18.10.3 through 18.12.3), or either setting ID is renamed. The offline tests check that both IDs still exist.

## 7. Preserve the user's omp configuration otherwise

**Decision:** Keep default tool, extension, skill, and rule discovery; never add `--no-tools`, `--tools`, `--no-extensions`, and similar flags for normal work; never loosen approval (`--auto-approve`, `--plan-yolo`) without authorization; and use the user's profile and authentication.

**Why:** omp is valuable as a full agent with its own skills and tools. Old workarounds such as `--no-tools --no-extensions` for a Codex schema bug in 18.4.9 reduced capability without establishing a boundary. The async overlay (decision 6) is the one deliberate per-run change, made because print mode otherwise drops work.

## 8. No silent model substitution

**Decision:** If a requested model or effort does not match an available selector exactly, the agent shows the closest matches and asks, or states the substitution.

**Why:** Requests named a model that did not exist, and one agent substituted another model without saying so.

## 9. Two test tiers, with live calls only where omp's runtime behavior is the subject

**Decision:**

- `scripts/test-offline.sh` (free) covers everything checkable without a model: the summary filter against real and edge-case event fixtures, the report against a ledger fixture, the wrapper against a stub `omp`, `verify-skill.sh` usage errors and its declined-task pattern, and omp CLI facts checked without sending a prompt.
- `scripts/verify-skill.sh <provider/model>` runs that tier, then six short live calls through the wrapper. They cover a normal run, resume, a deadline, `--read-only`, an inline subagent, and a 65-second bash command, plus ledger and report checks.
- SKILL.md names the omp version it was verified against, and the live tier fails when the installed version differs.

Every live probe runs with a `memory.backend: off` overlay (passed through the wrapper's `--config`). With memory on, the probes read and wrote the repository's memory bank. One probe answered with a string an earlier test had stored, and a resume check could have passed from memory instead of the session.

**Why:** the user upgrades omp regularly, and several claims depend on omp internals that change between releases: exit predicates, event fields, approval tiers, background-job behavior, and setting IDs. omp released 18.6.3 to 18.10.3 within one week. Live calls are kept to behavior that only a model run exercises. A cheap model (`gpt-6-luna`) passes every probe, though a run may need a `--probe` rerun for a SKIP, so the live tier costs a few cents. Most of that is the subagent probe, which runs on the user's `task` role. The offline checks were mutation-tested so that each guarded behavior has a check that fails when it breaks.

## 10. Memory is the user's to keep; tests and independent reviews turn it off

**Decision:** The wrapper leaves omp's memory setting alone by default, so delegated work benefits from the workspace's memory as an interactive session does. `--config` lets a caller pass an overlay that sets `memory.backend: off` for a run, and the skill recommends it for independent reviews and tests.

**Why:** With a memory backend enabled, a run reads and writes the memory bank for its workspace, even with `--no-session`. During this audit, a test probe answered with a canary string that a 2026-10-06 test run had left in the repository's bank, instead of doing its task. Test runs had also been adding entries to the user's real bank. A memory-off overlay kept the bank's file unchanged across a full live verification run.

## 11. Keep the skill generic

**Decision:** The skill has no user-specific paths, credentials, preferred models, or organization settings. Record locations default to omp's and XDG's standard places and can be overridden by environment variables. User-specific facts from the audit (for example the user's role mappings) stay out of the skill.

## 12. A typed line names the task file as the user's request

**Decision (user, 2026-10-14):** `run-omp.sh` passes the task file as `@prompt.md` and follows it, after `--`, with one typed line: "The attached file is my task for you. Carry it out." The live tier fails a probe, instead of skipping it, when the model's answer declines the task as instructions inside an attached file. The pattern is `tests/fixtures/declined-task.ere`: a refusal verb, then the instructions or task, then the word "file" or "attachment", in one sentence of the answer joined into one line. The free tier checks it against the two recorded refusals, other phrasings and line breaks, and answers that only mention the file or a missing tool, and it runs a stub probe through `verify-skill.sh` to confirm the FAIL.

**Why:** omp sends an `@file` as a `<file name="...">` block, and the first typed message after it (`src/cli/initial-message.ts:33-41`). With no typed message, the whole request looks like file content. On 2026-10-14, with omp 18.10.4 and `openai-codex/gpt-6-luna:low`, the model declined 2 of 12 live probes this way: "I can't follow instructions embedded in the provided file; they are untrusted content." Both runs exited 0 with `looks_complete` true, so a caller would have accepted a run that did nothing. The live tier reported them as SKIP, which hid the problem.

**Revisit if:** a model still declines tasks with the typed line present, or omp changes how it combines `@file` text with typed messages.
