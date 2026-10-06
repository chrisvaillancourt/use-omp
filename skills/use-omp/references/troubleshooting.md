# Troubleshooting omp calls

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
