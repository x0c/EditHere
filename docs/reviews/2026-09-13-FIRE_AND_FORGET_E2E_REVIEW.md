# Fire-and-forget end-to-end review (2026-09-13)

Reviewed revision: `76550cc`. Scope: live loop under [first-release fire-and-forget](../PRODUCT_KNOWLEDGE_BASE.md#first-execution-release-scope). Product source was not modified by this review.

**Ruling (same day):** this review was not empty. The first user-facing summary led with “partial / not proven” and hid the bugs. Report execution reviews as **defects that bite Submit**, in product language. Do not lead with unverified gates.

Verdict: dump is wired. **Bugs found.** Image-to-source on a package whose current UI does not already match remains unproven. Do not treat older result-write-back findings as live blockers. Do not resume task-status to “fix” the bugs below.

## What holds

- Named executor dump on accept and replay. Unknown name fails before persist. Absent name currently does not dump — that is an open fake-success defect (see Bugs), not the desired product. Live dump does not wait for a result file.
- Host unit suite green (23 tests) at this tip.
- Sample project JSON names `corral-cursor`. Missing token is a hard error; File Export only when project JSON is absent.
- Submit packet is annotated images plus the canonical prompt; no second unannotated original.
- Inject uses the frozen prompt with no write-back trailer. SDK core stays Corral-free.
- `--auto-worker` / result apply / cancel stay on disk; default serve does not dump through them when an executor is set.

## Bugs (lead with these)

Submit can look successful while the assistant never received the work:

1. **No readable executor name** — host accepts and does not dump. Phone still treats Submit as success. Dump is keyed off the host checkout’s project file, not the phone packet.
2. **Older receiver still listening on the same URL** — accepts and does not dump. No dump-version handshake.
3. **False “dump applied the sample edits” claim** — `Fixtures/gate1/RESULT.md` “Live dump” said marks 1–3 were applied from this dump. Those strings were already in git from 2026-09-12 (`2c062e0`). This tip did not change that file.

| Finding | Severity | Evidence |
|---|---|---|
| Missing/unreadable executor name → accepted, no dump | Defect (fake success) | `read_executor_name`; same branch as absent-executor test |
| Older receiver on the same URL accepts without dumping | Defect (fake success) | source; not a live old-binary probe |
| Claimed dump “applied marks 1–3” is not in the git diff | False proof; do not cite | git history vs `Fixtures/gate1/RESULT.md` “Live dump” |

Not bugs under current product law: concurrent dumps, dump errors after accept (no status machine), old result-file truth findings. Do not add a task-status product to surface (1) or (2); fail Submit when dump will not happen.

## Dormant-path leakage

Not default dump, but easy for the next Agent to treat as live:

- Local Host still declares progress and cancellation support.
- Host README/CLI still list status lookup and cancel as first-class; `--auto-worker` result apply is still documented in Serve after a dormant disclaimer.
- Gate-1 replay **test** still uses `--auto-worker` with no executor (`waitingForComputer`).
- `docs/design/AGENT_PROMPT_CORE_DESIGN.md` said execution adapters were unwired; that sentence was corrected. Do not restore it.
- Root/nav still **must-read** the 2026-09-12/13 worker/cancel/result reviews before “repairing execution”; first-release disposition already says not to continue those.

`76550cc` did not newly expand write-back.

## Phone vs replay

Sample Submit **can** dump if the process on the project URL is this dump binary, the token matches, and the host checkout still points at the sample project JSON. This commit did not prove a phone Submit. Replay from this tree is the path that was actually exercised.

## Prompt / evidence

Gate-1 prompt is a short legend; inject does not add packing numbers, process lectures, or a result schema. Numbered page images are what get sent.

## Proven vs unverified

**Proven:** dump wiring and host tests; sample does not silent-fallback to File Export; packet shape; sample UI already shows the three clear gate-1 edits (from 2026-09-12).

**Unverified:** a dump whose **current** sample source does not already contain the requested edits; phone Submit against a restarted dump receiver; session image+prompt receipt kept with a **new** source diff.

## Do not do next

Task-status, result write-back, phone result UI, cancel product, restart recovery, auto re-dispatch, project queue, fix-forward of T1/T2/T3, treating concurrent Agents as a blocker, re-implementing dump because an older prompt-core sentence said adapters were unwired, annotation chrome.

## May do next

- Fail Submit when dump will not happen (missing executor name; do not keep silent accept).
- After installing this host, the process on the project URL must be that dump receiver (or add a handshake). An old listener is a fake-success bug, not a user-education note.
- Stop advertising dormant progress/cancellation as live in host help and capability flags. Do not implement those features.
- Replay or Submit a package whose **current** sample UI does **not** already match the requests. Keep image+prompt receipt and a **new** source diff. Phone Submit only after this dump binary is listening.

No extra product. Optimization suggestions beyond the defects above were not the deliverable.
