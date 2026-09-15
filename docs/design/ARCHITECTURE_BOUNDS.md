# Architecture bounds

Public summary of non-negotiable boundaries for EditHere. Product behavior details live in [PRODUCT_KNOWLEDGE_BASE.md](../PRODUCT_KNOWLEDGE_BASE.md). Cross-platform split: [CROSS_PLATFORM_ARCHITECTURE.md](CROSS_PLATFORM_ARCHITECTURE.md).

## Shared server, per-platform capture

- Capture UI is per client (iOS overlay, Chrome overlay, later Android). After a mark exists, prompt assembly, packet wrapping, and named-executor dump belong to the local host (`Tools/edithere-host`).
- Do not add a JavaScript (or other) runtime that iOS or Android must call. Clients serialize the evidence package and POST it.
- Chrome and other thin clients may omit `agent-prompt.txt`. The host generates the canonical prompt. iOS may still upload a prompt; if present it is validated, not silently rewritten.

## Independence

- EditHere is fully decoupled from Corral. Corral (or any other agent host) is an optional destination adapter only.
- Core capture, selection, annotation, drafts, and the evidence package must build and run without Corral code, services, accounts, or project identifiers.
- Optional adapters own transport, credentials, and executor mapping. Those fields must not become required core fields.

## Integration

- One-time app-entry install on native clients. Normal use must not require per-control source edits.
- Development / internal builds are the default audience for the floating control. Do not ship it to production App Store users unless that is an explicit product decision.

## Evidence and Submit

- Every submission includes full visible-page annotated screenshots plus a generated Agent prompt that matches the numbered marks.
- File export proves portability. Execution destinations dump the frozen package to a named executor (fire-and-forget). Task-status machines, result write-back, and result UI stay dormant and default off.
- Feasibility ideas that are not yet proven must not be described as shipped guarantees.

## System chrome (iOS)

- Prefer system controls for toolbars, sheets, lists, menus, and alerts. The only custom drawing is the numbered selection outline on the frozen screenshot.
