# Agent execution follow-up plan

Status: first-release is **fire-and-forget** under [the product rule](../PRODUCT_KNOWLEDGE_BASE.md#first-execution-release-scope). Host dump-to-named-executor is wired. Open defects: Submit can look successful while the assistant never received the work (missing executor name; older receiver on the same URL). Image-to-code proof still needs a package whose current UI does not already match. Details: [e2e review](../reviews/2026-09-13-FIRE_AND_FORGET_E2E_REVIEW.md).

**Do not continue** task-status, result write-back, phone result UI, cancel, or recovery. Already-written plans and code for those stay on disk, **dormant and default off**.

## Deliver one working loop

Phone annotation → Submit → host accepts the package → dump to the named executor → that executor edits the configured project. Assume it finishes as asked. If it does not, mark again and Submit again. Source edits are idempotent.

Use the current evidence package, Local Host receiver and one selected executor. Do not introduce another service, general Agent platform, project execution queue, phone configuration page, task-status product, or result-return product. Preserve the [canonical prompt contract](AGENT_PROMPT_CORE_DESIGN.md); the executor consumes numbered screenshots and requests without manual copying or a plan-approval step. SDK core stays Corral-free; the first executor name is `corral-cursor`.

## Implementation order

### 1. Dump one real coding Agent now

Use the selected `corral-cursor` executor (one project configuration value, not adapter/runtime fields); implement only the dump in [the detailed design](../CORRAL_CLOSED_LOOP_ADAPTER_DESIGN.md). Do not reopen executor selection or substitute a marker worker. It must consume the numbered images and inspect/edit the configured checkout. Do **not** wait for a result file. Do **not** add inject-trailer write-back instructions as a host contract. Model calls must use the existing shared LLM gateway; do not use a routine coding-agent CLI to bypass it.

Allow simultaneous dumps for the same project; Agents coordinate existing work. No host-side project queue or lock is required. Preserve all workspace changes.

Immediate handoff when this work resumes:

- Fail Submit when dump will not happen (no readable executor name). **Done 2026-09-13** (`missing_executor`).
- After installing this host, the process on the project URL must be that dump receiver.
- Then take a real sample package whose **current** UI does not already match the request, including a change that requires looking at the image. Dump it through the selected coding Agent in the authorized sample checkout. The Agent must receive the numbered image and canonical request, discover the source and make the edit itself. Record image/prompt receipt and a **new** source diff. Do not substitute a human/parent Agent making the edit, a marker command, static fixture, an Agent merely explaining a proposed change, or a dump that only restores strings already in git.

Stop condition: if the runtime cannot consume images, access/edit the checkout or use the required gateway, resolve that capability failure first. Do not resume receiver status/write-back work as a substitute.

### 2. Leave dormant work dormant

Do not implement, wire, or expand:

- Task-status as a product (progress, incomplete/unknown, ready-for-review)
- Result write-back (`results.json` wait/validate/apply)
- Phone progress/result UI
- Cancellation and restart recovery
- Automatic re-dispatch, queues, nested executor config

Existing host routes, worker result-apply, and design sections for those remain on disk. They stay **default off**. Do not advertise them as the live path.

### 3. Do not resume the old “repair then show results” track

Receipt recognition on Submit (the phone must know the host accepted the package) is enough transport. Do not spend this milestone validating result types, mark correspondence, or verification booleans. Preserve working complete-packet validation, project-scoped credential mode and same-submission deduplication. Configuration stays in the project and host setup.

## Focused acceptance

| Check | Required observation |
|---|---|
| Real dump | Mark an image-dependent change, Submit (or replay), observe the Agent consume the image and change the intended source without manually copying evidence |
| Receipt | Host accepts a current package; one batch resolves to one dump |
| No write-back | Live path does not wait for or require a result file |
| Failure | Re-mark and Submit again; no automatic new execution, no cancel product |

These checks gate this release. They do not require result UI, status lookup as a product, generalized restart recovery, cancellation, a second runtime/destination or a project scheduling system.

## Deferred (dormant, default off — do not continue)

Task-status, result write-back, phone result UI, reliable cancellation, automatic execution recovery/resumption, interactive clarification, a second real destination, generalized retention and extended fault/resource hardening. If a dormant capability is later turned on, its recorded defects become acceptance blockers again.

Review source and evidence: [fire-and-forget e2e review](../reviews/2026-09-13-FIRE_AND_FORGET_E2E_REVIEW.md), then [execution delivery re-review](../reviews/2026-09-13-EXECUTION_DELIVERY_REREVIEW.md#first-release-disposition). The historical full architecture remains in [the architecture bounds](ARCHITECTURE_BOUNDS.md); the current product rule owns first-release scope.
