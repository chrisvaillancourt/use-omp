# use-omp

A portable agent skill for calling [Oh My Pi (omp)](https://github.com/can1357/oh-my-pi) from Claude Code or another coding agent. It covers normal-capability headless launches, task boundaries, session continuity, JSON output, process lifecycle, and troubleshooting.

This repository contains instructions, not a replacement CLI or a bridge daemon. It does not install omp, authenticate providers, or grant permissions.

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

- [Automation](skills/use-omp/references/automation.md): event parsing, exact session resume, cancellation, and interface choice.
- [Troubleshooting](skills/use-omp/references/troubleshooting.md): capability differences, authentication, and the historical Codex/Claude-tool schema failure.

## Safety and compatibility

Normal-capability omp calls can modify files and use configured services. A parent agent's permissions, prompt instructions, or omp tool-selection flags are not an enforced sandbox. Automatic approval is not enabled by this skill.

CLI guidance was checked against installed omp **18.6.3**. The historical schema diagnosis is explicitly scoped to **18.4.9**. Upstream help and the installed version take precedence over cached examples. A successful model response does not verify every optional tool or establish parity with the interactive UI.

## Verification

Live checks on 2026-10-06 with omp 18.6.3 exercised a real file read through the default tool setup, JSON event extraction with the documented jq filters, and exact-session recall. The dedicated-session recipe also accepted a dash-prefixed task and an `@`-prefixed literal follow-up without interpreting them as CLI syntax. Both pnpm and npm runners discovered the skill through `skills add . --list`.

An inherited open stdin pipe stalled the initial programmatic probe; closing stdin fixed it. The launch guidance includes that requirement. These checks do not certify every optional capability, provider, or host platform.

## Sources

- [omp source and installation](https://github.com/can1357/oh-my-pi)
- [Print-mode implementation](https://github.com/can1357/oh-my-pi/blob/main/packages/coding-agent/src/modes/print-mode.ts)
- [skills CLI source and usage](https://github.com/vercel-labs/skills)
- Local `omp --help`, `omp models --help`, and live CLI checks.
