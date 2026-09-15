# Cross-platform architecture

Status: product ruling 2026-09-15. Capture is per client. Prompt assembly, evidence wrapping, and named-executor dump are owned by the local host. Do not introduce a language runtime (JavaScript, WASM, …) that every client must embed.

## Why a host, not a shared client SDK

iOS is Swift. Chrome is TypeScript. Android will be its own stack. Those runtimes cannot import one another. The reusable work after a mark exists is already an HTTP service on the development machine: [`Tools/edithere-host`](../../Tools/edithere-host/).

That host is the shared server for this product. It already accepts packages, checks the executor name, and dumps to the named coding assistant (fire-and-forget). From 2026-09-15 it also **generates** the canonical Agent prompt when the client omits `agent-prompt.txt`, and it answers `POST /v1/preview` without persisting or dumping.

## Split

| Layer | Owner | Notes |
|---|---|---|
| Marking UI, hit-testing, screenshot | Each client | iOS frozen canvas; Chrome live DOM pick; later Android |
| Evidence JSON + annotated PNGs | Each client serializes the same schema | Web-only hints (`cssSelector`, `pageURL`, React file/line) may be stored on `targetHint`. They must not appear in Agent-facing text |
| Canonical prompt | Host (`edithere_host/prompt.py`) | Same rules as [AGENT_PROMPT_CORE_DESIGN.md](AGENT_PROMPT_CORE_DESIGN.md) |
| Digest, accept, dump | Host | Missing/unknown executor still fails Submit (假成功) |
| Coding-assistant adapters | Host executors | First name: `corral-cursor` |

```
iOS overlay ──┐
Chrome overlay ┼── POST package + images ── host (prompt + dump) ── named executor
Android later ┘
```

## Client duties

1. Collect marks (bounds or point, request text, presets).
2. Capture the full visible page and draw numbered outlines on that image.
3. POST multipart `projectID`, `submissionID`, `package` JSON, annotated images. Token header `X-EditHere-Token`.
4. Thin clients omit `agent-prompt.txt` and `contentDigest`. The host fills the prompt, copies `page-N.png`, and computes the digest.
5. iOS may keep uploading a pre-built prompt plus digest; if the prompt is present it is validated as today.
6. Chrome POSTs from the extension background. A content script on an HTTPS page must not fetch `http://127.0.0.1` (mixed content). The host also answers CORS preflight for browser tools that are not mixed-content-blocked.

Preview is `POST /v1/preview` with the same body. It returns `{ prompt }` and does not start work.

## Host duties

- Generate the numbered-screenshot legend (template 8 rules). Never print packing-generation numbers, selectors, or a second unannotated original.
- Fail Submit when the executor name is missing or unknown.
- Dump and assume the executor finishes. Do not add task-status, result write-back, or result UI.
- Successful Submit responses include `meta.executionPath = "named-executor-dump"` (also on `/v1/health`). Thin clients must treat a 200 without that field as an older receiver that accepted without dumping (假成功).
- When the client omits `agent-prompt.txt`, generate it and copy annotated captures to `page-N.png`. When the client uploads a prompt, **validate** it and still materialize `page-N.png`; do not silently rewrite the prompt text.

## What stays iOS-only

System chrome rules, Bonjour discovery, bundled `edithere.project.json` in the sample app, and the frozen-canvas overlay. Chrome uses an options page for host URL, token, and project ID instead of Bonjour.

## Android

Not in this milestone. When added, it is another capture client against this host, not a third prompt implementation.
