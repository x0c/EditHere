# EditHere native UI functional review

Landed in this repository on 2026-09-12 as the authoritative list of native-UI lifecycle defects. Original review was `/tmp/EditHere-review-2026-09-12/functional-review/DRAFT_FUNCTIONAL_REVIEW.md`. Product rules distilled from it live in `docs/PRODUCT_KNOWLEDGE_BASE.md`. Failed-path list: `docs/troubleshooting/2026-09-12-annotation-chrome.md`.

**Ruling (2026-09-12):** there is no Browse control. Close returns to the live app; tap the floating entry to capture the next screen. Finding 2’s *intent* still applies (idle overlay must pass host touches). Its Browse-button acceptance and “restore Browse” repair step are superseded.

Date: 2026-09-12. Review only; no product fixes applied. This supplements the earlier architecture and native UI handoffs.

## Verdict

The current native UI rewrite is not functionally ready. The first request-panel configuration has a reproduced fatal crash. Several other interaction paths have lifecycle or touch-routing defects. Switching to native controls was the correct product direction; the regression comes from incomplete integration with UIKit presentation and state ownership.

The working tree is uncommitted on top of `e78d45b`, and another process/Agent changed files while this review was running. Findings below refer to the saved files in `reviewed-source/`, not a promise that later edits are identical. In particular, the implementation changed from presenting on the overlay controller to creating a second higher window during the review. The fatal configuration order remains in the saved latest snapshot.

Reviewed snapshot SHA-256:

| File | Hash |
|---|---|
| HostWindow.swift | fa69ab3c082127af92c483d8bee277b20f655d53c883461ba5f5ba53baf09e0f |
| WriteViewController.swift | 775fa8d807b578bb77a834350dae165d9b43e73247d958036a324233a9737052 |
| Session.swift | 54b0f6309a1b6f05ec77dafbb153cc7c1bf44309455ccda232c208f204bec618 |

Original paths are under `./Sources/EditHere/`; HostWindow and WriteViewController are in `UI/`, Session in `Session/`.

## Findings

### 1. P1 — First target selection reaches a fatal configuration call

Evidence: runtime reproduced using the current WriteViewController copied into an isolated simulator app. `HostWindow.swift:260–267` creates the write controller and calls `configure` before loading its view or installing it in a navigation controller. `WriteViewController.swift:132` dereferences `submitItem`, which is initialized only in `viewDidLoad`.

The isolated app builds successfully and crashes at this exact call. Runtime output:

```text
NativeReview/WriteViewController.swift:131: Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional value
```

The isolated file has one fewer import line, hence line 131 versus product line 132. The only change to that copied file was removing its unused `import EditHereCore`; UIKit behavior and implementation were otherwise preserved. `crash.ips` identifies `EditHereWriteViewController.configure` on the main thread with SIGTRAP. This is a runtime reproduction of the controller defect, not a claim that a fully automated end-to-end sample flow was completed.

Fix direction: make configuration safe before view loading by storing state and rendering it after controls exist, then updating it when the view is loaded. Alternatively establish the intended containment and load the view before rendering. Do not merely change the dereference to optional chaining: that can discard the initial state. Do not overlook that `viewDidLoad` also uses `navigationController` to show its toolbar; forcing load before containment can create a different missing-toolbar bug.

Acceptance: cold first selection, repeated selection, point fallback, select → enter request → submit. Initial title/count/button state must be correct before the first interaction. Add a lifecycle regression test that configures a newly initialized controller before presentation.

Apple basis: [UIViewController lifecycle](https://developer.apple.com/documentation/uikit/uiviewcontroller) and [loadViewIfNeeded](https://developer.apple.com/documentation/uikit/uiviewcontroller/loadviewifneeded%28%29) distinguish construction from view loading. A successful build does not establish this ordering.

### 2. P1 — Browse mode intercepts the host instead of returning interaction

Evidence: source-confirmed in snapshot `HostWindow.swift:21–38, 71–81`. `.browsing` shares the annotation-mode fallback. For a touch outside SDK controls, it returns `annotationOverlay` even when that overlay is hidden. `refreshChrome` hides the overlay in browsing, while session `handleTap` rejects non-annotation modes. The SDK therefore claims a host-area touch and has no useful action to perform with it.

This directly contradicts Browse's purpose: scroll/navigate the real app and capture another screen. A transparent or hidden visual does not justify explicitly returning it from custom hit testing.

Fix direction: in browsing/idle, only SDK control hit regions own touches; other points return nil from the SDK window. In annotation mode, the frozen canvas owns the remaining points. Never return a hidden view as a fallback hit target. Verify coordinate conversion across windows.

Acceptance: enter marking → Browse → toggle a host switch, scroll the list, open a host page → return to marking. The host receives exactly the intended interactions, and marking never activates live host business controls.

### 3. P1 — The newly added sheet window breaks the intended interactive canvas

Evidence: source-confirmed design regression, not yet exercised end-to-end because finding 1 blocks the path. `HostWindow.swift:277–291` creates an ordinary UIWindow above the SDK overlay with a clear full-screen root. It becomes key and presents the write sheet. It has no pass-through behavior for the area outside the sheet.

The sheet's compact undimmed setting permits interaction with its own underlying presentation view. That view is now an empty root in the new window, not the frozen annotation canvas in the lower window. Clear pixels do not automatically pass touches through windows. Increasing window level has not established correct interaction ownership.

Fix direction: prefer one annotation window with the canvas and native presentation in a coherent hierarchy. If a second window is demonstrably necessary, explicitly implement and test outside-sheet routing, key-window restoration, and cleanup for every dismissal route. Do not add another high window just to conceal an unexplained presentation failure.

Acceptance (one-window rule still applies). **Superseded 2026-09-12 on retarget:** while any presented card occupies interaction, a tap on the uncovered canvas must **not** change the selected target and must **not** reach the live host. See `docs/PRODUCT_KNOWLEDGE_BASE.md` § Continuous marking. Collapse/close → app focus and SDK controls return correctly.

Apple basis: [largestUndimmedDetentIdentifier](https://developer.apple.com/documentation/uikit/uisheetpresentationcontroller/largestundimmeddetentidentifier) describes interaction with content under the sheet, not automatic passage through an independent UIWindow. [makeKeyAndVisible](https://developer.apple.com/documentation/uikit/uiwindow/makekeyandvisible%28%29) explicitly changes key-window ownership; it is not merely a visibility toggle. The cross-window failure above is an inference from those semantics and the inspected hierarchy.

### 4. P1 — Native swipe dismissal is not connected to SDK state or window cleanup

Evidence: source-confirmed. The sheet is interactively dismissible and shows a grabber. There is no presentation delegate handling user dismissal. Cleanup exists only in `dismissWriteSheetIfNeeded`, reached through SDK callbacks. The added sheet window is strongly retained separately; an interactive dismissal does not run this cleanup.

Consequences: the now-empty higher window can remain active over the app; the workspace toolbar can remain hidden; selected-target state remains active. A later state refresh may recreate the sheet. Weak references to the presented controllers are not a complete presentation state machine.

Fix direction: route native swipe dismissal and explicit collapse/close through one idempotent completion path that flushes the request, updates selection/presentation state, restores toolbar/focus, and releases/hides any auxiliary window. Track presenting/dismissing transitions so a late completion cannot hide or replace a newer surface. Programmatic dismissal also needs its explicit completion path; do not assume every dismissal produces the same delegate callback.

Acceptance: swipe down with empty input and with typed input; reopen; select another target; rapidly collapse and reopen. No transparent touch blocker, spontaneous reopening, lost draft or hidden primary controls.

Apple research pointer: [UIAdaptivePresentationControllerDelegate](https://developer.apple.com/documentation/uikit/uiadaptivepresentationcontrollerdelegate). The API page was discoverable; several individual Apple method pages returned JavaScript-only content and their Markdown endpoint could not be extracted by the browsing tool. Do not present those failed extractions as additional verified implementation evidence.

### 5. P1 — Marks opens from a presenter already occupied by the write sheet

Evidence: source-confirmed in `HostWindow.swift:336–337, 378–389`. While editing, Marks calls `presentMarksSheet`; it asks the auxiliary window's root to present a new navigation controller, although that same root is already presenting the write navigation controller. The earlier variant had the equivalent problem on the original root.

Fix direction: use a single coherent navigation path, such as pushing the marks list within the existing navigation controller and providing a normal return route. Alternatively complete dismissal before presenting the replacement. Do not issue concurrent presentations or paper over them with arbitrary delays.

Acceptance: type the first request → Marks shows that pending request → return and continue editing. Repeat during keyboard display and immediately after collapse. No presentation warning, silent button or lost input.

Additional gap: the existing marks list reads committed annotations only, does not implement row selection to edit, and does not consistently refresh its Submit count after deletion. Fix these as part of the same review/edit path rather than exposing an apparently editable list with inert rows.

### 6. P1 — Submit results and errors no longer reach the interface

Evidence: source-confirmed in saved UI files. Session updates `statusMessage` and `lastReceipt` for capture failure, submit success/rejection and draft-save failure. Neither native controller renders those values. The observer refreshes count and selection, but no result/error surface exists. The list starts submission and dismisses immediately.

Consequences: a failure can look like a dead button, and a local export can finish without telling the developer where it went. Newer marks may be preserved by the session while a failed older batch becomes practically inaccessible through this UI.

Fix direction: reconnect truthful, visible states at the submission/task surface: preparation, accepted/exported, failure and uncertain outcome. Keep the failed batch available for safe retry/recovery. Use native presentation/inline status appropriate to the action; no extra approval screen. A message that only exists in a model property does not satisfy feedback acceptance.

Acceptance: successful export, destination throws, capture fails, draft persistence fails, slow submission followed by new marks. Each result is visible, actionable and associated with the correct batch. Do not call local export “source modified.”

## Capability gap that predates this UI rewrite

The sample still injects `EditHereFileDestination` in `Examples/EditHereSample/Sources/EditHereSampleApp.swift:19`. Product documentation explicitly says Corral/ACP execution adapters are not implemented. Therefore even a repaired UI currently exports evidence; it cannot make an Agent edit source. This is a missing integration, distinct from the new UI regressions. Do not interpret an exported package as completion of the user's original direct-edit workflow.

**Superseded 2026-09-13:** sample Submit to Local Host dumps to the named executor when project JSON includes it. Do not read this gap as current. Open defects are fake-success Submit (see [fire-and-forget e2e review](2026-09-13-FIRE_AND_FORGET_E2E_REVIEW.md)), not “adapters unwired.” File export is still not “source modified.”

## Recommended repair order and acceptance

1. Fix controller initialization and prove first selection/input in a real running build.
2. Restore Browse hit routing and simplify the overlay/sheet hierarchy. Verify compact-sheet retargeting before adding more windows or callbacks.
3. Centralize presentation lifecycle: write, marks, interactive dismissal, programmatic dismissal and focus restoration.
4. Restore request editing, counts, submission feedback and access to failed batches.
5. Run one actual two-page flow: mark A, Browse, mark B, edit A, delete B, submit, open the exported image/manifest and match the request to the numbered screenshot.
6. Only then connect an execution destination and separately verify real source changes, a successful build and the requested visual outcome.

Do not claim acceptance from a native-looking screenshot or compilation alone. For each step record both what appeared and what happened to data. The highest-priority issue has runtime crash evidence; the remaining findings are source-confirmed defects/risk paths requiring acceptance after the first blocker is repaired.

## Evidence and limits

- Installed sample inspected on iPhone 17 Simulator, iOS 26.2. The entry responds, but automated target selection did not establish a reliable complete sample flow. No end-to-end success is claimed.
- Isolated crash harness: `Host.swift`, `WriteViewController.swift`, `project.yml`, `NativeReview.xcodeproj` in this directory.
- `build.log`: isolated app built successfully. `runtime.log` and `crash.ips`: reproduced fatal configuration call.
- `reviewed-source/`: immutable copies of the relevant source for this report. The live working tree may continue changing.
- No product source was changed by this reviewer. No build or release of the user's app was performed. The isolated diagnostic app has its own simulator bundle identity.
- Web research used Apple lifecycle, sheet-interaction and key-window documentation. External documentation establishes platform semantics; local code and runtime evidence establish the actual defects. No third-party workaround was adopted.
