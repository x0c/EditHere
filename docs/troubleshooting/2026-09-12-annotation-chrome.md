# Annotation chrome pitfalls (2026-09-12)

**Must read** before changing overlay hit-testing, frozen-canvas drawing, Marks list delete, write-sheet presentation, or declaring a tap “did nothing.” Authority for product rules remains `docs/PRODUCT_KNOWLEDGE_BASE.md`. This page is the EditHere failed-path list so the next Agent does not rediscover them.

## Do not ship a replacement until the old path still works

Do not delete a working write surface or toolbar until the system replacement has been seen on a running build. A broken rewrite plus a deleted fallback is a total outage.

## One overlay window; present the sheet from its root

Do not create a second higher window to host the write sheet. System undimmed/passthrough only applies to views in the presenting window, not across windows. Present from the overlay root after it is in the hierarchy. Store write-panel state and apply it after the view loads inside its navigation controller — never force-unwrap bar buttons in `configure` before `viewDidLoad`.

Do not make the overlay the key window when the floating entry is tapped. The installer only unhides it. **Do** make it key when the write composer needs the software keyboard, then restore the host when the composer dismisses. Apple only shows the keyboard in the scene’s key window.

The floating entry needs an explicit point-size constraint. Removing the size makes the button vanish.

iOS 18 may hit-test the same point twice. Compute once per event; a second uncached pass can swallow a pass-through.

## Keyboard waits until the card finishes appearing

Symptom: tapping a control to mark it shows the composer, but the keyboard arrives a beat later. The user may have to wait or tap the field. Product rule: tapping a target opens the keyboard immediately.

Cause: first responder ran in `viewDidAppear` and in the `present` completion, after the popover animation. The overlay was also not the key window until something else promoted it.

Forbidden:

- Waiting for present completion or `viewDidAppear` before focusing the request field
- Focusing before `super.viewWillAppear`, or calling `makeKey()` before `present` — both skip the bottom slide and flash the card in place
- Leaving the overlay non-key while asking a text view to show the keyboard
- Making the overlay key when the floating entry is tapped, or leaving it key after Close / Done
- Stretching the card to the slower default popover duration, or dropping animation to chase keyboard latency

Required: after `super.viewWillAppear`, request first responder so the popover already has its from-frame and the keyboard starts at stock speed (~0.25s). The card rides `keyboardLayoutGuide` with that keyboard animation. Promote the overlay to key window in that same focus, not before `present`. Restore the host when the composer dismisses. Keep `present(animated: true)` and match presentation duration to the keyboard; do not skip the slide.

## Overlay hit-testing

Idle: only real SDK controls (entry button, visible toolbar) claim hits; empty overlay background must pass through to the host. Annotating: the visible frozen canvas is a real subview and owns remaining points. Never return a hidden canvas as a hit target. Do not route by “mode” in a way that swallows host scrolling.

**Presented card locks the canvas (2026-09-12):** while the write composer, Marks, an alert, or any other occupying popup is up, a tap on the frozen page must not move the annotation target. Symptom: typing or browsing Marks, then tapping the screenshot behind still jumps the numbered outline. Cause: the write popover listed the frozen canvas in `passthroughViews`, and overlay hit-testing treated “a sheet is presented” as permission to retarget. Forbidden: restoring that passthrough so the developer can “keep marking” under a live card; letting those taps fall through to the host app; dismissing the write composer because the screenshot was tapped. **Required:** claim the tap, ignore it for selection, keep the card. After Done starts dismissing, the next canvas press is still kept — do not require a second tap. On-device proof uses the same sample with `-EditHereCanvasLockProbe` (console + full-device screenshot) when a phone is online; Simulator only if none. Do not install a UI-test runner. Product rule: `docs/PRODUCT_KNOWLEDGE_BASE.md` § Continuous marking.

## Continuous marking hitch (~1s after Done / next tap)

Symptom: after finishing a mark, the next press on the frozen page does nothing for about a second, then the outline appears. The user may ask whether there is “no async.”

Cause (stack, all required to stall ~1s):

1. Done/retarget committed the mark and only yielded one frame, then decoded, redrew, PNG-encoded, hashed, and persisted **every** capture on the UI thread. A one-frame yield is still the tap path.
2. Closing the write sheet ignored a press that arrived while dismiss was in flight.
3. The canvas `draw` path blit the full screenshot on every selection change.
4. Chrome refresh waited on a “will change” publisher (old values) plus another run-loop hop, so the outline missed the 100 ms press-down budget.

Forbidden:

- PNG encode, checksum, or draft file write on the tap/Done turn
- Regenerating annotated images for unchanged captures
- Assigning a decoded export PNG to the live canvas
- Dropping a canvas press because the write sheet is still dismissing
- Redrawing the frozen screenshot to move an outline
- Rebuilding canvas chrome on every keystroke
- Letting a cancelled idle export finish during the next press
- Calling a one-frame yield “async” while encode still runs on the UI thread

Required: press-down draws the outline on that turn (<100 ms). Export images are idle/background work and must finish before Submit. Keep the original capture in an image view; marks live on a separate layer. If the idle wait is cancelled, abort — do not treat cancel as success and keep encoding. Headless: a multi-mark streak on one frozen page must not increment annotated-export count until evidence flush/Submit. Device silk is the user’s check on iPhone Max (build 10 delivered; do not claim accepted from tests). Product contract: `docs/PRODUCT_KNOWLEDGE_BASE.md` § Continuous marking.

## Frozen canvas zoom (“the whole UI enlarged”)

Symptom: after adding or saving a mark, the frozen page looks zoomed and cropped (titles clipped).

Cause: export regeneration decoded PNG with `UIImage(data:)` (scale 1, size in pixels) and assigned that image to the live canvas, then drew at `UIImage.size`.

Forbidden:

- Assigning a decoded PNG onto the live frozen canvas
- Drawing the capture at `UIImage.size` when that size may be pixels

Required: keep the original capture image for preview; draw it in the overlay’s bounds. Rebuild export screenshots off the UI turn; decode PNG with the capture’s stored scale only for export.

## Marks list swipe (red hairline + cannot delete the next row)

Symptom: after swipe-delete, a red line remains above the grouped card; a later swipe does nothing.

Cause: the swipe animation does not own the row list. Two failed shapes:

1. UITableView mixing system swipe-to-delete with a custom `deleteRows` plus `reloadData` in the same turn.
2. System `List` + `.onDelete` that still observes the session object and rebuilds rows when delete publishes (draft, undo banner, evidence dirty). Encoding PNG off-turn is not enough; a same-turn list rebuild leaves the destructive fill and blocks the next swipe.

Required: use the system table controller and default cell content configuration. Keep visible rows local; remove a row with a single system batch deletion, then mutate the session in its completion. Do not call `reloadData` during deletion, schedule a timed resync, or replace the list from session publishes. Refresh edited content on return from the editor. A normal table batch deletion is supported; the forbidden pattern is deletion plus same-turn full reload.

The user subsequently rejected the SwiftUI row-stack list and its apparent upper-left disappearance. The replacement uses `UITableViewController(style: .insetGrouped)`, default system cells, `UIContextualAction` with a trash image and no title, the system `.fade` row animation, and `UIContentUnavailableConfiguration`. No custom row stacks or animation timers remain. VoiceOver retains a Delete action. Confirm repeated swipe deletes, last-row empty state, and edit/return on iPhone Max; compilation is not visual acceptance.

Official references: [system contextual action title](https://developer.apple.com/documentation/uikit/uicontextualaction/title) and [table batch updates](https://developer.apple.com/documentation/uikit/uitableview/performbatchupdates(_:completion:)).

## Close vs Browse

Close already returns to the live app and keeps the batch. A Browse control is redundant. Do not add Browse. Next screen: Close, use the app, tap the floating entry again.

## Verification

**Do not boot or drive the Simulator to accept UI when a physical phone is online.** After a user-visible change, build a signed sample and `ios-deliver` it to **iPhone Max**. Do not install EditHereSample on Simulator, AppleScript/cliclick the overlay, or treat a missed Simulator tap as a product defect. **Install and launch are not UI verification.** Capture the affected screen or recording on that phone and look at it before telling the user it is done. Simulator is allowed only when no physical device is available.

A successful local file export is not “source was modified.” Named-executor dump is wired separately; file export remains portability only. Open dump defects (fake-success Submit) live in [the fire-and-forget e2e review](../reviews/2026-09-13-FIRE_AND_FORGET_E2E_REVIEW.md), not in this chrome note.

On-device proof of the selection-mode bottom bar (Close trailing, Marks immediately to its left, title `N Marks`) uses the same sample with `-EditHereSelectionBarProbe`. Do not restore Close leading with Marks on the opposite end.

## Write sheet turns into a tall empty card with Quick Actions stuck to the keyboard

Symptom: after typing starts, a huge white sheet fills the space above the keyboard; **Quick Actions** sits on the keycaps. The frozen page disappears.

Cause: the custom detent counted keyboard height twice. A later fix measured only the toolbar frame and the keyboard's accessibility key grid, which excludes the suggestion row. The real keyboard began higher; visible system buttons extended beyond the measured toolbar frame. Replacing the toolbar with a button stack then broke the required system styling.

Required: if the remaining job is only “keep a short strip and keep buttons off the keys,” a custom detent still returns **content height only** and a real system toolbar stays in the content with clearance from the keyboard guide. Do not translate the presented card, add keyboard overlap, select `.medium` / `.large`, or use `inputAccessoryView`. Open the keyboard as soon as a target is selected.

If the remaining job is “rounded rectangle floating above the keyboard,” stop padding the sheet — see the next section. Product spacing and styling authority: `docs/PRODUCT_KNOWLEDGE_BASE.md`.

Use an opt-in in-app probe when a separate test runner is prohibited. Wait for settled layout and inspect all rendered toolbar descendants. Do not accept only a notification-time measurement or the keyboard key-grid accessibility frame. A saved app-window image may omit the out-of-process keyboard, so full-device visual evidence remains necessary.

## White sheet glued to the keyboard (missing lower rounded corners)

Symptom: Quick Actions already sits above the keys, but the card still looks connected to the keyboard. The lower corners are missing; a white slab fills the gap; the frozen page does not show through.

The rejected sheet geometry is preserved in [the failed-path capture](../reviews/implemented-ui-native-sheet-2026-09-12.png) for comparison. It is evidence of the symptom, not an acceptance screenshot.

Cause: `pageSheet` / custom-detent chrome extends behind the keyboard. Extra toolbar-to-keyboard clearance only moves the buttons. Painting a fake lower radius on that leftover white is not a system control.

Forbidden:

- Treating “add more bottom padding” as the fix for a connected white slab
- Replacing the system toolbar with stacked glass buttons to fake a floating card
- Inflating the first detached popover to ~16 pt side margins and ~32 pt bottom gap (rejected as too much empty space)

Required: present a **system popover** (no arrow). On iPhone keep `adaptivePresentationStyle` as `.none` so it does not convert back into a sheet. Keep compact **8 pt** side, bottom, and keyboard gaps. User-accepted 2026-09-12 on iPhone Max.

## Marks empty state slides below the card

Symptom: tapping Marks on the write composer showed the previous composer page and the empty-state image hanging under the card.

Cause: Marks was a second entry on the composer and pushed onto that compact card after waiting for keyboard hide.

**Superseded (2026-09-12):** Marks is not on the write composer. Open it only from the selection-mode bottom bar as its own presentation. Do not restore the composer Marks button or the in-card push.

## Quick Actions sits in the center

Symptom: after Marks left the composer, the remaining control is centered. User: Actions 怎么变成居中了; then **靠右**.

Cause: a lone titled toolbar item centers. Marks used to occupy the trailing slot.

Required: one leading flexible spacer; **Quick Actions** trailing. Visible title is **Quick Actions**, not **Actions**. Do not move it leading to “fix” the center.

## Composer motion claimed done; user saw no change

Symptom: 一点效果没有 after a keyboard-speed or chrome change; or 正事儿没做 after global docs displaced the product request.

Cause: install/launch treated as verification, or wrapping present in `CATransaction.setAnimationDuration`, which did not shorten the system popover.

Required: full-device screenshot (layout/title) or screen-record (motion) of the affected state. Keyboard-speed slide is still required and **not accepted**. Do not retry the CATransaction-duration wrap as the fix. Finish the open chrome request before process-doc work.

## System controls

If iOS already provides the control, use it. Hand-built substitutes are forbidden except the numbered outline on the frozen screenshot. See product knowledge base § System controls.

## Write composer went see-through or became a square slab

Symptom: the input card shows the frozen list through it, or lower corners disappear.

Cause: translucency (80% fill / `UIColorEffect` / clear inner chrome) was tried and **rejected**. Walking presentation wrappers to change that fill also squared the system rounded chrome.

Forbidden: restoring see-through fill because an earlier experiment existed; subclassing `UIPopoverBackgroundView`; painting a second rounded panel; walking private presentation views.

Required: default opaque system popover. Rounded rectangle, solid fill, no custom backdrop. Product rule: `docs/PRODUCT_KNOWLEDGE_BASE.md` write composer.
