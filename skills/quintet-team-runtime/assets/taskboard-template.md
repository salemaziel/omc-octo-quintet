# Taskboard — <team-name>

Goal: <one-line shared goal>
Launched: <ISO-8601 timestamp>

## Workers

| Worker      | Provider | Owns (files/dir)        | Status |
| ----------- | -------- | ----------------------- | ------ |
| w1-codex    | codex    | src/<module>/           | …      |
| w2-codex    | codex    | tests/<module>/         | …      |
| w3-gemini   | gemini   | docs/<page>.md          | …      |
| w4-qwen     | qwen     | (read-only audit)       | …      |

## Progress log

Workers append one line per meaningful step, then a final DONE.

```
[w1-codex] <what changed, where>
[w2-codex] <what changed, where>
[w3-gemini] <what changed, where>
[w4-qwen] <finding or note>
[w1-codex] DONE
```

## Orchestrator verification checklist

Do NOT trust a DONE line until each box is confirmed against real artifacts:

- [ ] w1 — files exist and compile/lint
- [ ] w2 — tests present AND passing (run them yourself)
- [ ] w3 — docs render / links resolve
- [ ] w4 — audit findings triaged (fixed, filed, or accepted)
- [ ] no two workers edited the same path (no clobbering)

Only after every box is checked: `quintet team shutdown <team-name>`.
