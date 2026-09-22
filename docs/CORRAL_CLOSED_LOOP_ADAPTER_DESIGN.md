# EditHere executor adapter design

Status: **fire-and-forget is the live product**. First concrete executor: `corral-cursor`. Dump is wired on accept/replay. Open defects: fake-success Submit when dump does not happen (missing executor name; older receiver on the same URL). Live image-to-code proof still needs a package whose current UI does not already match.

Write-back, task-status, and result UI below are **dormant and default off**. Keep the text. Do **not** continue implementing them.

Related: [first-release scope](PRODUCT_KNOWLEDGE_BASE.md#first-execution-release-scope), [execution plan](design/AGENT_EXECUTION_PLAN.md), [prompt contract](design/AGENT_PROMPT_CORE_DESIGN.md).

---

## 1. Pattern (locked)

```text
Phone EditHere
  → Local Host receiver (existing; no new service)
  → selected executor (project field "executor")
  → that executor edits sources and is assumed to finish
```

**Executor = adapter.** One project picks one name. The host only:

1. Accepts the frozen package.
2. Dumps it to the named executor (task id, package dir, checkout).
3. Returns. It does **not** wait, does **not** require a result file, and does **not** maintain a product task-status machine.

The host does **not** scrape chat, run NLP, or call a second model to invent outcomes.

Each executor owns how it starts work and how it feeds images + the canonical prompt. Switching executors is switching the name and its implementation — not adding shared `adapter` / `runtime` fields.

If the change did not happen, the developer marks again and Submits again. Source edits are treated as idempotent.

---

## 2. Configuration

```json
{
  "executor": "corral-cursor"
}
```

- One string in `edithere.project.json`. Examples: `corral-cursor`, later `claude-code`.
- No nested `{ "adapter", "runtime" }`.
- Design ≠ live is closed for `corral-cursor`: the sample project JSON includes the key because dump-to-that-executor is wired. Do not add other executor names until those implementations exist.
- Unknown executor name → fail the accept clearly; never silent File Export when project JSON is present.
- Missing/unreadable executor name → **fail the accept** (`missing_executor`). Do not silent-accept. Unknown names already fail.

Checkout paths and tokens stay in host-local config. No phone executor picker.

---

## 3. Host ↔ executor contract (live)

Dispatch input (conceptual):

| Input | Meaning |
|---|---|
| `task` | Accept record (`remoteTaskID`, `submissionID`, …) — transport identity only |
| `package_dir` | Frozen evidence (images + canonical `agent-prompt.txt`) |
| `checkout` | Absolute authorized project path |
| `project_config` | Build / delivery / acceptance from project JSON (unused until a later explicit ask) |

Executor obligations:

1. Deliver numbered images + the frozen canonical `agent-prompt.txt` to whatever backend it uses.
2. Edit the checkout. The host assumes this succeeds.
3. Do not mutate the on-disk frozen `agent-prompt.txt`.

Host after dump: do not wait for a file, do not apply mark outcomes, do not patch verification booleans.

---

## 4. Placement

| Piece | Location |
|---|---|
| Executor interface + name registry | `host/edithere_host/executors/` (sibling `host/` repo) |
| Each executor implementation | Same tree; optional deps only inside that module |
| SDK | No executor-backend imports |

Absent `executor` → do not invent a worker. Concurrent dumps allowed; no project queue.

---

## 5. Dormant (default off — do not continue)

Already-written result-file schema, inject trailer (`result_path`), host wait/validate/apply, task-status, cancel, and phone result UI. Existing host code that applies a result file on worker exit stays on disk; it is **not** the live product path and must not be expanded.

If this is later turned on, the host still must not scrape chat or call a second model for outcomes. Until then, do not implement or wire it.

Historical schema (kept for the dormant path only):

```json
{
  "remoteTaskID": "<uuid>",
  "submissionID": "<uuid>",
  "summary": "…",
  "markOutcomes": [
    { "number": 1, "status": "changed", "summary": "…", "paths": ["…"] }
  ],
  "verification": {
    "codeChanged": true,
    "checksPassed": false,
    "artifactReady": false,
    "installed": false,
    "visuallyVerified": false
  }
}
```

---

## 6. First implementation: `corral-cursor`

This section is **one executor’s internals**, not the product pattern.

Uses Corral to host a session whose Corral runtime id is `cursor`, and injects images/text via Corral.

| Step | This executor does |
|---|---|
| Start | Corral `SessionHub.new_session("cursor", checkout)` |
| Feed | `send_image` per page, then `send_text` (canonical prompt) |
| Finish | Return after dump; do **not** wait for a result file |
| Do not | Spawn `agent` outside Corral and call it this executor; use `plan continue` as execute; add write-back trailer |

Image path paste ≠ vision proof; live proof must show image-dependent edits.

Gateway routing for whatever model that session uses remains a capability check for this executor; failure is reported, not silently swapped to another executor.

---

## 7. Implementation order

1. Registry + parse `executor`; unknown → fail; absent → do not dump.
2. Implement `corral-cursor` minimum: session + inject images and canonical prompt. **Stop. No wait, no result file.**
3. Replay a real package; prove image use and correct edits.
4. Do **not** continue host build/deliver-from-result, phone result UI, or auto-status.

---

## 8. Non-goals

Task-status product, result write-back, cancel product, auto re-dispatch, project queue, multi-executor UI, nested config fields, new HTTP service, executor types in EditHereCore, success from idle/attention/path-paste alone.

---

## 9. Acceptance

| Check | Pass |
|---|---|
| Pattern | Any executor is a name → dump; host does not wait on a result file |
| First executor | `corral-cursor` proves image→edit on a real package |
| Dormant | Write-back / task-status / result UI remain default off |
| Submit | Wired only after dump proof |
