# Agent prompt is the core product

**Must read** before changing how a Submit batch becomes instructions for an Agent, wrapping those instructions in a destination adapter, or claiming that Submit quality is “good enough.” Skipping it treats the overlay as the product, ships a numbered legend without screenshots or hints, splits one batch into many sessions, or hard-codes wording so later quality work requires a schema change.

Status: product ruling 2026-09-12. The collection UI is how developers *capture* intent. **The generated Agent task (numbered screenshots + structured prompt) is how that intent becomes a correct source change.** That generation path is the core capability and must be designed for continuous iteration.

Cross-project architecture still lives in `docs/design/ARCHITECTURE_BOUNDS.md`. This file owns prompt/evidence→Agent packaging. Corral transport wrapping remains in `docs/CORRAL_CLOSED_LOOP_ADAPTER_DESIGN.md`.

## Product rules

- One Submit → one evidence package → **one** derived prompt → **one** Agent session. Later marks in the same batch keep earlier context. A retry of the same batch identity must reuse that session. A later Submit of a **new** batch is a different session. Do **not** print those session rules into the Agent-facing text — the adapter owns them.
- Screenshots are **per frozen page**, not per mark. All marks on one freeze share one numbered composite. A clean capture is kept locally so marks can be redrawn; it is **not** part of the Agent packet, Prompt preview, or prompt catalog (user ruling 2026-09-12: do not send a second unannotated image). Close → use the app → tap the floating entry again starts a new page. There is no required per-mark crop; crops, if added later, are supplemental.
- The developer’s original request text is durable evidence. Generated instructions are a **derived** artifact. Never overwrite or replace the original request with paraphrased Agent copy.
- Numbered badges on the composite **are** the same numbers as in the prompt. That contract is inviolable.
- Runtime observations (visible wording, accessibility name, control type, bounds) may be stored in the package. Print **on-screen wording** (and a human control kind only when wording is missing). Do not print private class names, coordinates, or a lecture that hints are not source identity.
- Submit already authorizes edits. Do not add a plan-approval gate to compensate for a weak prompt. Incomplete or ambiguous marks must say “do not guess” in the packet — without `Completeness:` jargon.
- File export writes the canonical prompt next to the images. That is portability, not execution. An adapter may wrap the canonical prompt (for example: `Page 1: page-1.png`). It must not drop, paraphrase, or replace the core. Do not prefix a lecture such as “open these numbered screenshots before editing.”
- **If a review finds a line that does not locate a mark or specify the change, delete that line in the same turn.** Do not ship a quality essay and leave the junk. User 2026-09-12: “你知道元认知了就直接改” then “全面排查写进提示词里的这种废话.”

## Why this is the iteration surface

Image-to-code quality is still an unmeasured feasibility experiment. Improving it will be mostly **prompt and packaging**, not overlay chrome.

Comparable working pattern (inspected 2026-09-12, do not copy web-only fields):

- Numbered overlays on a full screenshot (Set-of-Mark grounding).
- A machine-readable sidecar besides the pixels (Shotback, Snap, and similar “annotate then hand to an Agent” tools).
- Prompt detail as a **regenerable** view of that sidecar, not a one-shot string baked into the capture.

EditHere’s sidecar is the evidence package. The prompt is a versioned view of it.

## Three layers

| Layer | Owner | Frozen? | Iterates by |
|---|---|---|---|
| Evidence package | EditHereCore schema | Yes, at Submit | Schema version only when facts change |
| Canonical prompt | EditHereCore prompt template | No — regenerate from the same package | Code constant only — **never print** `Prompt template: N` |
| Transport envelope | Destination adapter | No | Adapter only: native image parts, absolute paths, “you must open these files” |

Do not put Corral session ids, host paths, or relay URLs into the evidence package or the canonical prompt. Do not put destination-only wrapping into Core.

Regenerating a prompt from an already-submitted package (new template, same screenshots and requests) is an allowed quality improvement. It must not silently start a second Agent session for that batch identity.

## Canonical prompt

The Agent must be able to answer, from this package alone: **which page, which numbered mark, what change.** If the change is not specific, say so and do not guess.

The packet is **only** facts that locate a mark or specify the change. Before adding a line, ask: does this locate a mark or specify the change? If no, omit it. If a review finds a line that fails that test, **delete it in the same turn** — do not leave a quality essay.

Forbidden in Agent-facing text (user 2026-09-12): packing-generation numbers, product branding, session/process instructions, report schemas, lectures about hints, bundle ids, build numbers, markdown section ceremony (`## Task` / `## Rules` / `## Output`), `Request:` prefixes, `Completeness:` labels, and “there is no second screenshot” disclaimers.

Required content:

1. App display name. Source revision when the host supplied one. No bundle id, marketing version, or build number.
2. One sentence describing the marks (blue rounded outline, numbered pill; point = ring and crosshair).
3. One line per **used** page: screen id and mark numbers. No asset UUIDs in the canonical prompt (file export may list `page-N.png` above the text). No clean original.
4. Developer overall instruction when nonempty — verbatim, no heading.
5. Numbered requests matching badges:
   - Developer-typed text verbatim, or one short preset intent line (do not duplicate canned Remove as request + action).
   - `On screen:` when capture has visible wording (including descendants).
   - Accessibility name only when it differs; skip private/`_` ids and UUIDs.
   - Human control kind only when there is no on-screen wording. Never `_UI…` class names.
   - Point marks: outline was not recognized; confirm on the screenshot.
   - If the change is not specific: “Do not guess.” No `Completeness:` vocabulary.

Keep developer-typed text in the language the developer wrote. Framing stays English (Agent default).

Do **not** append a closing lecture such as “If several rows look the same…” or “Change only what is requested.” (user 2026-09-13: filler — the numbered badge already picks the instance; these lines do not locate a mark or specify the change).

### Completeness (when to say “do not guess”)

| Action | Complete when |
|---|---|
| Remove | Always (the box/point is the target) |
| Change text | Developer supplied the replacement, not the empty preset |
| Appearance | Developer wrote a concrete change (color, size, spacing, …), not the empty preset |
| Custom | Non-empty request (empty custom cannot be committed) |

Point-only marks may still be complete as requests. The prompt must say the boundary was not recognized and the Agent must confirm the control on the screenshot rather than inventing a box.

## Adapter wrapping

After the canonical prompt:

- Destinations that paste image **paths** must add an envelope that names **`page-N` screenshot files** (not asset UUIDs) and requires the Agent to open them. A pasted path is not vision proof. Do not paste a clean original.
- Destinations that attach native image parts should still keep the screenshot catalog so mark numbers stay bound to pages. Attach only the numbered composites.
- Never send the text prompt without the numbered composites.
- Never attach a second unannotated copy of the same page.
- Never start one Agent per mark.

## Do not restore (failed approaches)

These were shipped into the Agent-facing text and rejected. Do not put them back:

- A second unannotated original “in case strokes hide detail” (user: 不要留). Keep the clean capture locally to redraw boxes.
- `Prompt template: N` or any packing-generation number (user: “这是啥意思”). The constant lives in code and this doc only.
- Product title (`EditHere change request`), bundle id, marketing version, build number.
- Process blocks the model cannot act on: plan approval, single session, “authorized batch,” report schema (`changed / not changed / unresolved`), `## Task` / `## Rules` / `## Output`.
- Duplicate canned Remove as both request and action; `Request:` / `Completeness:` labels; private `_UI…` class names; UUID asset paths; normalized coordinates.
- Stopping at a written quality review after finding junk (user: “你知道元认知了就直接改” / “全面排查废话”). Cut the lines.
- Closing filler `Change only what is requested.` / `If several rows look the same, edit only the numbered one.` (user 2026-09-13).

## What not to optimize first

- Per-mark cropped images (optional later; full-page context is the primary “where”).
- Asking the developer to approve a plan.
- Per-control source annotations as a prerequisite.
- Treating Agent stop-reason as verified UI change.

## How to iterate

1. Keep the evidence package stable. Bump the **code** packing-generation constant when section layout changes. **Never print that number** in the packet.
2. Replay the same saved packages through the new template.
3. Score **applied UI** (correct control, correct change, unrelated tree preserved, unresolved when appropriate). Do not score fluent Agent prose.
4. Record failures as fixtures (wrong control, guessed appearance, ignored screenshot, split sessions).
5. Fill instance identity for repeated rows when selection can supply it; until then the numbered screenshot badge is the disambiguator — do **not** print a closing lecture about it.

Feasibility experiment 1 in the cross-project design remains the quality gate for “Agents can locate source from numbered pages.” This file does not claim that gate has passed.

## Current implementation

The Agent-facing prompt is a short legend for the numbered screenshots. Internal packing generation **8** must **not** appear in that text. The **host** (`edithere_host/prompt.py`) is the canonical generator for thin clients (Chrome). iOS may still derive the same legend locally for on-device Preview; Submit may upload that text, which the host validates. File export may prefix `Page 1: page-1.png` lines with no lecture. Do not restore process copy. Named-executor dump is wired (`corral-cursor`). Do not re-implement dump in each client.

The preview is a developer inspection of the Agent packet. It must not become a plan-approval step. Back returns to Marks; Submit on Marks still starts work.
