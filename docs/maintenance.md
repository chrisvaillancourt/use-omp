# Maintaining use-omp

## After editing the skill or upgrading omp

1. Run the tests. After a skill edit, the free tier is usually enough. After an omp upgrade, run the live tier, which runs the free tier first:

   ```sh
   scripts/test-offline.sh                              # free, about 10 seconds
   scripts/verify-skill.sh openai-codex/gpt-6-luna:low  # six live calls, a few cents
   scripts/verify-skill.sh --probe bash openai-codex/gpt-6-luna:low  # one probe, to rerun a SKIP
   ```

   The live tier records into a throwaway directory, not your ledger or `omp stats`. Every check prints PASS, FAIL, or SKIP. A SKIP means the model never made the tool call a probe needed; rerun that probe alone with `--probe NAME` (`resume` also runs `normal`). A FAIL that says the model declined the task as an attached file's instructions means the typed task line stopped working (see [decision 12](decisions.md#12-a-typed-line-names-the-task-file-as-the-users-request)). Artifacts stay in the printed work directory.
2. A failed version check alone means omp changed. Read the installed changelog (`"$(dirname "$(realpath "$(command -v omp)")")/../CHANGELOG.md"`) for print mode, events, sessions, approval, task, and async. Re-verify the affected claims. Then update the version in SKILL.md ("last verified against omp **x.y.z**") and in the README.
3. Any other FAIL means a documented behavior drifted. Fix the skill text, the scripts, or both, and record the change in [decisions.md](decisions.md) if it changes a decision.
4. Reinstall the skill. Installed copies don't follow this checkout:

   ```sh
   pnpm dlx skills add . --skill use-omp --agent claude-code --global --yes
   ```

   Start a new Claude Code session to pick it up.

## Adding or changing tests

- Add a test only for behavior the skill documents or the scripts implement. The README's Verification section lists what each tier covers.
- Keep live probes isolated: they run with the `memory.backend: off` overlay and throwaway record directories, so they neither read the user's memory or ledger nor add to them.
- Prefer the free tier. Use a fixture for event-parsing behavior, the stub `omp` for wrapper behavior, and a no-prompt CLI call for omp facts. Add a live call only when the behavior depends on what omp does during a model run.
- The declined-task pattern lives in `tests/fixtures/declined-task.ere`, one extended regular expression per line. When a model declines a task in a new way, add its answer as `tests/fixtures/answers/declined-*.md`; add answers that must stay SKIP as `skip-*.md`.
- Build event fixtures from a real run's `events.jsonl`. Drop `message_update`, `tool_execution_update`, and `tool_stream_update` records, strip signature or encrypted fields, and replace local paths with neutral ones such as `/work` and `/tmp`. Then confirm that the summary is unchanged.
- To check that a new test can fail, break the code it guards in a copy of the working tree (`rsync -a --exclude .git ./ <scratch>/`) and confirm the test fails there.

## Where the records are

| What | Default location | Override |
|---|---|---|
| omp transcripts of delegated runs | `~/.omp/agent/sessions/--agent-delegations--/` | `USE_OMP_SESSION_DIR` |
| Run directories (prompt, events, stderr, exit, summary, answer) | `~/.local/state/use-omp/runs/` | `USE_OMP_STATE_DIR` |
| Ledger, one JSON line per run | `~/.local/state/use-omp/runs.jsonl` | `USE_OMP_STATE_DIR` |

Read the metrics:

```sh
skills/use-omp/scripts/report.sh [--since YYYY-MM-DD] [--json]
omp stats --summary          # or `omp stats` for the dashboard; see the /agent-delegations/ folder
```

`report.sh` covers delegation outcomes: completion rate, nonzero exits, unexpected tool errors, subagent failures, duration, and primary plus inline-subagent cost. `omp stats` covers tokens, latency, error rate, and total cost, including background subagents and the advisor.

Retention is manual. Delete old run directories when you no longer need them; `omp gc --archive` archives cold transcripts, which can leave older ledger `session_file` paths stale. `omp gc --compress` (omp 18.10.4 and later, APFS or NTFS) compresses idle transcripts in place and keeps those paths valid; on 18.10.4 it can exit 1 when a session holds a pretty-printed JSON artifact over 1 MiB ([can1357/oh-my-pi#15745](https://github.com/can1357/oh-my-pi/issues/15745)). Records hold prompts, source code, and tool output, so keep them private.

## Re-auditing usage

The ledger answers most questions directly. For runs launched without the wrapper, or to study how agents used the skill:

- Search Claude Code transcripts (`~/.claude/projects/*/*.jsonl`) for `"skill":"use-omp"`, `omp -p`, and `run-omp.sh`. Each ledger line's `caller.claude_session_id` links a run to its Claude session.
- Look for runs without `--mode json`, `--no-session` launches, retries after failures, the user correcting a model name, and refused launches.
- Repeat the cold-start test from the [audit](2026-10-13-audit.md#method): give a fresh agent only SKILL.md and a realistic task, with `USE_OMP_STATE_DIR` and `USE_OMP_SESSION_DIR` pointed at a scratch directory, and ask for a friction log.

## Known limits

- `looks_complete` is a heuristic. It cannot tell whether the answer is right, or whether the child declined the task; check the evidence.
- `write_targets` misses files changed through `bash`. `git status` is the authority.
- With `--allow-async` or a direct launch without the overlay, background subagents and long bash commands can be cancelled at exit, and background subagent spend is not in the summary.
- The overlay depends on the setting IDs `async.enabled` and `bash.autoBackground.enabled`. The offline tests fail if omp renames either, and the live tier's subagent and 65-second bash probes check that both still take effect.
- With the overlay, every bash command runs inline under omp's tool timeout (300 seconds by default, capped by `tools.maxTimeout`). Tasks with longer commands should tell the child to pass a larger `timeout` to bash.
- The wrapper cannot forward INT when it was started as a background job; cancel with TERM.
- omp's logs do not list the loaded skills, tools, or extensions. To check a capability, ask the child and confirm with a tool call in the events.
- The skill was verified on macOS with zsh and bash 3.2 tooling. The scripts avoid GNU-only flags, but Linux has not been exercised.
