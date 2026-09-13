# README design research

Status: research landed; public README (EN/ZH), MIT license, and GitHub facade published 2026-09-13. Keep using this file for positioning and benchmark decisions—do not invent capability claims.

## Evidence and limits

Snapshot: 2026-09-12. Repository counts and pushed dates came from the GitHub REST repository endpoint. Read the checked-out READMEs and inspect their linked hero assets. Shallow clones were inspected outside the product workspace. Upstream feature descriptions below are claims, not independently tested integrations. A push date is repository activity, not a release or verified maintenance quality. Stars show accumulated attention, not README conversion or product reliability.

| Reference | Stars | Latest repository push (UTC date) | Role |
|---|---:|---|---|
| [Agentation](https://github.com/benjitaylor/agentation) | 4,648 | 2026-06-07 | Primary editorial reference: direct agent-feedback workflow with substantial attention |
| [AnnotateKit](https://github.com/Connected-Mate/annotate-kit-ios) | 3 | 2026-07-22 | Closest native iOS comparison; not an adoption benchmark |
| [Shotback](https://github.com/DCCA/shotback) | 0 | 2026-08-25 | Screenshot-plus-request packaging reference; not an adoption benchmark |
| [AA.Annotate](https://github.com/adiladiloglu/AA.Annotate) | 1 | 2026-08-01 | Multiple captures and agent handoff reference; not an adoption benchmark |
| [Sampler](https://github.com/gabrieltmitchell/sampler) | 4 | 2026-09-12 | Closest native iOS workflow comparison; debug-only agent handoff reference |
| [Monad Design](https://github.com/Monadix-AI/monad-design) | 20 | 2026-09-09 | End-to-end visual-development presentation reference; not a drop-in SDK comparison |
| [FLEX](https://github.com/FLEXTool/FLEX) | 14,636 | 2026-06-11 | Established iOS embedded-tool presentation reference |
| [Wormholy](https://github.com/pmusolino/Wormholy) | 2,616 | 2026-05-23 | Established iOS SDK integration presentation reference |

API evidence: `https://api.github.com/repos/{owner}/{repository}`. Refresh before reusing counts as current. AnnotateKit's old repository URL redirects to `Connected-Mate/annotate-kit-ios`. Reachability.swift is too far from the task and is excluded.

## Observations and decisions

### Agentation

Its README uses a logo, package badges, one paragraph explaining the user action, Install, Usage, Features, How it works, Requirements, Docs and License. The checked-out Markdown has approximately 254 whitespace-delimited words including markup/code. It does not have a product demo in that README; do not claim high-star tools universally require a GIF. Borrow the quick route to installation and concrete actions. Its web selector-to-source mechanism is not evidence that EditHere can identify native source files precisely.

### AnnotateKit

The README describes the same native iOS entry-point integration and point-note-agent flow. It gives a short root integration example, agent delivery choices and a sample output. Its hero is a stylized phone illustration with placeholder content, not proof of real interaction. The approximately 2,120-word README repeats provenance and expands into configuration, parity and mechanisms. Borrow the explicit output example and agent connection explanation; do not imitate the illustrated UI, repeated positioning or feature inventory. Its native limitations also make “first/only iOS tool” an unsupported EditHere claim. Do not equate its accessibility hints with guaranteed source locations.

### Shotback

The hero puts numbered marks and a prominent agent handoff action in the same frame. This helps explain both input and destination visually. The README describes image/data/prompt handoff and multi-capture batches. Borrow a concrete numbered-page plus request example. Its approximately 1,960-word README delays quick start behind extensive features; EditHere should keep integration earlier. Do not borrow browser-only capabilities, redaction guarantees, zero-network claims or its sidecar-first image-optional agent workflow.

### AA.Annotate

Its README shows multiple captures and numbered comments, then includes substantial platform installation and agent usage detail (approximately 1,020 words). Borrow clarity about the files handed to an agent. Keep platform mechanics in the integration guide for EditHere.

### Sampler

Sampler is the closest current native iOS comparison: a debug-only floating widget, a tap-to-annotate flow and structured output for coding agents. Its checked-out README is approximately 906 words and leads with “install with your AI coding tool,” then states the Release no-op behavior, shows the shortest package setup and lists the generated files (`report.md`, `annotations.json`, screenshots and crops). The GitHub REST snapshot has 4 stars, 21 commits and a latest push on 2026-09-12; these values are time-sensitive. Borrow the direct first-use path, the explicit debug boundary and the concrete output inventory. EditHere must not claim MCP, a Claude skill, automatic dispatch or Release no-op behavior unless those paths are implemented and tested here. The current file destination is local export and does not execute an agent.

### Monad Design

Monad Design is a broader visual-development workspace rather than an SDK. Its approximately 991-word README uses a short positioning line, a real-looking hero, a video, a numbered workflow and an explicit current-scope section. The GitHub REST snapshot has 20 stars, 108 commits and a latest push on 2026-09-09. Borrow the visible loop—start, reproduce, describe, compare—and the honest statement of what the current version does not cover. Do not borrow claims about editing source, rebuilding the app or comparing implementation variants; EditHere currently captures evidence and exports it through a destination contract.

### Vocabulary and discovery

Across the direct comparisons, the words that explain the category without product-specific knowledge are “visual feedback,” “iOS,” “annotate a running app,” “numbered screenshots,” “structured feedback” and “coding agents.” Use those terms in the opening description and metadata where they are true. Explain “evidence package” after the reader has seen the screenshots and request; do not make that internal term the first sentence. “AI-powered,” “automatic code changes,” “source location” and “return build” are unsupported for the current EditHere core and should stay out of the README.

### Official README guidance

[GitHub's README guidance](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-readmes) says a README should answer why the project is useful, what users can do and how to get started, while keeping long explanations in linked documents. Its [documentation-writing guidance](https://docs.github.com/en/contributing/writing-github-docs/best-practices-for-github-docs) recommends choosing one or two core user tasks, leading with the most useful information, using meaningful headings and keeping the page scannable. The rewrite therefore needs one primary path—integrate once, mark, submit—and one secondary path—inspect the local export—before architecture or historical context.

### Audit of the current README

The current 52-line page is a useful internal smoke description, but it is not yet a public onboarding page:

- The opening uses “destination adapter” and “evidence package” before showing what a developer sees. Start with the running-app action and the numbered screenshot result, then define those terms.
- “Send the whole batch” is inaccurate for the shipped `EditHereFileDestination`; it exports locally and does not execute an Agent. Say “export the whole batch” for the current path and reserve “send” for a verified execution destination.
- The page promises annotated screenshots and a JSON manifest but omits the generated prompt, which is part of the core handoff. Show a small, sanitized output tree instead of a process explanation.
- Requirements are implicit. State iOS 17+, Swift Package Manager and the debug/internal distribution boundary. The package's current remote is a private Forgejo SSH address, so a public README must not invent a public dependency URL.
- The absolute cross-project design path is useful to maintainers but is a dead link for external readers. Link to a repository-local design or product document, and keep cross-project references in contributor-facing docs.
- There is no license file in the package root inventory. Do not add a License badge or promise reuse terms until the licensing decision and file are real.
- There is no verified current product screenshot or icon asset ready for a public hero. A real capture is required before adding a visual; an illustration must not stand in for product evidence.

These are content and evidence gaps, not reasons to change the SDK's behavior. The README rewrite should remain a documentation-only change until a current capture, export tree and distribution channel are available.

### FLEX and Wormholy

Use FLEX's real interaction demo and short entry-point example as presentation references. Use Wormholy's task-oriented feature wording and explicit SDK requirements. Neither is a direct screenshot-to-coding-agent competitor. Their stars do not validate an EditHere positioning claim.

## Proposed EditHere page

Aim for approximately 400–650 English words excluding code; this is an editorial target, not a proven conversion optimum. Keep English and Chinese equivalent.

1. Language switch, name and two short sentences: native iOS visual feedback; numbered screenshots with matching change requests.
2. One compact real demonstration or a pair showing the selected UI and the resulting numbered screenshot/request correspondence.
3. Requirements and the shortest verified integration path, with the package source stated honestly for the current distribution channel.
4. Four concise capabilities: point at a target, collect changes across pages, retain visible-page context, and match image numbers to requests.
5. The real first-use sequence and the fact that Submit is on the Marks list.
6. A short real exported result, including the current local file destination and its generated files. State that automatic execution requires an adapter.
7. Links to the detailed integration guide, sample instructions, product rules and prompt design.

Product facts remain authoritative in [the product knowledge base](../PRODUCT_KNOWLEDGE_BASE.md) and [prompt design](AGENT_PROMPT_CORE_DESIGN.md). Never substitute upstream promises for EditHere behavior. Avoid “first”, “only”, precise source-location guarantees, automatic code edits or return-build claims without evidence.

## Rewrite plan

### Phase 0: unblock the proof

1. Confirm whether this README is for the current private package, a future public mirror, or both. Use a local-package installation example while the public package URL is unavailable; do not expose the private SSH remote.
2. Confirm the license decision and add a real license file before adding license badges or reuse language.
3. Produce one current, full-device capture of the running sample and one real file-destination export. Inspect both before they enter the README. The capture must show the action and result clearly; the export must show only sanitized, stable names.

### Phase 1: write the smallest useful page

1. Open with the user outcome: mark a visible iOS target while the app is running, keep marking across screens, then export one numbered set of screenshots and matching requests.
2. Put the verified visual proof directly below the opening. Add a short caption that explains the number-to-request relationship in plain language.
3. Put requirements and the shortest integration snippet next. Keep optional bindings and destination design in the integration guide.
4. Show the five-step first-use flow, with `Submit` described as the batch action on the Marks list and `EditHereFileDestination` described as local export.
5. Show a compact output tree containing the numbered annotated images, manifest and generated Agent prompt. State that a future execution-capable adapter can hand the same package to an Agent; do not imply that the current file destination edits source.
6. End with links to integration, sample, product rules, prompt design, contribution and license documents that actually exist.

### Phase 2: produce the equivalent Chinese page

Keep `README.md` as the English entry page and add a complete `README.zh-CN.md` with a language link at the top of each page. Translate the user-visible workflow and limits rather than mechanically translating internal type names. Both pages must have the same section order, screenshots, commands, output claims and caveats.

### Phase 3: acceptance before calling the rewrite complete

- Every code block is copied from the current integration guide or checked against the package and sample.
- The install route works for the stated distribution channel, or the page labels the route as local/private instead of pretending it is public.
- The screenshot and output tree come from the current sample; no placeholder illustration, old prompt text, clean original or private path remains.
- English and Chinese links, image paths and headings resolve from a clean checkout.
- A reader can answer “what is it?”, “what do I do first?”, “what files do I receive?” and “does this edit my code automatically?” within the first screenful and the following quick-start block.

The rewrite can be implemented after these inputs are available. Until then, changing README wording would either hide a distribution decision or make an unverified visual claim.

## Material readiness

No usable App Icon was found in the package asset inventory during the initial pass. The existing sample composer capture is a candidate, but current representative captures still need verification. Two newer temporary captures inspected were black frames; older prompt screenshots contain superseded text. None of those should be used as current product evidence. Obtain current real UI and export output before claiming the visual README is complete. Do not fabricate a product screenshot or modify the app merely to match an illustration.

## Next acceptance

Verify the package access path, current integration example and exported files; acquire and inspect real demonstration material; render both languages and check every local image/link. Record any unavailable public installation channel truthfully. Research does not establish star growth, runtime correctness of reference tools, or successful agent execution for EditHere.
