# EditHere product knowledge base

## Purpose

EditHere lets developers mark on-screen UI in a running iOS app and submit a portable evidence package to a destination that can start code changes. The overlay is how intent is captured. **The numbered screenshots plus the generated Agent prompt are the core product capability** — they decide whether the Agent changes the right source. Collection UI and destinations exist to feed that task. It is an independent SDK. Core never imports Corral; the first wired executor for this workspace is `corral-cursor` (see § Project-owned execution configuration). See `docs/design/AGENT_PROMPT_CORE_DESIGN.md`.

## Confirmed product rules

- Developers only; no tester/public feedback roles.
- One-time package install at app/root entry. Per-control source annotations are optional precision helpers, not required.
- Floating button → tap target → request/preset → **Done** → keep marking. **Submit (count)** exists only on the Marks list (the collected-edits screen), never on the write sheet or the selection toolbar. Marks’ **bottom trailing Preview** opens a read-only Prompt page (system push; Back returns to Marks) showing the numbered page screenshots plus the generated Agent prompt. Preview is not Submit and not a plan-approval gate. To mark another screen: Close (or collapse) to use the app, then tap the floating button again. There is **no separate Browse control** — it duplicated Close.
- The write sheet must **not** show a target caption such as `1 · Selected area` (navigation subtitle or an in-sheet label). The canvas outline already identifies the mark. Title stays `EditHere`.
- The write sheet **Quick Actions** menu is a **flat** system menu of request shortcuts only: **Change text** then **Remove element**. No `Request` / `Target` section titles and no extra groups. Each item has a system symbol (`textformat`, `trash`). **Remove element** uses the system destructive style (red title and icon). It must **not** contain target-boundary adjustment (`Larger area`, `Smaller area`, `Use point`). Do not resurrect those as a menu, toolbar, or extra control. Selection is tap; same-point retap walks the ancestor chain. Automatic point fallback remains when no useful bounds exist — that is not a user-facing “Use point” action.
- Full visible-page annotated screenshots are required evidence.
- Entering annotation mode covers the frozen page with a semi-transparent gray scrim at alpha **0.26** (Reduce Transparency **0.38**). **0.40 was too dark**; **0.32 was still a bit dark** (user corrections 2026-09-12). Do not ship the original faint wash, do not return to 0.40 or 0.32, blur the page, or bake the scrim into exported evidence.
- **Marking hint (2026-09-12):** while annotation mode is on and the **current frozen page** has **no blue boxes** yet (no committed outlines on this capture, and no provisional selection), show centered **watermark-style** instructional text — large bold type, light gray at slightly brighter low opacity (~0.42 white), may wrap — English default: **Tap an on-screen element to mark it**. Use a system `UILabel` (not custom-drawn chrome). Prefer wrapping onto two lines rather than shrinking. Scope is **this screen**, not the whole batch: hide once any blue box appears on this freeze; show again on a new freeze with no boxes, or after every mark on this page is deleted and nothing is selected. Do not bake the hint into exported evidence.
- Submit authorizes execution for execution-capable destinations. No plan-approval gate.
- **Fire-and-forget (2026-09-13):** Submit dumps the frozen package to the named executor and assumes that executor finishes. Do not maintain a product task-status machine. Do not wait for or show a result write-back. If work fails or looks wrong, mark again and Submit again — source edits are idempotent. Already-written status/write-back/result plans and code stay dormant and default off; do not continue them.
- Multiple Agent tasks may work on the same project concurrently. EditHere does not require a per-project execution queue or write lock; Agents coordinate their work. Concurrent execution alone is not an acceptance blocker. Do not add a product task-status or result-return system to “keep them independent.”
- Preset **Remove** means “request removing this UI element from the product”, never mutate live business data immediately.
- Core builds and runs with zero Corral code or services.
- **System controls only:** if iOS already provides a standard control or presentation for the job, use it. Do not hand-build or custom-draw a substitute. See § System controls.

## First execution release scope

**Ruling (2026-09-13):** fire-and-forget. Submit hands the frozen package to the named executor and **assumes that executor finishes the requested edits**. Do **not** maintain a product task-status machine. Do **not** wait for, require, or show a result write-back. Source edits are **idempotent**: if work fails or looks wrong, mark again and Submit again. Do not build retry, cancel, recovery, or per-mark result UI to compensate.

The first loop is: phone marks and Submit → host accepts the package → dump to the configured executor. Stop there. One execution destination, one named executor. Same-project concurrent dumps are allowed. The still-open proof is that a real coding Agent consumes the numbered images and edits the intended source. A receiver command hook, marker subprocess, manual edit or passing transport test does not satisfy that proof.

- Do **not** continue implementing task status, result write-back, phone progress/result UI, cancellation, automatic recovery, or verification-fact plumbing.
- Already-written plans and code for those stay on disk. They are **dormant and default off**. Do not wire them into the live path. Do not expand them.
- Do not treat a missing result file, incomplete status, or an interrupted run as a product problem that needs a state machine. Re-mark and resubmit.
- Phone UI stays annotation + Submit. No computer/project configuration, cancellation, reconnect, or result-return chrome.

The delivery order is in [the execution plan](design/AGENT_EXECUTION_PLAN.md). This scope governs the first release; historical lifecycle hardening is not a prerequisite.

### Open dump defects (2026-09-13)

**Submit looking successful while the assistant never received the work is a defect** (假成功).

1. **Fixed 2026-09-13:** Project JSON with no readable executor name now **fails Submit** before persist (`missing_executor`). Unknown names still fail (`unknown_executor`). Do not restore silent accept-without-dump.
2. **Still open:** An older receive program answering the project URL accepts and does not dump. After installing this host, that dump program must be what is listening. There is no dump-version handshake.

Do not claim a dump “applied” sample edits that were already in git from an earlier commit.

Do not claim a dump “applied” sample edits that were already in git from an earlier commit.

**Execution review reports:** name those defects first, in product language. A review that only says the loop is “partial” or “not proven” is incomplete — that framing hid the 2026-09-13 e2e bugs and the user treated the review as empty (白review / 没看懂钉死). Details: [fire-and-forget e2e review](reviews/2026-09-13-FIRE_AND_FORGET_E2E_REVIEW.md).

## Project-owned execution configuration

The first wired executor name for this workspace is `corral-cursor` (Corral-hosted coding session). Project field: `"executor": "corral-cursor"`. Other executors are other names (e.g. `claude-code`), each a full adapter. There is no shared `adapter`/`runtime` config. The host accepts the package and dumps it to the named executor; it does **not** wait for a result file and does **not** mine chat. Write-back, task-status, and result UI in [the adapter design](CORRAL_CLOSED_LOOP_ADAPTER_DESIGN.md) are **dormant and default off** — keep the text, do not implement further. The sample project JSON includes `"executor": "corral-cursor"` now that dump-to-executor is wired.

Execution configuration belongs to the host app's development project, not a phone settings flow. The developer configures the destination and authorized project through project integration; the installed app uses that configuration automatically. Do not add phone controls for choosing a computer or project, connection setup/status management, pairing, reconnecting, or unbinding. Do not require a first-launch QR pairing or project-selection step.

Keep shareable destination/project identity, optional `executor` name, and build/check/delivery instructions in project configuration (`edithere.project.json`). Keep machine-specific checkout resolution and tokens on the development host (`edithere.host.example.json` → local host config). Credentials are provisioned through the project's secure development setup: prefer the environment variable named by `tokenEnv` / `tokenEnvHint` (sample: `EDITHHERE_HOST_TOKEN` / project-scoped `EDITHHERE_TOKEN_EDITHHERE_SAMPLE`), or a gitignored local `edithere.credentials.json` that the sample build phase embeds into the app bundle for cold launches (see `edithere.credentials.example.json`). Never commit real tokens. Never embed unrestricted host or model credentials in tracked files.

Concrete sample format (schema version `1`):

```json
{
  "schemaVersion": "1",
  "projectID": "edithere-sample",
  "displayName": "EditHere Sample",
  "executor": "corral-cursor",
  "receiver": {
    "baseURL": "http://127.0.0.1:8787",
    "submitPath": "/v1/submissions",
    "tokenHeader": "X-EditHere-Token",
    "tokenEnvHint": "EDITHHERE_TOKEN_EDITHHERE_SAMPLE"
  },
  "build": { "scheme": "EditHereSample" },
  "delivery": { "method": "ios-deliver" },
  "acceptance": { "screens": ["sample-home"] }
}
```

The `baseURL` above is the fallback; discovery (`_edithere._tcp`) is the default path. Remote access beyond the LAN (Corral-style relay) is a recorded direction, not implemented — no phone configuration UI for it.

Authoritative examples: `Examples/EditHereSample/edithere.project.json` and `Examples/EditHereSample/edithere.host.example.json`. The phone resolves the receiver via Bonjour (`_edithere._tcp`, TXT `project=<projectID>`) before falling back to the bundled `receiver.baseURL`, so a DHCP address change does not break Submit. Keep the bundled URL current as the fallback. The sample app loads the bundled project JSON and uses `EditHereLocalHostDestination` when a token is available from `EDITHHERE_HOST_TOKEN` or bundled `edithere.credentials.json`. If project JSON is present and the token is missing, install fails with an actionable error — do **not** silently fall back to File Export. File Export is only for the portability demo when project JSON is absent.

Local Host execution upload sends annotated images, `agent-prompt.txt`, and `page-N.png` composites. Clean originals stay on-device for redraw. The claimed `contentDigest` for execution is package JSON plus annotated image bytes only (`EditHereHashing.executionContentDigest`). Host validation must match that contract. Do not claim the dump loop is proven until fake-success defects are gone and a package whose **current** UI does not already match the requests produces a new source change. Current ledger: [fire-and-forget e2e review](reviews/2026-09-13-FIRE_AND_FORGET_E2E_REVIEW.md). The 2026-09-12 execution delivery review records older status/write-back faults; those paths stay dormant — do not resume them as the fix.

The phone captures marks and submits. It does not own a task-status or result-return product. If the change did not happen, mark again and Submit again. Configuration changes are made through the project/host setup. Missing configuration must be actionable for the integrating developer without asking the phone user to bind a project.

## Module boundaries

| Module | Owns | Must not own |
|---|---|---|
| EditHereCore | Schema, drafts, outbox, destination protocol | UIKit overlay, Corral APIs, model calls |
| EditHere | Floating UI, selection, capture, session | Destination transport specifics |
| EditHereFileDestination | Local export + checksum validation | Agent execution |
| EditHereLocalHostDestination | HTTP submit/lookup/cancel to development-host receiver | Annotation UX / Corral |
| Future adapters | Auth, transport, task mapping | Annotation UX / evidence schema changes |

## Evidence package

`manifest.json` + `assets/*`. Schema version `1.0.0`. Destination-specific fields cannot become required core fields. Store destination identity on submitted outbox records so changing the default destination does not reroute retries.

## Agent prompt after Submit

**Must read** before changing the generated submit text, wrapping it for an execution destination, or claiming an agent can locate and edit from Submit alone. The numbered full-page screenshot is the primary “where”; the text is a legend, not a source map. Image-to-code accuracy is still an unmeasured feasibility experiment — do not treat fluent prompt prose as proven edits.

The Agent packet contains **only** facts that locate a mark or specify the change (authoritative detail: `docs/design/AGENT_PROMPT_CORE_DESIGN.md`):

- Put **on-screen wording** on each mark (`On screen:`), including text on descendants of the selected control.
- If you find a line in the generated prompt that does not locate a mark or specify the change, **delete it in the same turn**. Do not write a review and leave the junk (user 2026-09-12: “你知道元认知了就直接改” / “全面排查废话”).
- Developer-typed text stays verbatim. Preset Remove is one short intent line.
- Forbidden in the packet (user 2026-09-12): packing numbers (`Prompt template: N`), product branding, session/process instructions, report schemas, lectures about hints, bundle ids, build numbers, `## Task` / `## Rules` / `## Output`, `Request:` prefixes, `Completeness:` labels, coordinate dumps, private class names, UUID asset paths, and “there is no second screenshot” disclaimers.
- If the change is not specific, say do not guess — without completeness jargon.
- File export may list `Page 1: page-1.png` above the legend. A pasted path is not proof the agent saw the screen.
- If several rows look the same, the numbered box is the instance.

Do not add a plan-approval gate to compensate. Keep the original request text next to any generated instructions.

The generated Agent task is a **core product capability**, not a side file. Authoritative packaging, packing-generation (code-only), and iteration rules: `docs/design/AGENT_PROMPT_CORE_DESIGN.md`. Skipping that doc prints packing numbers or process lectures, reviews junk without cutting it, ships a numbered legend without a screenshot catalog, or splits one batch into many sessions.

### One Submit, one task, shared page screenshots

**Must follow** when changing Submit packaging, capture lifetime, or claiming how many Agent sessions a batch starts.

- One Submit ships **one** evidence package and **one** generated prompt covering every mark in that batch. Product rule: that becomes **one** Agent session, not one session per mark, so later marks keep earlier context. File export already writes a single prompt file. `EditHereLocalHostDestination` submits that package to the development-host receiver; retries of the same batch identity must reuse that task, never open a second session. A later Submit of a **new** batch is a separate task.
- Screenshots are **per frozen page**, not per mark. Tapping the floating entry captures the current visible viewport **once** and freezes it. Every mark committed on that frozen page shares that capture. A clean copy is kept **locally** so boxes can be redrawn when marks change. The Agent packet, Prompt preview, file-export folder handed to an Agent, and prompt catalog include **only** the numbered composite (all of that page’s boxes/points). Do **not** send or show a second unannotated screenshot (user ruling 2026-09-12). Close → use the app → tap the floating entry again starts a **new** capture. A batch can contain several pages; Submit then includes one numbered screenshot per used page, plus the full numbered request list. There is no per-mark crop in the current package.
- Do not recapture on every mark. Do not attach a private full-page image to each annotation. Do not treat an unmarked freeze (entered annotation mode, then left without a mark) as useful evidence — prune unused captures before Submit writes the package.
- An agent can understand the screenshots if it **sees** the numbered composites and matches badge numbers to the prompt list. Marks are system-blue rounded rectangles (~2 pt stroke, no fill) with a white number on a blue pill at the top-left of the box; a point mark is a blue ring and crosshair with the same pill. Same-page marks on one image is the intended layout context. Put the visible wording of the marked control into the prompt. That image-to-code hop is still unmeasured. A pasted image path is not proof of seeing. Do not attach a clean original “in case the boxes hide detail.”
- **Prompt preview (2026-09-12):** Marks bottom trailing Preview shows that packet before Submit. Flush evidence first so numbered composites exist. Show only the numbered page images plus the prompt text — no clean original. Decode preview images only onto the preview screen — never onto the frozen canvas. No extra confirm on the preview page.

## Selection

UIKit hierarchy traversal inspired by FLEX’s candidate collection and overlay exclusion. Prefer semantic controls over leaf labels only among **visually unoccluded** hits. Same-point retap walks the **ancestor chain**, not a flat sibling list. There is **no** Larger/Smaller/Use point control. If no useful bounds are found, keep a numbered point marker and still allow submit. Capture pixels and the candidate snapshot are taken together for the active host scene; do not re-query the live tree against a frozen image.

## Continuous marking (latency)

**Ruling (2026-09-12):** Done → immediately mark the next control must feel instant. A ~1s hitch after finishing a mark is a defect, not “selection being careful.”

- Press-down to a visible new outline must complete in **under 100 ms**. That budget applies on the frozen page itself and when the occupying card is **closing** after Done. It does **not** apply while a presented card is still up. Yielding one frame and then encoding on the UI thread is **not** async; it still stalls the next press.
- Full-page annotated PNG encode, checksum, and draft disk write **must not** run on the tap/Done turn or on the UI thread during marking. They run after a short idle, on background, or immediately before Submit. Submit still waits until every capture has a complete annotated screenshot. A cancelled idle wait must abort; do not treat cancel as success and keep encoding into the next press.
- **Ruling (2026-09-12):** while any presented interaction is up (write composer, Marks, alert, menu hosted in that card, or any other occupying popup), the frozen page behind it must **not** accept a new annotation target. This is not limited to typing or the Marks list — if a card is occupying the interaction, a tap on the screenshot must not move the numbered outline. Do **not** put the frozen canvas in the popover’s passthrough list to “keep marking.” Those taps must still be claimed so they do not reach the live host, and they must not dismiss the write composer. Closing the write sheet must not swallow the next canvas press: if the developer presses a new target while the card is animating away, keep that selection, draw the outline immediately, and present the write sheet when the dismiss finishes. Do not require a second tap. This supersedes “undimmed canvas retarget while the write sheet is still up” and the functional-review acceptance that tapping the uncovered canvas should change the target.
- Live preview stays the original capture plus vector outlines. Do **not** decode an export PNG onto the canvas (zoom/crop defect) and do **not** redraw the full screenshot on every selection change — keep a still image layer and a cheap marks layer. Do **not** rebuild the canvas or bottom bar on every keystroke.
- Entering annotation mode shows the in-memory capture first, then encodes the original PNG in the background. Do not block the first freeze on PNG encode.
- Drive the outline on the same press turn. Do **not** wait for a “state will change” publisher and then hop another run-loop / task before drawing — that delay is the hitch.
- Headless proof: committing or retargeting several marks on one frozen page must not encode an annotated PNG on that turn; Submit (or an explicit evidence flush) then fills the export images. Device feel is still the user’s check on iPhone Max — tests are not silk.
- **Frozen-canvas gray scrim (2026-09-12):** entering annotation mode covers the captured page with a semi-transparent gray mask so the screen reads as frozen, not live. Accepted depth: black scrim at alpha **0.26** (Reduce Transparency: **0.38**). The original wash was too light; **0.40 was too dark**; **0.32 was still a bit dark** — do not restore those. The screenshot underneath must stay readable; do not blur, run a desaturation filter, or use a night-mode alpha (≥ 0.6). This is canvas treatment, not chrome — a plain filled view under the numbered outlines. Do **not** bake the scrim into exported evidence. Do **not** add a second dim for the system write sheet. This supersedes the earlier “no wholesale dimming” / “do not darken the canvas” wording wherever they would remove this mask or keep it as a faint wash.
- **When the user asks to deepen or lighten that mask:** change the existing `CanvasScrim` alphas and the matching test assertion, then stop expanding the task. The fill already exists on the frozen canvas. Do **not** search the tree for a missing overlay, invent a second dim, reopen overlay hit-testing, or treat “no historical grayscale filter” as a blocker.

## Marks list revision (2026-09-12)

Implement this directly with standard UIKit controls; do not introduce another list framework, abstraction layer, or timing workaround for this screen. The user rejected the current Marks popup list and its diagonal, upper-left deletion motion. Rebuild the entire list with system list cells, spacing, separators, swipe actions, and empty state. The destructive swipe action displays only the trash symbol, without visible Delete text; retain an accessibility label. Do not layer a custom move/scale transition or delayed timer over system row deletion. Repeated swipe-delete visual acceptance remains pending on iPhone Max. Sample build 21 passed the device build, installed on iPhone Max with version readback, and launched. AppShelf upload was attempted independently but failed; this is not a shelf release or visual acceptance.

## System controls

**Must follow** whenever adding, changing, or reviewing any user-visible EditHere chrome. Recorded 2026-09-12 after the user rejected hand-built bars/sheets and leftover custom list chrome (red hairline after delete, swipe-to-delete that cannot continue).

**Rule:** if iOS already provides a standard control or presentation for the job, EditHere must use that control. Hand-building, stacking views, or custom-drawing a substitute is forbidden.

Use the system control for at least:

| Job | Use |
|---|---|
| Bottom/top actions | System toolbar or navigation bar items |
| Write/request surface | System sheet, or system popover when a fully detached rounded composer is required |
| Secondary actions | System menu (`UIMenu` / `UIAction`) with SF Symbols. Destructive items use `.destructive` (system red) and sit last. No invented section titles when there is only one group. |
| Collected marks | System list (inset grouped), system swipe-to-delete, system empty state. Prompt preview is a pushed system screen on that same navigation stack. |
| Marks secondary action | System toolbar trailing **Preview** (flexible spacer so a lone item does not center). Do not paint a floating button. |
| Confirm / result / error | System alert or equivalent system feedback |
| Entry control | System button configuration, not a painted disk |
| Text input | System text view / text field |

Forbidden:

- Rounded stacks or plain views imitating a toolbar or sheet
- Extra backgrounds, corners, or shadows on system bars and sheets
- Self-drawn list rows, separators, section cards, or empty-state chrome
- Driving swipe-to-delete with a custom row-delete plus delayed full reload that leaves destructive fill (red hairline) or blocks the next swipe
- Introducing SwiftUI only to claim “native” while still wrapping custom chrome; either UIKit or SwiftUI is native only when the **container** is a system list/bar/sheet

**Sole exception:** the numbered selection outline on the frozen screenshot. No system control marks a region on a captured image. Do not expand this exception to chrome, lists, or buttons. The frozen-canvas gray scrim is not a second exception for drawing: it is a plain filled view under the outlines (see Product intent).

If a future control has no system equivalent, record the exception in this section before drawing it. Unlisted exceptions are not allowed.

## Product intent (accepted)

- Developer-only; one-time app/root integration; no per-control instrumentation required.
- Tap to select whole visible control where possible; point fallback without drawing.
- Typed request or meaningful shortcuts; multi-mark batch. The write sheet’s trailing action is **Done** (flush this mark, stay in annotation mode, pick another target). **Submit** is only on the Marks list and starts modification for the whole batch. Marks also has a system toolbar **Preview** (trailing, one leading flexible spacer) that pushes the Prompt preview; it must not sit on the write composer or the selection toolbar.
- Full visible-viewport annotated screenshots required.
- Entering annotation mode covers the frozen page with a gray scrim (alpha **0.26**; Reduce Transparency **0.38**). Do not ship the original faint wash, do not restore **0.40** or **0.32**, and do not bake the scrim into exported evidence.
- Entering annotation mode shows centered **watermark-style** light-gray text (**Tap an on-screen element to mark it**; large, bold, slightly brighter low opacity, may wrap) while the **current frozen page** has no blue boxes. Hide when this page has any blue box (provisional or committed); show again on a new empty freeze or after deleting every mark on this page with nothing selected. Other pages’ marks do not count. System `UILabel` only; never in exported evidence.
- Fully independent of Corral in the SDK core; the first computer-side executor for this workspace is `corral-cursor` (optional install; detailed design in `docs/CORRAL_CLOSED_LOOP_ADAPTER_DESIGN.md`).
- Annotation UI **must** use real system presentation. Do **not** hand-build rounded panels that imitate toolbars/sheets, or any other substitute where a system control exists. Authoritative visual direction: § System controls below and `docs/reviews/2026-09-12-NATIVE_UI_REVISION.md` (supersedes the custom layout study aesthetic and the earlier “accepted §5 composition” wording wherever they conflict). Interaction/evidence rules from the earlier review still apply.
- The selection-mode bottom bar is a real `UIToolbar`. It **must** appear and disappear with the system toolbar-item transition (`setItems(_:animated:)`), plus a short settle from the bottom. User-accepted 2026-09-12 (flash-in and over-wide trailing gap). Do **not** flash it in by toggling `isHidden` with the items already installed — that skips the system dissolve. Start from empty items, unhide, then `setItems(_:animated:)`; on show set opacity to fully visible immediately so that dissolve is not hidden behind a second fade. **Ruling (2026-09-12):** Close is trailing / 靠右. **Marks** sits immediately to the left of Close (opens the collected-edits list, where Submit lives). The Marks title is **`N Marks`**, not `Marks N`. One leading flexible spacer so both items trail together. Do **not** put Close leading. A second flexible spacer between Marks and Close is not “a little more space”: it is equal-width columns and parks Marks in the center of the screen. Do **not** put Submit on this bar. Do **not** wrap the overlay root in a navigation controller just to call `setToolbarHidden` — that extra full-screen view claims host touches (see the functional review). The overlay has no navigation owner, so Apple’s documented path is the standalone toolbar plus `setItems(_:animated:)`. Reduce Motion keeps the same layout and uses a short fade with no slide.
- The write composer stays a **short compact strip** (nav + request field + **Quick Actions**). **Marks is not on this card.** It lives only on the selection-mode bottom bar (the bar visible after Done / before picking a target). Tapping Marks on the composer was a duplicate entry and pushed a duplicate list into the same card; both are forbidden (user correction 2026-09-12). The trailing control’s visible title is **Quick Actions**, not **Actions** (user correction 2026-09-12). **Quick Actions stays trailing / 靠右** — the same end of the bar Marks used to occupy. A lone toolbar item centers; do **not** center it, and do **not** move it leading after Marks is gone (user correction 2026-09-12). One leading flexible spacer; Quick Actions is the only titled item. Tapping a target opens the keyboard immediately and the card **slides up with the keyboard at keyboard speed**. Do not flash the card in, and do not play a slower popover animation then the keyboard. **Not yet accepted (2026-09-12):** wrapping present/dismiss in a shorter `CATransaction` duration did not change what the user saw (“一点效果没有”). Do not report this motion done without a full-device screen-record. The keyboard-speed requirement still stands. Request first responder after the appearance has started (not before `super`, not after present completes). Make the overlay the key window only for typing; restore the host when the composer dismisses. **Ruling (2026-09-12):** when the card must show four rounded corners with frozen-page background in the gap, present it as a **system popover** (no arrow). Keep the iPhone adaptive style `.none` so it does not collapse back into a sheet. A compact `pageSheet` / custom detent cannot do this: sheet chrome always extends white down behind the keyboard. Extra toolbar clearance only moves the buttons; painting a fake lower radius on that leftover white is not a system control. Keep the proportions compact: **8 pt** side margins, **8 pt** internal bottom padding, **8 pt** external gap above the keyboard. **Ruling (2026-09-12):** keep the **system popover’s rounded rectangle** with the default **opaque** system fill. A see-through / 80% translucent composer was tried on device and **rejected** (user: 半透明不好看). Do **not** restore a translucent popover fill, `UIColorEffect`, clear inner chrome, or transparent nav/toolbar to chase see-through. Do **not** walk presentation wrappers, clear `_UIPopoverView` layers, or set chrome subview alpha — that squared the card. Do **not** subclass a custom popover background or paint a second rounded card. Marks stays on its own presentation and is not this card. Do **not** restore the 16 pt sides / 32 pt bottom that followed the first detached popover — the user rejected that extra air as a tall card with oversized outer margins. **Quick Actions** stays a native system toolbar item with a visible gap above the keyboard, including its suggestion row. Measure rendered buttons, not only the toolbar frame or the keyboard key-grid accessibility frame. Do not replace the toolbar with a stack of configured buttons. Do not wait for keyboard dismissal before opening Marks from the selection bar. Do not translate the presented card, add keyboard height to a sheet detent, use `.medium` / `.large`, or attach Quick Actions through `inputAccessoryView`. Keep fields above the toolbar and constrain the toolbar using the content view's keyboard guide. This supersedes “bottom meets the keyboard top”, “raise the same card”, “aim for at least 16 pt of visible clearance” as a padding target, treating extra sheet padding as a rounded rectangle, and putting Marks on the write composer.
- The write sheet’s trailing navigation action is **Done**, not Submit. Done dismisses the keyboard and sheet, keeps the current request, and returns to the frozen canvas so the developer can mark another target. Submit stays only on the Marks list as the single batch action. This supersedes earlier “Submit on the write sheet / selection toolbar” wording.
- **Ruling (2026-09-12):** the user cut target adjustment from the composer shortcuts. **Quick Actions** is a flat menu: **Change text** (text symbol) then **Remove element** (trash, system red). No `Request` / `Target` headings. Do not restore `Larger area` / `Smaller area` / `Use point` (or a Target submenu) from the native-revision or implementation-review sketches. Those reviews are superseded on this point.
- The write sheet does **not** repeat the selected-target caption (`N · Selected area`, control name, or the same string as a navigation subtitle). That text adds nothing on the composer; the numbered outline on the frozen canvas is the identity. Navigation title remains `EditHere` only.
- The write sheet **Quick Actions** menu is request shortcuts only. It does **not** adjust the selected region. Items need familiar system symbols; **Remove element** is destructive.
- Native chrome has a **lifecycle contract**, not just a look. Authoritative defects and acceptance: `docs/reviews/2026-09-12-FUNCTIONAL_REVIEW.md`. Required:
  - One overlay window. Present the write sheet from that window’s root controller. Do **not** create a second higher window for the sheet (system undimmed/passthrough only applies to views in the presenting window, not across windows). A presented card occupying interaction must **not** retarget the frozen canvas behind it.
  - Store write-panel configuration and apply it after the view exists inside its navigation controller. Do **not** force-unwrap bar buttons in `configure` before `viewDidLoad`.
  - In idle, the overlay window must return no hit for host content. Never treat a hidden canvas as a hit target. Only annotation mode’s visible frozen canvas owns the remaining points.
  - Swipe-down, Collapse, Close, and programmatic dismiss share one cleanup path that flushes the typed request, clears the provisional selection, and returns the live app. The floating entry remains for the next capture in the same batch. Do **not** add a Browse button next to Close.
  - Deleting a mark uses the **system list swipe only**. The list must display a **local row snapshot**. Do **not** let the session’s change publisher rebuild the list on the same turn as the swipe, and do **not** mix swipe-to-delete with a custom row removal plus `reloadData`. Either mistake leaves the destructive fill as a red hairline (even when rows remain) and blocks the next swipe. Session removal and evidence PNG stay after the swipe animation. Empty list is a system empty state with zero leftover swipe views. Do **not** custom-draw list chrome, separators, or empty states. Live canvas outline/number is the only bespoke drawing. Failed path: `docs/troubleshooting/2026-09-12-annotation-chrome.md`.
  - Live preview draws the captured image in the overlay’s bounds. Keep the original capture for the canvas. Do **not** assign a PNG decoded with `UIImage(data:)` onto the live canvas (that decode is scale 1 / pixel size) and do **not** draw at `UIImage.size` when that size might be pixels — that is the “annotation zoomed and cropped” defect.
  - Marks opens **only** from the selection-mode bottom bar, as its own presentation. Do **not** put Marks on the write composer, and do **not** push the list onto the composer’s navigation stack (duplicate entry and duplicate panel; user correction 2026-09-12). While the composer is up, the selection bar is hidden — finish the mark with Done, then use Marks. Updates while the list is visible must not refocus a hidden editor.
  - Submit success, failure, and capture/draft errors must be visible. A model-only `statusMessage` is not enough. Local file export is **not** “source modified.”

## Current implementation status

Shipped (2026-09-12 review remediation wave):

- Core schema, draft store, outbox, submitter, file export, sample app
- Single screenshot-pixel geometry for preview/export (`EditHereGeometryTransform`); no double-scale marks
- Capture + candidate snapshot frozen together on one host scene
- Occlusion-aware selection; same-point retap follows ancestry. Actions has no target adjustment.
- Active draft flush on retarget / Close / Done / collapse / Submit from the Marks list
- Annotated images regenerated from stored originals; **not** on the same turn as list swipe-delete, tap, or Done
- Continuous marking: outline on press-down; evidence PNG/hash/persist off the interaction path; original PNG encoded after the frozen canvas is shown
- Submit takes an immutable snapshot, opens a new batch immediately, single-flight + content-digest outbox identity
- Compact select toolbar + write sheet + Marks list was an interim redraw; **native UI revision** replaces custom stack/sheet chrome with system toolbar + a compact system surface. The accepted write composer is a **system popover** (no arrow; compact 8 pt margins), not a `pageSheet` that draws white behind the keyboard. First rewrite was reverted in design: keep ComposerView deleted, but do **not** resurrect the second sheet window or pre-load `configure` crash. See `docs/reviews/2026-09-12-FUNCTIONAL_REVIEW.md`.
- Agent UI verification: if a physical phone is online, install, test, and capture on that phone. Do **not** boot Simulator while a phone is available. Simulator is allowed only when no physical device is online. Sample build 21 was installed and launched on iPhone Max; the compact no-arrow composer, full lower corners and 8 pt spacing were visually accepted on the device. AppShelf upload failed independently (exit 97), so no shelf release is claimed.
- Browse control removed (duplicated Close). Next screen: Close, use the app, tap the floating entry.
- Frozen-canvas zoom cause identified: decoded PNG must not replace the live capture; draw in overlay bounds.

Still open (user-visible, do not claim accepted):

- Marks list swipe: sample build 5 still showed a red hairline with remaining rows and could not delete the next row. Switching to a system list was not enough while the list still rebuilt from the session publisher on the swipe turn. **2026-09-12:** the later SwiftUI row-stack list was also rejected for its deletion motion. The replacement is a system inset-grouped table with default cells, icon-only swipe deletion, and session mutation after the system batch animation completes. No timer-based resync or same-turn `deleteRows` + `reloadData`. Confirm on device by deleting several rows in a row with no leftover fill.
- Continuous marking hitch on device: sample **build 10** installed on iPhone Max after the off-turn encode split. Do **not** claim silk until the user confirms Done → next press outlines immediately. XCTest only proves encode is not on the tap turn.
- Keyboard-on-tap latency and composer slide: sample **build 23** was installed and launched on iPhone Max, but the agent did **not** capture the motion — only install/launch. The user reported no visible change. Do **not** claim accepted. Install/launch is not UI verification; recapture the affected screen or recording before claiming the card slides with the keyboard.

Still open before claiming “ready for source-writing processors”:

- Richer recovery/reconcile worker (F7 beyond single-flight + digest reuse)
- Full keyboard/rotation/multi-scene device acceptance; Undo polish; installer single-flight
- Measured feasibility experiments 1–7
- Dump-to-executor for `corral-cursor` is wired on accept/replay. Image-to-code proof on a real package is still open. Do **not** continue write-back, task-status, or result UI; those stay dormant and default off.

Not ready:

- Claiming Corral/Cursor closed loop from design or Local Host tests alone
- Treating “agent stopped” or a missed Simulator click as a verified UI change
- Shipping a chrome replacement after deleting the working surface (keep the old path until the system replacement is on a running build)

## Corral closed-loop

See `docs/CORRAL_CLOSED_LOOP_ADAPTER_DESIGN.md` (corrected) and the review §4.4. Adapter stays in Corral iOS host. Do not require JPEG; path-paste is not vision proof.
