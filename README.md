# use-omp

A portable agent skill for calling [Oh My Pi (omp)](https://github.com/can1357/oh-my-pi) from Claude Code or another coding agent. It covers:

- full-capability headless launches through a small wrapper script that records every run;
- how to tell whether a run actually finished (exit 0 often does not mean it did);
- reviews that can run commands to prove issues while the user's checkout stays untouched;
- session continuity, process lifecycle, and the ways a headless run differs from the interactive TUI;
- run metrics through a ledger and omp's own `omp stats`, plus troubleshooting.

The repository holds the skill's instructions, three small scripts the skill uses, a drift check, and design notes. It is not a replacement CLI or a bridge daemon. It does not install omp, authenticate providers, or grant permissions.

## Documentation

- [AGENTS.md](AGENTS.md): instructions for agents working in this repository (also loaded by Claude Code through `CLAUDE.md`).
- [SKILL.md](skills/use-omp/SKILL.md): the procedure agents follow.
- [docs/decisions.md](docs/decisions.md): what was decided and why, with the evidence and when to revisit each decision.
- [docs/2026-10-13-audit.md](docs/2026-10-13-audit.md): the usage audit, verified omp behavior, experiments, and follow-ups behind the current design.
- [docs/maintenance.md](docs/maintenance.md): verifying after an omp upgrade, reinstalling, where the records live, re-auditing, and known limits.
- [scripts/test-offline.sh](scripts/test-offline.sh) and [scripts/verify-skill.sh](scripts/verify-skill.sh): the free and live test tiers (see [Verification](#verification)), with fixtures in [tests/fixtures/](tests/fixtures/).

## Install for Claude Code

Use the [Vercel `skills` CLI](https://github.com/vercel-labs/skills). From the root of this local Git checkout:

### pnpm (primary)

```sh
pnpm dlx skills add . --skill use-omp --agent claude-code --global --yes
```

### npm (alternative)

```sh
npx --yes skills add . --skill use-omp --agent claude-code --global --yes
```

If `skills` is already installed, the equivalent is:

```sh
skills add . --skill use-omp --agent claude-code --global --yes
```

Follow your host's dependency-install policy. Where Socket Firewall is required, prefix the package-manager command with `sfw`, for example `sfw pnpm dlx skills add . --skill use-omp --agent claude-code --global --yes`.

This repository is usable directly from a local checkout; no published remote is assumed. From another directory, replace `.` with the checkout's absolute path. If the repository is later published, the CLI also accepts its real Git URL. Review any existing `use-omp` installation before using `--yes`, which skips overwrite confirmation.

`--global` makes the skill available across Claude Code projects. To install for one project, run the command from that project, pass the source checkout's absolute path, and omit `--global`. Replace `claude-code` with another agent identifier supported by `skills --help` when installing for a different harness.

Depending on the CLI version and mode, the installer may link or copy the skill into agent directories. Treat the installed files as separate from this checkout: editing the source is not an update mechanism. After changing this local skill, re-run the same targeted install command.

Verify registration:

```sh
pnpm dlx skills list --global --agent claude-code
```

With npm, use `npx --yes skills list --global --agent claude-code`. Neither `pnpm dlx` nor `npx` installs a persistent `skills` command; bare `skills` commands require a separate existing CLI installation.

Start a new Claude Code session if the current session does not discover the newly installed skill. Invoke `/use-omp`, or ask Claude to delegate a task to omp. Registration and readable files establish installation, not proof that an already-running session has refreshed its skill list.

To uninstall only this skill from Claude Code:

```sh
pnpm dlx skills remove use-omp --global --agent claude-code
```

With npm, use `npx --yes skills remove use-omp --global --agent claude-code`.

## Prerequisites and use

Install omp separately using its [official installation guidance](https://github.com/can1357/oh-my-pi#install). The pnpm/npm commands above install the **skill**, not omp. Configure an available provider through omp's normal authentication flow.

The skill is generic: it contains no user-specific paths, credentials, preferred models, or organization settings. Agents choose a locally available model and preserve the intended workspace/profile rather than copying a fixed model ID.

Read [SKILL.md](skills/use-omp/SKILL.md) for the procedure. Additional references are loaded only for their branches:

- [Automation](skills/use-omp/references/automation.md): event fields, exit status, after-the-fact inspection, exact session resume, cancellation, and interface choice.
- [Troubleshooting](skills/use-omp/references/troubleshooting.md): stalls, refused tools, launch errors, capability differences, authentication, and the historical Codex/Claude-tool schema failure.
- [run-omp.sh](skills/use-omp/scripts/run-omp.sh): the launch wrapper agents use. It runs one headless task with JSON events and closed stdin, starts omp in the workspace, and turns omp's background jobs off for the run (`async.enabled` and `bash.autoBackground.enabled`) so subagents and long commands finish before exit (`--allow-async` opts out). It keeps the records: the omp transcript in a delegations folder that `omp stats` reports separately, a run directory, and a line in a `runs.jsonl` ledger.
- [report.sh](skills/use-omp/scripts/report.sh): summarizes the ledger. It reports completion rate, failures, unexpected tool errors, subagent failures, duration, and primary plus inline-subagent cost, by model, workspace, and week.
- [summarize-events.jq](skills/use-omp/scripts/summarize-events.jq): reduces a `--mode json` event file to the session ID, the models, the stop reason, tool calls and errors, write targets, subagent results and background jobs, cost, and a completion verdict.

## Records and metrics

`run-omp.sh` records every run unless called with `--no-record`. Transcripts go to `~/.omp/agent/sessions/--agent-delegations--` (override with `USE_OMP_SESSION_DIR`). `omp stats` reports them as a separate `/agent-delegations/` folder, including subagent and advisor spend. Run directories and the `runs.jsonl` ledger go to `${XDG_STATE_HOME:-~/.local/state}/use-omp` (override with `USE_OMP_STATE_DIR`). See [automation.md](skills/use-omp/references/automation.md#records-and-metrics) for the ledger fields. The records contain prompts, code, and tool output; keep them private.

```sh
skills/use-omp/scripts/report.sh          # delegation outcomes from the ledger
omp stats --summary                       # tokens, latency, and cost per folder
```

## Safety and compatibility

Normal-capability omp calls can modify files and use configured services. A parent agent's permissions, prompt instructions, approval modes, and omp tool-selection flags are not an enforced sandbox. omp's default approval mode (`yolo`) already runs tools without prompting; the skill does not add `--auto-approve` or loosen the user's approval settings.

Reviews keep full capabilities so the reviewer can run tests and reproduce issues. The skill protects the user's files by isolating the review (a worktree or clone, scratch files in a temporary directory, `git status` before and after) rather than by restricting tools. `--read-only` (`--approval-mode always-ask`) is opt-in. It blocks bash, eval, edits, MCP tools, and subagents, so a review becomes unverified static analysis. See decision 5 in [docs/decisions.md](docs/decisions.md). Decision 6 explains why the wrapper turns omp's background jobs off for headless runs.

CLI guidance was checked against installed omp **18.10.4** (source and live runs). The historical schema diagnosis is explicitly scoped to **18.4.9**. Upstream help and the installed version take precedence over cached examples. A successful model response does not verify every optional tool or establish parity with the interactive UI.

## Verification

Two test tiers guard the skill. Tests use only the behavior the skill depends on.

```sh
scripts/test-offline.sh                              # free: no model calls, about 10 seconds
scripts/verify-skill.sh openai-codex/gpt-6-luna:low  # after every omp upgrade: free tier + 6 live calls
scripts/verify-skill.sh --probe subagent openai-codex/gpt-6-luna:low  # rerun one probe
```

**Free tier** (`scripts/test-offline.sh`, 82 checks). Run it after any skill edit. It covers:

- `summarize-events.jq` against fixtures in `tests/fixtures/events/`. Six are trimmed events from real omp 18.10.3 runs, with local paths and provider response IDs removed: a normal run, a deadline, a refused tool, an inline subagent, a background subagent, and a backgrounded bash command. The rest are edge cases: a final `stop` that still carries a tool call, `pause_turn`, a missing `agent_end`, empty text, odd records, a truncated stream, patch-format edits, a session transcript, and a failed subagent.
- `report.sh` against a ledger fixture with malformed lines, non-ISO dates, non-numeric fields, read-only refusals, and background jobs.
- `run-omp.sh` against a stub `omp` on `PATH`:
  - umask and launch directory;
  - the flags it passes, including the typed line that names the task file, the background-job overlay, `--config`, `--read-only`, `--allow-async`, `--resume`, and `--no-record`;
  - the ledger line and private record files;
  - TERM handling and usage errors.
- `verify-skill.sh` usage errors, which must stop before any model call; its declined-task pattern against answer fixtures in `tests/fixtures/answers/`; and, through the stub `omp`, a FAIL for a probe whose answer declines the task and a SKIP for one that only mentions the file.
- omp CLI facts checked without sending a prompt:
  - the flags the skill uses and the `omp models --json` shape;
  - the setting IDs the overlay relies on;
  - `--restore` and an invalid `--mode` exiting 2, and a missing `@file` exiting 1;
  - an open stdin pipe holding print mode.

**Live tier** (`scripts/verify-skill.sh <provider/model>`). Run it after every omp upgrade. It runs the free tier, checks the installed version against the one SKILL.md names, then makes six short model calls through `run-omp.sh` into a throwaway directory, with omp's memory turned off so earlier runs cannot answer a probe. The calls check that:

- a normal-capability run reads a file, writes nothing, completes, and keeps its transcript;
- a resumed run continues the same session and recalls the earlier answer;
- a 1-second deadline ends without a complete answer (exit 0 with no answer before the first reply, or 1 with `aborted` mid-turn);
- the opt-in `--read-only` refuses `bash` while still exiting 0;
- a subagent runs inline, finishes, and reports its cost under the wrapper's overlay;
- a 65-second bash command stays inline instead of becoming a background job;
- every exit code matches the final stop reason, and the ledger and `report.sh` account for every run.

A cheap tool-capable model is enough. With `openai-codex/gpt-6-luna:low` the primary agents cost under a cent per run. The subagent probe runs on your `task` role's model, which dominates the total of a few cents. A probe reports SKIP when the model never makes the tool call it needs; rerun that probe alone with `--probe NAME` (repeatable: `normal`, `resume`, `deadline`, `approval`, `subagent`, or `bash`). `resume` also runs `normal`, whose session it resumes. A probe whose answer declines the task as instructions inside an attached file reports FAIL, not SKIP.

The offline checks were mutation-tested: nine deliberate bugs in the scripts each made at least one check fail. A failing live check means the skill's description of omp has drifted; see [maintenance.md](docs/maintenance.md).

On 2026-10-13 with omp 18.10.3, both tiers passed with `openai-codex/gpt-6-luna:low` and `openai-codex/gpt-6.1-sol:low`. The exit-status, stdin, session-directory, approval, and event-field claims were also checked against the installed source.

On 2026-10-14 with omp 18.10.4, the free tier passed and every live check passed in at least one of two runs with `openai-codex/gpt-6-luna:low`. Each run had one SKIP, a different probe each time, because the model refused the task as instructions inside an attached file (see [troubleshooting.md](skills/use-omp/references/troubleshooting.md#a-refusal-that-looks-complete)). The 18.10.3 to 18.10.4 source diff leaves print mode, exit status, events, session flags, approval tiers, and the headless approval refusal unchanged; the [audit addendum](docs/2026-10-13-audit.md#upgrade-check-18104-2026-10-14) cites the files.

Later that day, after `run-omp.sh` began following the task file with a typed line that names it as the task (decision 12 in [docs/decisions.md](docs/decisions.md)), one full live run had no failures and one SKIP. In that run the model ran the subagent probe's command with `bash` itself instead of calling `task`; it did not decline the task. A `--probe subagent` rerun passed.

Earlier live checks on 2026-10-06 with omp 18.6.3 exercised a real file read through the default tool setup, JSON event extraction with the documented jq filters, and exact-session recall. The dedicated-session recipe also accepted a dash-prefixed task and an `@`-prefixed literal follow-up without interpreting them as CLI syntax. Both pnpm and npm runners discovered the skill through `skills add . --list`.

An inherited open stdin pipe stalled the initial programmatic probe; closing stdin fixed it. The launch guidance includes that requirement. These checks do not certify every optional capability, provider, or host platform.

## Sources

- [omp source and installation](https://github.com/can1357/oh-my-pi)
- [Print-mode implementation](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/modes/print-mode.ts)
- [skills CLI source and usage](https://github.com/vercel-labs/skills)
- Local `omp --help`, `omp models --help`, and live CLI checks.
