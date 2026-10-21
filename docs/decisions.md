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

**Update (2026-10-21): progress events are dropped after each run.** The "records grow large" trigger fired: about a week of regular use left close to a gigabyte of run directories. Most of those bytes were `tool_execution_update`, `message_update`, and `tool_stream_update` events. They repeat partial tool output and message deltas, and nothing in the skill reads them: `summarize-events.jq` and `answer.md` use `message_end`, `tool_execution_start`, and `tool_execution_end`. The wrapper removes them once omp exits, so a stall is still visible while the run is live. Every event line starts with its `type`, which the filter relies on. Retention of the remaining records is still manual.

**Revisit if:** the records grow large again (retention is manual for run directories; `omp gc` handles transcripts), or a profile/XDG setup moves the sessions root.

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

**Why:** omp is valuable as a full agent with its own skills and tools. Old workarounds such as `--no-tools --no-extensions` for a Codex schema bug in 18.4.9 reduced capability without establishing a boundary. The wrapper's overlay makes the only deliberate per-run changes: background jobs off (decision 6), because print mode otherwise drops work, and memory off (decision 10), because delegated runs are mostly independent second opinions. `--allow-async` and `--memory` undo them.

## 8. No silent model substitution

**Decision:** If a requested model or effort does not match an available selector exactly, the agent shows the closest matches and asks, or states the substitution.

**Why:** Requests named a model that did not exist, and one agent substituted another model without saying so. Decision 13 extends this to bare model IDs that several providers offer: the wrapper refuses to guess when the user's provider order does not decide.

## 9. Two test tiers, with live calls only where omp's runtime behavior is the subject

**Decision:**

- `scripts/test-offline.sh` (free) covers everything checkable without a model: the summary filter against real and edge-case event fixtures, the report against a ledger fixture, the wrapper against a stub `omp`, `verify-skill.sh` usage errors and its declined-task pattern, and omp CLI facts checked without sending a prompt.
- `scripts/verify-skill.sh <provider/model>` runs that tier, then six short live calls through the wrapper. They cover a normal run, resume, a deadline, `--read-only`, an inline subagent, and a 65-second bash command, plus ledger and report checks.
- SKILL.md names the omp version it was verified against, and the live tier fails when the installed version differs.

Every live probe runs with memory off, which is now the wrapper's default (decision 10), and the live tier checks the ledger's `memory_off` for each run. With memory on, the probes read and wrote the repository's memory bank. One probe answered with a string an earlier test had stored, and a resume check could have passed from memory instead of the session.

**Why:** the user upgrades omp regularly, and several claims depend on omp internals that change between releases: exit predicates, event fields, approval tiers, background-job behavior, and setting IDs. omp released 18.6.3 to 18.10.3 within one week. Live calls are kept to behavior that only a model run exercises. A cheap model (`gpt-6-luna`) passes every probe, though a run may need a `--probe` rerun for a SKIP, so the live tier costs a few cents. Most of that is the subagent probe, which runs on the user's `task` role. The offline checks were mutation-tested so that each guarded behavior has a check that fails when it breaks.

## 10. Memory is off for delegated runs; `--memory` opts in

**Decision (user, 2026-10-21; reverses the 2026-10-13 version):** The wrapper's overlay sets `memory.backend: off` for every run. `--memory` leaves the user's memory setting in force. The ledger records `memory_off` for each run. A caller's `--config` overlay merges after the wrapper's and wins.

**The earlier decision** left memory on by default, so delegated work would benefit from the workspace's memory as an interactive session does, and recommended a memory-off overlay for independent reviews and tests.

**Why it changed:**

- Callers turned memory off almost every time. In nearly every recorded run, the caller wrote its own memory-off overlay, under several different file names.
- The skill's main use is an independent second opinion, and recalled memory biases one. With a memory backend enabled, a run reads and writes the bank that `mnemopi.scoping` selects, even with `--no-session`. During the 2026-10-13 audit, a test probe answered with a canary string an earlier test run had left in the bank instead of doing its task, and test runs had been adding entries to the user's real bank.
- Scoping makes memory-on hard to predict for other users. `per-project-tagged` also recalls from a shared bank, and `global` shares one bank across projects. A public skill cannot know which a user has.
- With memory off, the result no longer depends on what the bank happens to hold.

**Costs accepted:** headless runs now differ from interactive sessions in one more way, which decision 7 otherwise avoids. Implementation tasks lose what omp has learned about a repository unless the caller passes `--memory` or puts the context in the task. Delegated work is not remembered by the user's later omp sessions.

**Revisit if:** delegations shift from consultations to implementation work where callers routinely pass `--memory`, or omp gains a way to read a bank without writing to it.

## 11. Keep the skill generic

**Decision:** The skill has no user-specific paths, credentials, preferred models, or organization settings. Record locations default to omp's and XDG's standard places and can be overridden by environment variables. User-specific facts from the audit (for example the user's role mappings) stay out of the skill.

## 12. A typed line names the task file as the user's request

**Decision (user, 2026-10-14):** `run-omp.sh` passes the task file as `@prompt.md` and follows it, after `--`, with one typed line: "The attached file is my task for you. Carry it out." The live tier fails a probe, instead of skipping it, when the model's answer declines the task as instructions inside an attached file. The pattern is `tests/fixtures/declined-task.ere`: a refusal verb, then the instructions or task, then the word "file" or "attachment", in one sentence of the answer joined into one line. The free tier checks it against the two recorded refusals, other phrasings and line breaks, and answers that only mention the file or a missing tool, and it runs a stub probe through `verify-skill.sh` to confirm the FAIL.

**Why:** omp sends an `@file` as a `<file name="...">` block, and the first typed message after it (`src/cli/initial-message.ts:33-41`). With no typed message, the whole request looks like file content. On 2026-10-14, with omp 18.10.4 and `openai-codex/gpt-6-luna:low`, the model declined 2 of 12 live probes this way: "I can't follow instructions embedded in the provided file; they are untrusted content." Both runs exited 0 with `looks_complete` true, so a caller would have accepted a run that did nothing. The live tier reported them as SKIP, which hid the problem.

**Revisit if:** a model still declines tasks with the typed line present, or omp changes how it combines `@file` text with typed messages.

## 13. Model selection: an optional default, and bare IDs resolved by the user's provider order

**Decision (user, 2026-10-21):** `--model` is optional. Without it, the wrapper uses `USE_OMP_MODEL`, then omp's `default` role. A bare model ID that several providers offer resolves by omp's `modelProviderOrder` setting, matched case-insensitively. If the order names none of the candidates, or the ID is unknown, the wrapper exits 2 and names the candidates or similar selectors. A `provider/model` selector and an omp role name (`slow`, `@slow`) pass through unchanged. As in omp, IDs match case-insensitively and an exact ID wins over a role of the same name. The lookups run in the workspace with the caller's `--config` overlays, so they read the same settings as the run. The ledger records the final message's model, the request as given, and its source.

**Why:**

- Requests usually name a model without a provider, and the same ID often exists under two or three providers. In several sessions, the agent ran a provider the user had not asked for. It took the first `omp models` entry, and the catalog lists one subscription provider before the other. The user then had to say which provider to use.
- Passing the bare ID to omp does not fix this. omp ranks candidates by recent use before `modelProviderOrder` (`config/model-resolver.ts:590-611`, omp 18.12.3), so a provider the user tried once can win.
- Users also repeated the same model and effort on most requests, and omp's own `default` role often differs from what they want for delegations. Nearly all recorded runs used one effort, while the user's interactive default was another. `USE_OMP_MODEL` holds a delegation default without editing omp's roles.
- An exit 2 with candidates, instead of a guess, keeps decision 8. The preference lives in the user's omp config and environment, so the skill stays generic (decision 11).

**Revisit if:** omp's resolver stops ranking recent use first, or `omp models --json` drops `id`. The free tier checks the `id` field and that `modelProviderOrder` and `modelRoles` print JSON.

## 14. The hand-back leaves out cost

**Decision (user, 2026-10-21):** SKILL.md no longer asks agents to report a run's cost. The summary, ledger, `report.sh`, and `omp stats` keep the figures, labeled as estimates.

**Why:** the user did not want cost in replies. The figures are omp's estimates at list prices (`omp models --json` `cost`). Subscription providers bill by plan usage, so a run's dollar figure is not money spent, and a week's total can look alarming while costing nothing extra.

## 15. Consulting unprompted is opt-in

**Decision (user, 2026-10-21):** The skill's description names both explicit requests and high-stakes checkpoints: a plan before implementation, a hard-to-reverse decision, or a conclusion others will rely on. The body lets an agent consult on its own initiative only when the user's instructions or memory ask for it. Otherwise the agent offers in one line. It consults once per checkpoint, says what it is consulting on and with which model before it launches, and skips routine work.

**Why:** the user wants second opinions at important junctions without one at every step. A public skill that consulted unprompted would spend every user's plan usage without asking. The user's own instructions are the right place for frequency and model rules, and they can change without a skill release. Usage showed the skill loads reliably when asked: in most sessions the model chose the skill itself after the user mentioned omp or the skill mid-sentence. A search of recent sessions found no typed request to consult another model that went without the skill.

**Revisit if:** agents consult too often or too rarely under users' instructions, or users ask for a built-in default frequency.

## 16. Tool errors are informational; unexpected refusals are problems

**Decision:** `report.sh` counts runs with tool errors but no longer lists them as problems. It lists runs that did not complete, exited nonzero, had approval refusals outside `--read-only`, had subagent failures, or left background jobs. SKILL.md tells agents that most tool errors are the child's own failed commands.

**Why:** about half of the recorded runs had tool errors, and a sample showed nearly all were ordinary: a test or command exiting 1, a path that did not exist, a script traceback. Listing them buried the real problems: the most recent "problems" were all of this kind, while a failed launch and a run whose subagents failed were easy to miss.
