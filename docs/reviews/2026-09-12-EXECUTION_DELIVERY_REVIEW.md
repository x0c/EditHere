# Execution delivery review

Reviewed revision: `2c062e04c1e9d945d4eef483b315eec05c4a1b43`. Scope: project configuration, Local Host destination, receiver/worker, evidence handoff, recovery and claimed gate-1 proof. Review only; no product source changes. The worktree was initially uncommitted and became this commit during review; the inspected execution files had no differences from it at final scope check.

Verdict: **not ready for automatic execution or closed-loop acceptance**. Project-owned configuration is the correct direction. Existing task persistence and status structures are useful foundations. The failures below must be fixed before exposing the destination as execution-capable.

## P1 findings

### 1. The execution packet loses the canonical change requests

Locations: `Sources/EditHereCore/Outbox/Outbox.swift:204`, `Sources/EditHereLocalHostDestination/LocalHostDestination.swift:57`, `Tools/edithere-host/edithere_host/cli.py:cmd_replay`, `package_util.py:111`.

The phone stages manifest/assets with EvidenceWriter, which does not write the canonical prompt. Local Host gathers files but never invokes the prompt builder. The receiver's fallback builds only an app/page catalog, omitting every annotation request and ambiguity instruction. Independently, CLI replay loads referenced assets and extra files only under assets/, so even an exported root agent-prompt.txt is dropped before the worker runs.

Reproduced using the committed gate-1 package, a temporary host config/data directory, and replay with auto-worker enabled but no worker command. Exit was 0; the resulting prompt was only:

```text
App: EditHere Sample
Page 1 · sample-home — marks 1, 2, 3, 4, 5
```

All five requests and the do-not-guess text were absent. They remain in the manifest, but the advertised execution input is not the required canonical packet; an unspecified future worker reading extra files is not a valid substitute.

Fix: produce/preserve the canonical prompt in the shared submission/export path, bind it to numbered composites and validate completeness before acceptance. Replay must preserve the same prompt. Do not create a second independent Python prompt template.

Acceptance: compare actual phone upload and replay worker input to the preview/canonical prompt for a multi-page batch, including incomplete and repeated-row requests.

### 2. Execution capability and working state are reported without execution

Locations: `Sources/EditHereLocalHostDestination/LocalHostDestination.swift:33`, `Tools/edithere-host/edithere_host/server.py:_handle_submit`, `worker.py:73`.

The destination always advertises direct execution. Default receiver operation only stores tasks. Auto-worker sets working after writing a request file, even with no worker command. Reproduced: a valid submission with no configured worker returned HTTP 200 / working. An empty package also returned working (see finding 5).

When a command is configured, it runs synchronously inside the HTTP request with no timeout. The acceptance response waits for completion; exit status is not mapped to a final task outcome. The configured checkout is not passed to the hook, whose working directory is the task directory. There is no implemented bounded Agent lifecycle, project queue, restart reconciliation, or verified gateway execution integration.

Fix: separate durable acceptance from an independently managed worker, validate execution capability at setup, and transition to working only on observed startup. Map exit/error/outcomes honestly. Resolve the authorized checkout before dispatch. Concurrent same-project execution is allowed under the [product concurrency rule](../PRODUCT_KNOWLEDGE_BASE.md#confirmed-product-rules).

Acceptance: no command, failing command, delayed command, receiver restart and two same-project jobs. Acceptance must return before a long execution finishes; no false working state.

### 3. Cancel reports success while execution continues writing

Locations: `Tools/edithere-host/edithere_host/server.py:_handle_cancel`, `worker.py:44`.

Cancel only writes state=cancelled. The worker process is neither signalled nor tracked. The Swift destination nevertheless advertises cancellation support.

Reproduced with an isolated Python worker that creates a start marker, waits 0.8 seconds, then writes a second marker. After the first marker, HTTP cancel returned 200 / cancelled. The second marker was still written afterwards. The original Submit response also did not arrive until the worker exited.

Fix: track the running attempt/process, request cancellation, wait for stop acknowledgement, and report cancelled only when further work has stopped. Preserve already-written changes; do not revert arbitrary workspace files. Disable unsupported cancellation until implemented.

Acceptance: cancel queued and running jobs, including subprocesses and cancellation racing with completion, without subsequent writes or false success.

### 4. Normal app launches silently fall back to file export

Location: `Examples/EditHereSample/Sources/EditHereSampleApp.swift:50`.

The receiver credential comes only from the launch process environment. Without it, the sample silently selects File Export; configuration exists but Submit does not reach the receiver. Xcode scheme environment values are provided by Xcode at launch, not a durable credential setup for ordinary home-screen launches or shelf-installed apps.

This is a source-confirmed branch and a platform-supported consequence, not a new on-phone cold-launch reproduction in this review. Apple's [scheme documentation](https://developer.apple.com/documentation/xcode/customizing-the-build-schemes-for-a-project) explains environment injection by the launching Xcode action.

Fix: provision a scoped credential through secure project-owned development setup that survives normal launches. Missing execution configuration must be an actionable integration error, not an automatic destination change. Do not add the rejected phone pairing/settings page.

Acceptance: install through the actual delivery route, launch without injected environment, submit, terminate/reopen and submit again. Verify the receiver got each task and File Export was never silently substituted.

### 5. The receiver trusts the submitted digest instead of verifying content

Locations: `Tools/edithere-host/edithere_host/server.py:_handle_submit`, `package_util.py:27`, `store.py:176`.

The receiver checks hashes only for asset descriptors it happens to recognize. It does not recompute the submitted content digest, require meaningful captures/annotations, require all descriptor fields, or compare the form submission identity with manifest.id. It therefore acknowledges incomplete or different content as an existing accepted task.

Reproduced: changing overallInstruction while retaining the previous digest returned 200 / reused, preserving the old request. A package containing only `{}` was accepted with 200. Tests currently exercise changed digest with identical bytes, not changed bytes with an unchanged claimed digest.

Fix: define one canonical digest contract, calculate it server-side, validate schema/version, identities, mark-to-capture references, required annotated images and canonical prompt before durable acceptance. Reject invalid or conflicting content without creating a task.

Acceptance: changed request with stale digest, missing descriptors, missing captures, identity mismatch, unknown schema and incomplete assets.

### 6. Recovery is not scoped to the original project/destination binding

Locations: `Tools/edithere-host/edithere_host/store.py:save_task/find_by_submission`, `server.py:_do_GET`, `Sources/EditHereLocalHostDestination/LocalHostDestination.swift:143`, `Sources/EditHereCore/Outbox/Outbox.swift:129`.

Acceptance keys by project plus submission, but recovery GET keys by submission alone; the secondary sid index is overwritten by the latest project. The Swift response does not retain/validate projectID or contentDigest during recovery. All Local Host instances also use the same default destinationID regardless of receiver/project, while the pending record retains no immutable receiver binding.

Reproduced: accepting the same submission id in two configured projects, then performing recovery lookup, returned the second project's task. This is relevant to retrying after a project configuration change, not a claim about random UUID collisions. Changing receiver/project while retaining local-host can also send old work through the new configuration.

Fix: persist immutable destination binding for pending work; scope recovery by that binding/project/submission and verify the returned identity/digest. Configure receiver credentials with project scope: the present shared host token authorizes every registered project and task, rather than enforcing app-to-project authorization.

Acceptance: same identity in two projects, changed default receiver/project, revoked binding, and lookup returning another task. No old task may be redirected or shown as another project's result.

## Additional P2 issues and unfinished work

- **Clean originals leave the phone.** LocalHostDestination.submit explicitly uploads originalImage and all staged files; this violates the product rule that clean originals remain local for redraw. Select only the required numbered composites and canonical prompt for execution handoff. The current worker catalog selects annotated images, but that does not undo the unnecessary original upload/storage.
- **No automatic outbox recovery or result UI.** Lookup exists only during another submit attempt; there is no completed background recovery/progress integration in the inspected path. Per-mark result structs are present, but the phone task-detail UI is explicitly pending. These are known unfinished milestones, not evidence of a shipped complete loop.
- **Status decoding is not backwards compatible.** The new nonoptional markOutcomes property uses synthesized Codable decoding; an older serialized task status without it will fail despite the initializer's default empty array. Add an explicit decoding default and an old-payload regression fixture.
- **CLI contracts need further work.** Argument errors use default argparse text rather than the advertised JSON error envelope. doctor computes ok without dataDirWritable and performs a write probe; serve prints a success-shaped starting envelope before bind succeeds. These are secondary to the execution blockers.
- **Worker retention/resource bounds remain absent.** Synchronous capture_output with no timeout and no upload body bound is unsuitable for long Agent output or malformed large submissions. Add explicit limits and durable bounded logs with the worker lifecycle.

## What the existing proof establishes

Inspected `Fixtures/gate1/after-device.png`: Recently used, absent promo card and Pinned item at row 3 match the result note; surrounding list labels remain. This is evidence of the resulting sample UI. The fixture is explicitly synthetic and its README permits manually opening the images and prompt. No captured runtime/gateway transcript in that fixture establishes that the automatic receiver/worker consumed the canonical packet and performed the edits.

Therefore retain this as controlled fixture/visual evidence, not proof of automatic phone Submit, gateway-compatible runtime integration, cancellation or offline recovery. The replay prompt-loss reproduction specifically prevents using the current replay command as that proof.

## Validation performed and limits

- Ran existing Python receiver suite: 1 test passed (normal HTTP accept, dedupe, conflict, lookup).
- Ran isolated HTTP/worker/replay probes, using temporary data, loopback listeners and a harmless Python marker-file worker; no LLM, real project edits or real execution service calls. Recorded outputs: [execution-review-results.json](execution-review-results.json).
- Reproduced missing worker falsely working, cancellation continuing writes, Submit waiting for worker exit, changed content with stale digest, empty package acceptance, replay prompt loss and cross-project recovery collision.
- Inspected committed device image. Queried devices; physical iPhone Max is available. Did not launch Simulator, install a test driver, rebuild or replace the phone app, run Swift/device acceptance, or claim current phone cold-launch verification.
- Review source remained at the named revision at final scope check. Product fixes and a release were not performed in this review.

## Repair status (2026-09-12 follow-up)

Code changes address the six P1 findings: staged canonical `agent-prompt.txt`, annotated-only execution digest, async worker with honest `submitted`/`waitingForComputer`/`working`, process-group cancel, project-scoped submission lookup, and no silent File Export when project config is present (credentials via bundled/build-time file). Host and Swift unit suites were re-run after the fixes. Automatic coding-agent execution and phone task-detail UI remain open; do not treat this as closed-loop acceptance yet.


Independent re-review of `0bf5666`: [2026-09-13 execution delivery re-review](2026-09-13-EXECUTION_DELIVERY_REREVIEW.md). The repairs above are partial; startup/restart cancellation, result ingestion, complete-packet acceptance and immutable/scoped binding remain blocked.
