# Gate 1 fixture — image-to-source proof

Synthetic EditHere evidence package for the first execution acceptance gate.

## Package

`package/` contains `manifest.json`, numbered `page-1.png`, `agent-prompt.txt`, and `assets/` (annotated + original). Worker packets must use **only** the numbered composite (`page-1.png` / annotated), not a second clean original.

## Covered cases

1. Change title text (clear target + wording)
2. Remove promo card
3. Same-looking list rows — only mark **3** / Item 3
4. Point mark with underspecified appearance request — must stay unresolved
5. Underspecified “Improve it” — must stay unresolved (do not guess)

## Replay

Once `edithere-host` is available (sibling `host/` repo checkout):

```bash
export EDITHHERE_HOST_TOKEN=dev-token
cd ../../../host && python3 -m edithere_host replay ../sdk-swift/Fixtures/gate1/package --project edithere-sample --json
```

Then run the execution worker against the stored task (or open `page-1.png` + `agent-prompt.txt` in an authorized checkout of the sample app) and verify: marks 1–3 change the intended sample UI source; marks 4–5 remain unresolved without speculative edits.
