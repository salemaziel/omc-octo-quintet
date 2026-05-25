# Fleet modes & reliability

Detailed reference for one-shot fleet dispatch. SKILL.md keeps the commands and the synthesis duty inline; this file holds per-mode mechanics and reliability behavior.

## What each mode does

- **consult / fleet** — independent answers, printed side by side under per-provider headers with a status tag (`[0:ok]` or `[code:class]`). `fleet` and `consult` are the same fan-out.
- **debate** — Round 1: independent positions. Round 2: each provider is shown the others' answers and asked to critique and refine. Two full fan-outs.
- **review** — wraps the target (a diff, file contents, or description) in a severity-ranked code-review prompt before fanning out.

`[providers]` defaults to `all`; pass a comma list to narrow.

## Reliability behavior to expect

- A provider with `auth=none` or an open circuit breaker is silently skipped — `doctor` first so you know who's in the pool.
- If a provider fails transiently, you'll see a `falling back → <other>` log line and the fallback's answer appended. That's expected, not an error.
- Tune timeouts via `QUINTET_<PROVIDER>_TIMEOUT` (seconds) or the global `QUINTET_TIMEOUT`.

## No providers ready

If `doctor` shows **zero** ready providers (all `auth=none` / missing), fleet has nothing to fan out to and will exit without answers. Do not retry blindly — tell the user which CLIs need authenticating (commonly `qwen`, which needs one interactive `qwen` run to trigger OAuth) and stop until at least one provider is ready.

## When NOT to use fleet

- For *doing* multi-file work in parallel, use **team mode** (`quintet-team-runtime`) — fleet is read/advisory and one-shot; it does not maintain a working session or coordinate file edits.
- For a single model, just call that CLI directly; fleet's value is breadth + reliability across several.
