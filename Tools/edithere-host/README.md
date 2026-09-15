# edithere-host

Durable local HTTP receiver for EditHere evidence packages. Task `destinationID` is `local-host:{projectID}` (phone clients match that binding).

**Product default (2026-09-13):** fire-and-forget. Accept the package and dump it to the named executor in project JSON (`executor`). Do **not** continue task-status, result write-back, or result UI. Existing status routes, cancel, and worker result-apply stay on disk, **dormant and default off** — they are not the live product path. Missing or unknown executor names fail accept before persist. After installing this host, the process answering the project URL must be this dump program — an older copy still accepts without dumping.

Python 3 stdlib only. No JVM.

## Setup

1. Copy the example config (do not commit real tokens):

```bash
mkdir -p ~/.config/edithere
cp Tools/edithere-host/host.example.json ~/.config/edithere/host.json
# Edit checkout paths / project IDs as needed.
```

Override config path with `EDITHHERE_HOST_CONFIG` or `--config`.

2. Provision tokens. Host-wide default is `tokenEnv` (usually `EDITHHERE_HOST_TOKEN`). Prefer a **per-project** `tokenEnv` under each `projects` entry (example: `EDITHHERE_TOKEN_EDITHHERE_SAMPLE`) so one app credential cannot authorize every project:

```bash
export EDITHHERE_TOKEN_EDITHHERE_SAMPLE="$(openssl rand -hex 24)"
# Optional fallback for routes without a project:
export EDITHHERE_HOST_TOKEN="$EDITHHERE_TOKEN_EDITHHERE_SAMPLE"
```

Never put the token in `host.json`, logs, or git.

3. Check configuration:

```bash
cd Tools/edithere-host
./edithere-host doctor
# or: python3 -m edithere_host doctor
```

## Serve

`serve` also advertises one Bonjour instance per project (`_edithere._tcp`,
TXT `project=<projectID>`), so Sample phones resolve the receiver on the LAN
without a hardcoded IP. `--no-advertise` serves HTTP only; loopback binds
never advertise. `serve --dry-run` prints the advertisement plan.

```bash
export EDITHHERE_TOKEN_EDITHHERE_SAMPLE=...   # or EDITHHERE_HOST_TOKEN
./edithere-host serve
# Override bind: ./edithere-host serve --listen 127.0.0.1:8787
# Serve HTTP only: ./edithere-host serve --no-advertise
# Preview only:   ./edithere-host serve --dry-run
```

This host is the shared EditHere server: thin clients send numbered screenshots and mark JSON; the host generates `agent-prompt.txt` when omitted, then dumps to the named executor. iOS may still upload a prompt; if present it is validated, not rewritten. Invalid uploaded prompts still return `400` / `incomplete_packet`. Missing/unknown `executor` → `400` / `missing_executor` or `unknown_executor`. Accepted tasks start as `submitted` and dump. `--auto-worker` is **dormant / not the live product path**. Browser clients: CORS preflight is answered; Chrome still POSTs from the extension background (HTTPS pages cannot fetch this HTTP port).

Cross-platform split: `docs/design/CROSS_PLATFORM_ARCHITECTURE.md` (from the `sdk-swift` root). Prompt rules: `docs/design/AGENT_PROMPT_CORE_DESIGN.md`.

### HTTP (all responses use `{ok,data,error,meta}`)

| Method | Path | Notes |
|---|---|---|
| `POST` | `/v1/preview` | Same multipart as Submit (`projectID`, `submissionID`, `package`, annotated images). Returns `{ prompt }` and does **not** persist or dump. |
| `POST` | `/v1/submissions` | multipart: `projectID`, `submissionID`, `package`, plus asset files named by relative path; header `X-EditHere-Token`. `contentDigest` and `agent-prompt.txt` are optional for thin clients — the host generates the prompt, copies `page-N.png`, and computes the digest. If `contentDigest` is sent, it must match the **post-assembly** digest (`400` / `digest_mismatch` otherwise). |
| `GET` | `/v1/submissions/{submissionID}?projectID=` | dormant lookup — **`projectID` query (or `X-EditHere-Project-ID` header) required** |
| `GET` | `/v1/projects/{projectID}/submissions/{submissionID}` | dormant lookup, nested path |
| `GET` | `/v1/tasks/{remoteTaskID}` | dormant lookup |
| `POST` | `/v1/tasks/{remoteTaskID}/cancel` | dormant; not the live dump path |

Idempotent: same `projectID` + `submissionID` + recomputed `contentDigest` reuses the task. Same submission with a different digest → `409` / `error.code=conflict`. Empty or schema-invalid packages → `400`.

## Replay (gate-1 proof without the phone)

Point at an exported package directory that contains `manifest.json`, referenced `assets/`, and root `agent-prompt.txt` (plus optional `page-*.png`). Replay persists those root files into the stored package; it never invents a page-catalog-only prompt.

```bash
./edithere-host replay /path/to/exported-package --project edithere-sample
./edithere-host replay /path/to/exported-package --project edithere-sample --dry-run
./edithere-host replay /path/to/exported-package --project edithere-sample --json
./edithere-host replay /path/to/exported-package --project edithere-sample --auto-worker
```

## Status (dormant)

`status` and `describe` remain for debugging. They are not the live dump path.

```bash
./edithere-host status
./edithere-host describe --json
```

Exit codes: `0` ok, `1` fail, `2` usage, `3` not found, `4` auth, `5` conflict, `6` timeout. Non-TTY stdout uses JSON envelopes when sensible; `--json` forces the envelope.

## Tests

```bash
cd Tools/edithere-host
python3 -m unittest discover -s tests -v
```

Pitfalls: multipart parts that end in `\n` must keep that byte (do not strip payload newlines after removing the boundary CRLF). Worker start/cancel share a reentrant lifecycle lock — a non-reentrant lock deadlocks when start rechecks cancel while holding the lock.
