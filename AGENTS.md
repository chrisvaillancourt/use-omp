# AGENTS.md

This repository is the `use-omp` agent skill: instructions and small scripts that let a coding agent (mainly Claude Code) delegate work to omp (Oh My Pi) headlessly, record each run, and judge whether it finished. Read this file first, then open only the documents your task needs.

## Contents

- [Where to look](#where-to-look)
- [Repository map](#repository-map)
- [Rules](#rules)
- [Before you finish](#before-you-finish)

## Where to look

| Task | Read |
|---|---|
| Understand what the skill tells agents to do | [skills/use-omp/SKILL.md](skills/use-omp/SKILL.md) |
| Change launch, recording, events, or exit-status behavior | [references/automation.md](skills/use-omp/references/automation.md), then the script in `skills/use-omp/scripts/` |
| Diagnose a failing or odd omp run | [references/troubleshooting.md](skills/use-omp/references/troubleshooting.md) |
| Know why something is the way it is, before changing it | [docs/decisions.md](docs/decisions.md) |
| See the evidence behind the current design (usage, verified omp behavior, experiments) | [docs/2026-10-13-audit.md](docs/2026-10-13-audit.md) |
| Handle an omp upgrade, add tests, reinstall, re-audit, or find the records | [docs/maintenance.md](docs/maintenance.md) |
| Install instructions, what each test tier covers | [README.md](README.md) |

## Repository map

```text
skills/use-omp/            the installed skill (SKILL.md, references/, scripts/)
  scripts/run-omp.sh       launch one headless omp task and record it
  scripts/summarize-events.jq   run summary and completion verdict from --mode json events
  scripts/report.sh        metrics from the run ledger
scripts/test-offline.sh    free test tier: no model calls, about 10 s
scripts/verify-skill.sh    live tier: free tier plus six short model calls
tests/fixtures/            event, ledger, and answer fixtures, and the declined-task pattern
docs/                      decisions, audit, maintenance
```

## Rules

- **The installed copy is separate.** `~/.claude/skills/use-omp` is a copy made by `pnpm dlx skills add`. Editing this checkout does not change it. Ask the user before reinstalling or merging.
- **Verify omp claims at the source.** Check behavior against the installed omp (`realpath "$(command -v omp)"` leads to the package; its TypeScript source ships in `src/`) or a live run, and cite `file:line`. SKILL.md names the omp version it was verified against; update it only after the live tier passes on the new version.
- **Don't reverse a decision silently.** If a change contradicts [docs/decisions.md](docs/decisions.md), raise it with the user first. Record new or changed decisions there, with evidence and a revisit trigger.
- **Keep the skill generic and publishable.** No personal paths, account names, emails, org names, ticket keys, or preferred models in the skill, docs, or fixtures. The free tier's privacy scan enforces part of this.
- **Reviews keep full capabilities.** When delegating a review to omp, isolate the checkout (worktree or clone) instead of restricting tools. `--read-only` is opt-in ([decision 5](docs/decisions.md)).
- **Live calls cost money and touch real state.** The live tier makes six model calls and writes only to throwaway records with omp's memory off. Any other live omp run in this repo writes to the user's ledger, `omp stats`, and the repo's memory bank unless you pass `USE_OMP_STATE_DIR`, `USE_OMP_SESSION_DIR`, and a memory-off `--config` overlay. Prefer fixtures and the stub `omp` (see [maintenance.md](docs/maintenance.md#adding-or-changing-tests)).
- **Update every reference when a value changes.** That covers check counts, versions, flags, defaults, and costs in README.md, the docs, SKILL.md, and script help text.
- **Shell portability.** Scripts run under macOS `/bin/bash` 3.2 with `set -u`. Avoid GNU-only flags and `timeout`, and use the `${arr[@]+"${arr[@]}"}` idiom for possibly empty arrays.

## Before you finish

1. Run `scripts/test-offline.sh`. All checks must pass.
2. After an omp upgrade, or a change to omp-facing behavior, run `scripts/verify-skill.sh openai-codex/gpt-6-luna:low` (or another cheap tool-capable model). Rerun a SKIP with `--probe NAME`.
3. Update the docs that describe what you changed (see the table above).
4. Commit with Conventional Commits (`feat(skill):`, `fix(skill):`, `docs:`, `test:`). Explain why in the body, and leave out tool attribution.
