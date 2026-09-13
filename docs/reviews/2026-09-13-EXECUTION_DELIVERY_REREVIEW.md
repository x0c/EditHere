# Execution delivery re-review

Reviewed revision: `0bf56663144998edec6d8733275b2c819f3d2c74`. Review date: 2026-09-13. Scope: the fixes following [the first execution review](2026-09-12-EXECUTION_DELIVERY_REVIEW.md). Product source was not modified by this review. The implementation was committed while inspection was in progress; at the scope check the reviewed source worktree was clean at this revision.

First-release scope: use [the disposition below](#first-release-disposition). Cancellation and automatic recovery are deferred capabilities; their defects are not normal-path blockers once those paths are disabled.

Latest independent verdict: **partial repair; automatic execution acceptance remains blocked**. See [the review of d18c016](#independent-review-of-d18c016) for current findings. The original review below concerns 0bf5666.

Original verdict: **partial repair; automatic execution acceptance remains blocked**. The seven existing Python receiver tests passed. They close several specific reproductions but not the complete six P1 contracts from the first review.

## Verified improvements

- EvidenceWriter now creates the canonical prompt; the committed gate-1 replay test preserves it.
- No configured worker now produces waitingForComputer rather than working.
- Empty package and changed manifest with a stale claimed digest are rejected.
- Submission lookup now requires project scope and distinguishes the same submission id in two projects.
- Cancellation after a simple worker has registered stops that worker in the existing regression test.
- Source inspection confirms originals are excluded from the normal Swift HTTP upload and missing credentials no longer silently select File Export when project configuration exists.

The last item is source evidence, not a new phone installation/cold-launch acceptance. Automatic coding-agent integration and the phone task-detail/result UI are still explicitly pending in the implementation plan.

## Remaining P1 findings

### R1. Cancel is not atomic with startup and cannot recover running workers after restart

Locations: `Tools/edithere-host/edithere_host/worker.py:enqueue_worker/start_worker_process/cancel_worker_process`; `server.py:HostServerState/_handle_cancel`.

The asynchronous starter captures an old task value and never rechecks whether it was cancelled. When cancellation arrives before process registration, the server marks it cancelled with no process to stop; the starter subsequently launches it and overwrites cancelled with working. Tracking exists only in the in-memory process dictionary. Recreating the receiver loses that tracking while detached work may remain alive, so cancel again reports success without stopping it.

Reproduced using temporary checkouts and harmless marker workers:

- Controlled scheduler interleaving: hold the starter until HTTP acceptance, cancel, then release it. Cancel returned 200/cancelled; the worker wrote afterwards and the final task state became working.
- Recreate the HTTP server/state while a worker remains alive, then cancel through the new receiver. Cancel returned 200/cancelled; the worker still wrote afterwards. This is a receiver-state recreation probe, not an OS crash injection; it directly demonstrates the missing process recovery mapping.

Repair: reserve and persist an execution attempt, coordinate cancellation/start/registration under one state transition owner, and recheck cancellation before permitting execution. Persist enough process identity to reconcile after restart without unsafe PID-only killing. Unknown running state must not be reported stopped. Add queued-cancel, startup-cancel and restart-cancel acceptance; retain the existing simple running-cancel test.

### R2. Result content is ignored and file existence is mistaken for a valid result

Location: `Tools/edithere-host/edithere_host/worker.py:_watch_process`.

After exit 0 the watcher only checks whether results.json exists. It does not parse it, validate its schema/task identity, or copy mark outcomes and verification facts into the task. Invalid text therefore produces readyForReview; a valid result also returns an empty markOutcomes list and unchanged verification flags. Exit 0 without a file remains working indefinitely, with no implemented later-result watcher.

Reproduced two real subprocesses: one wrote `not json`, the other wrote a result containing mark 1 changed and codeChanged=true. Both reached readyForReview; both returned empty markOutcomes and codeChanged=false.

Repair: define and validate the worker result contract; persist only validated per-mark outcomes, artifact references and verification evidence. Missing/invalid results must have an honest terminal or explicitly recoverable state. Do not infer verified success from process exit or a filename. Exercise valid, malformed, missing, partial and mismatched-task results via HTTP lookup.

### R4. Canonical-prompt validation happens after durable acceptance and is outside the digest

Locations: `Tools/edithere-host/edithere_host/server.py:_handle_submit`; `package_util.py:compute_content_digest/require_canonical_prompt`; `store.py:accept_or_reuse`.

The receiver validates manifest and annotated images, then persists and deduplicates the task, and only afterwards checks the canonical prompt during worker preparation. With auto-worker disabled it never checks the prompt. The digest excludes agent-prompt.txt and page-N copies. A missing prompt is accepted as a task; adding it on retry reuses the old incomplete directory and does not repair it or restart preparation.

Reproduced: submit without prompt -> HTTP 200 and failed; retry the same submission with the correct prompt -> reused=true, still failed, prompt still absent on disk. This differs from the repaired normal replay path: correct new packages work, incomplete acceptance is still not safe.

Repair: validate the complete execution packet before task publication. Define whether the prompt is frozen at acceptance or regenerated from immutable evidence; enforce that policy explicitly and validate numbered-page correspondence. Do not claim unchanged packet identity while arbitrary execution text can differ unnoticed. A rejected incomplete upload must be completable with the same submission id before acceptance, without opening another execution session.

### R5. Project-scoped lookup does not freeze the original destination binding

Locations: `Sources/EditHereLocalHostDestination/LocalHostDestination.swift:init/lookup/decodeTaskPayload`; `Sources/EditHereCore/Outbox/Outbox.swift:145-183`.

The new query parameter fixes the earlier cross-project lookup collision, but every destination still defaults to local-host. Pending state still lacks immutable receiver/project identity. Recovery checks that same generic destination id and trusts the currently configured project; it does not check the original receiver/project/content digest. Changing project or receiver after an uncertain submission can therefore route old work to the new binding. The task payload still lacks a decoded content digest.

This remainder is source-confirmed; a new end-to-end Swift two-receiver fault test was not run in this review. Do not mark the first review's binding finding fully fixed on the strength of query scoping alone.

Repair: store a stable binding identity and original destination resolution with the submission; use that for retries and validate the full recovered identity. Add a client test that changes default project/receiver after an accepted-but-unacknowledged task.

### R6. Bundled credentials remain host-wide instead of project-scoped

Locations: `Examples/EditHereSample/project.yml:preBuildScripts`; `Tools/edithere-host/edithere_host/server.py:_check_token/_handle_submit/_handle_cancel` and `config.py:HostConfig.token`.

The build now embeds the shared host token into the app to support ordinary launches. The receiver accepts that one token for every configured project and every task; projectID remains chosen by the request, not authorized by the credential. Thus this solves persistence by packaging the host-wide credential instead of implementing the required project-scoped provisioning boundary. Being gitignored protects version control, not the installed app bundle.

Repair: issue an app/project-scoped revocable credential, enforce its scope server-side for submission, lookup and cancellation, and provision that restricted credential through project setup. Do not add a phone pairing/settings page. This review did not inspect or print any real credential or probe a production receiver.

## Additional P2 findings

- **Incremental credential builds retain stale credentials.** The pre-build script's no-credential branch does not remove an existing output file or fail the build. Reproduced by running the actual YAML shell block in temporary directories with a synthetic token, then without either token source: the old bundled credential file remained. Clean/remove stale generated credential output and make missing required configuration explicit; validate cold launch with and without provisioning on the actual delivery route.
- **Unknown schema versions and incomplete annotation details are not rejected.** Schema validation only requires a nonempty version string and annotation capture references; it does not establish support for a particular version or require each numbered request's semantics. This is source evidence; the existing empty-object rejection does not close full schema acceptance.
- **Replay still copies all files under assets/.** That includes the gate-1 clean original even though the normal Swift upload was corrected. The receiver needs an explicit allowlist for execution artifacts to uphold original-local-only semantics across both routes.
- **Lifecycle/resource limits remain incomplete.** No worker timeout or durable startup recovery; the log cap is applied after reading a full line, and upload body length remains unbounded. CLI replay uses daemon monitoring threads that are not durable after the CLI exits. These require dedicated acceptance before an automatic production worker is advertised.

## Accepted concurrency behavior

R3 is withdrawn under the [product concurrency rule](../PRODUCT_KNOWLEDGE_BASE.md#confirmed-product-rules). The probe demonstrated two same-project tasks starting concurrently; it did not demonstrate overwritten changes. Concurrent execution is allowed and does not require a per-project queue or write lock. The raw probe remains evidence of allowed behavior, not a failing acceptance check.

## Evidence and limits

- Existing receiver suite: `python3 -m unittest discover -s tests -v`, 7 tests passed in approximately 5.1 seconds.
- New isolated probes: [execution-rereview-results.json](execution-rereview-results.json). The startup race uses a controlled scheduler barrier around the real starter; other probes use real loopback HTTP/subprocesses and temporary files. No LLM calls or real checkout edits were made.
- Existing improvements are distinguished above from remaining contracts. No Swift suite, new signed build, phone cold-launch, automatic coding-agent, gateway trace or phone result UI was validated in this review. No Simulator, test driver or Docker was started.
- Keep [the execution plan](../design/AGENT_EXECUTION_PLAN.md) marked partial until real Submit -> execution -> validated results -> build/install -> affected-screen evidence passes. Unit worker hooks are not an Agent integration proof.

## Next repair gate

Prioritize R1/R2 together as one coherent per-task worker lifecycle: accepted -> starting -> working -> validated result or explicit failure/cancel, with durable execution tracking. Then close complete-packet acceptance, immutable bindings and scoped credentials. Retest all original reproductions plus the new interleavings before proceeding to phone task-detail UI and full-loop acceptance.

## Repair progress (2026-09-13, post-re-review)

User ruling: same-project concurrent Agents are allowed; R3 stays withdrawn (see [Accepted concurrency](#accepted-concurrency-behavior)).

| ID | Status | What landed |
|---|---|---|
| R1 | Existing tests pass; still open in independent fault probes below | Cancel flag + lifecycle `RLock`; recheck before/after `Popen`; persist worker pid/pgid; restart cancel recovers from disk; cancel-before-start barrier test; uncertain stop → 409 `cancel_uncertain` |
| R2 | Existing tests pass; still open in independent result validation below | Parse/validate `results.json`; apply markOutcomes/verification; invalid/missing → `failed` not `readyForReview` |
| R3 | Withdrawn | Concurrent same-project work is allowed |
| R4 | Closed in host tests | Require canonical `agent-prompt.txt` before accept; digest includes prompt; missing prompt → 400 then same submissionID retry succeeds |
| R5 | Partially closed | Task `destinationID` is `local-host:{projectID}`; phone destination matches; recovery requires current + stored destination id; payload projectID mismatch rejected |
| R6 | Partially closed | Optional per-project `tokenEnv` in host config; authorize by project; sample prefers `EDITHHERE_TOKEN_EDITHHERE_SAMPLE`; stale credentials file removed when neither source exists |

Also fixed: multipart parser no longer strips a real trailing `\n` from uploaded files (broke prompt digests); worker start no longer deadlocks on nested `lifecycle_lock` (must use `RLock`).

Host suite: `python3 -m unittest discover -s tests -v` (13 tests). Full Submit → coding Agent → phone UI still pending per the execution plan.

## Independent review of d18c016

Reviewed revision: `d18c016` (2026-09-13). The changes were committed during inspection; the product source worktree was clean at the scope check. No product source changes were made by this review. Same-project concurrency remains allowed and is not a finding.

### Confirmed progress

All 13 receiver tests pass (13.632 seconds). This confirms missing-prompt rejection followed by successful retry, canonical-prompt digest inclusion, ordinary start/cancel handling, malformed-JSON rejection, valid result ingestion and configured per-project token rejection. The stale credential removal branch is present in source; no new signed build/cold launch was performed. These results do not close all failure windows below.

### T1 — P1 — Cancellation can still acknowledge before work stops

Locations: `Tools/edithere-host/edithere_host/worker.py:246-267, 349-384`; `server.py:_handle_cancel`.

Two independent temporary marker probes reproduce HTTP 200/cancelled followed by a write:

- Pause immediately before the actual `Popen`, after the cancellation checks. Cancel returns success because no process is registered. Releasing the pause permits real execution before the post-launch check can kill it. The existing barrier test pauses before those checks and misses this window.
- Run a shell command whose child ignores SIGTERM and writes after a short delay. The shell exits on SIGTERM; `_kill_process_group` treats the shell's exit as proof the entire group stopped, skips escalation, and returns success while the child continues.

Repair: make launch reservation/start/registration and cancel confirmation one coordinated per-task protocol; a pending launch cannot be reported stopped. Confirm the relevant worker descendants have stopped instead of relying on the shell leader alone. Test both windows. This is per-task correctness, not a requirement to serialize different tasks.

### T2 — P1 — Restart cancellation signals an unverified persisted PID

Location: `Tools/edithere-host/edithere_host/worker.py:419-461`.

The restart path trusts the stored PID and checks only whether a process with that number exists before sending SIGTERM/SIGKILL. The stored timestamp is not checked against OS process identity. If the old worker exits and its PID is reused, cancelling an old task can terminate an unrelated process. The required identity recheck is documented in [process termination safety](maintainer process-termination safety notes).

A signal-spy probe supplied a stale timestamp and simulated a live reused PID; the code attempted SIGTERM without any identity lookup. No real unrelated process was signalled. Persist and revalidate an OS-backed identity before each signal; a mismatch must not authorize termination.

### T3 — P1 — Invalid verification values are converted into success

Location: `Tools/edithere-host/edithere_host/worker.py:123-158`.

Result validation uses Python truthiness instead of requiring JSON booleans. A real worker returned string `"false"` for codeChanged/checksPassed/installed/visuallyVerified and an outcome for nonexistent mark 999. HTTP lookup returned readyForReview with all four flags true and mark 999 accepted. Thus malformed worker output still advertises checks, installation and visual verification that did not occur.

Require exact supported value types and correlate unique mark numbers with the submitted package. Reject wrong task identity and unsupported/incomplete result structures; do not coerce arbitrary strings/numbers into verification facts.

### T4 — P1 — The public default Swift initializer rejects current host responses

Locations: `Sources/EditHereLocalHostDestination/LocalHostDestination.swift:25-34, 354-358`; `Tools/edithere-host/edithere_host/store.py:16-17`.

The host now returns `local-host:{projectID}`. The public baseURL/projectID initializer still defaults to `local-host`, while response decoding now requires exact equality. A consumer using that initializer can have a task accepted and started, then see a conflict when the acknowledgement is decoded; lookup fails for the same reason. Only the projectConfigURL initializer sets the matching project-qualified id.

A standalone macOS harness compiled the actual Core/LocalHost Swift sources and invoked lookup with a representative current-host HTTP response. It threw `Recovered task destination local-host:sample does not match local-host.` This is portable client-runtime evidence, not phone UI acceptance. Align all construction paths and add a current-host response regression; account for older stored task identities during migration.

### T5 — P1 — Changing receivers can still redirect a pending task

Locations: `Sources/EditHereLocalHostDestination/LocalHostDestination.swift:44-54`; `Sources/EditHereCore/Outbox/Outbox.swift:145-185`.

Project-qualified destination ids distinguish projects, but still omit receiver identity. Configure a different receiver with the same projectID after an accepted-but-unacknowledged submission: the stored id and digest remain compatible, recovery uses the new receiver, and a missing lookup falls through to submit there. The old receiver can already be executing that batch. Remote contentDigest/submission identity is still not validated by the client.

This is a source-confirmed remainder of R5; a full two-receiver Swift retry test was not run. Preserve the original resolved receiver/project binding for pending work, or explicitly stop recovery when that binding changes.

### Evidence and remaining limits

- [Third-review probe results](execution-third-review-results.json) include source hashes and the reviewed full revision. Python probes use loopback HTTP, temporary directories and harmless marker processes; the PID probe intercepts signals. The Swift harness uses the actual portable source and a synthetic HTTP response.
- The ordinary receiver suite is green; the independently reproduced findings above remain acceptance blockers. R4's missing-prompt/retry case is closed. R6's explicit per-project credential mode works; host-token fallback remains optional and should not be described as mandatory project isolation.
- Receiver restart still does not create a new completion watcher for surviving workers; durable completion/reconciliation requires further acceptance. Replay asset allowlisting, schema completeness and resource limits remain as recorded above.
- No real coding Agent/model call, phone Submit, signed app, install or affected-screen validation was performed. No Simulator, test driver or Docker was started.

## First-release disposition

The [product first-release scope](../PRODUCT_KNOWLEDGE_BASE.md#first-execution-release-scope) supersedes the earlier assumption that all lifecycle capabilities must ship together. The findings remain factual; their release treatment is:

| Finding | First-release treatment |
|---|---|
| T1 cancellation can outlive acknowledgement | Dormant / default off; do not continue cancellation as a product |
| T2 persisted PID termination | Dormant / default off; no restart cancellation |
| T3 false verification results | **Superseded (2026-09-13):** no result write-back or result UI in the live path. Do not fix-forward a status machine. Re-mark and resubmit. |
| T4 default initializer rejects receipt | Fix if Submit cannot tell the host accepted the package; not a task-status product |
| T5 old work can move to another receiver | Do not auto-resubmit to a new target; full recovery/migration is not required |

Current code was not changed to implement this reduced scope by this documentation update. The live product is fire-and-forget: dump the package to the named executor and assume it finishes. Do not continue receiver status, write-back, or result UI as a substitute. Same-project concurrency remains allowed.
