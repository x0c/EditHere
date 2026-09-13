**Languages:** English | [简体中文](README.zh-CN.md)

# EditHere

Annotate a running iOS app on device, write what should change, and export numbered screenshots with a matching prompt for coding agents.

Install once at app entry. Tap controls while the app is running. Submit a batch when you are done. No Corral account required — local file export works out of the box.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-lightgrey.svg)](#supported-platforms)
[![Swift](https://img.shields.io/badge/Swift-6-orange.svg)](Package.swift)

<p align="center">
  <img src="docs/images/marking-mode.png" alt="EditHere marking mode with on-screen hint" width="280">
  &nbsp;
  <img src="docs/images/selection-bar.png" alt="Numbered mark on a selected control" width="280">
</p>

<p align="center"><em>Mark visible controls on a frozen page. Numbers stay aligned with your change requests.</em></p>

## Features

- **Tap to mark** — select a control’s bounds; tap again to expand to a parent
- **Batch across screens** — Close, use the app, reopen EditHere, keep collecting
- **Numbered full-page screenshots** — evidence keeps the whole visible page, not crops only
- **Agent-ready export** — annotated images, `manifest.json`, and `agent-prompt.txt`
- **Pluggable destinations** — file export by default; optional local-host dump to a named executor

## Supported platforms

| Platform | Support |
|---|---|
| iOS 17+ | Yes (Swift Package) |
| iPadOS 17+ | Yes (same package) |
| macOS / Linux / Windows | Not applicable — this is a native iOS SDK |

## Install

In Xcode: **File → Add Package Dependencies…** and add:

```text
https://github.com/x0c/EditHere
```

Link these products to your app target:

- `EditHere` — floating UI and session
- `EditHereFileDestination` — local Documents export (start here)
- `EditHereLocalHostDestination` — optional HTTP receiver for development hosts

Or in `Package.swift`:

```swift
.package(url: "https://github.com/x0c/EditHere.git", from: "0.1.0")
```

## Quick start

```swift
import EditHere
import EditHereFileDestination

#if DEBUG
let destination = try EditHereFileDestination.documentsDestination()
let configuration = EditHereConfiguration(destination: destination)
_ = try await EditHereInstaller.install(configuration: configuration)
#endif
```

SwiftUI:

```swift
ContentView()
    .installEditHere(configuration: configuration)
```

Gate with `#if DEBUG` (or an internal flag) so production App Store builds do not show the floating control unless you intentionally want that.

### First use

1. Tap **Edit**
2. Tap a control (same spot again expands to a parent)
3. Type a request or use Quick Actions, then **Done** to keep marking
4. **Close** to use the app; tap the floating button again for another screen
5. Open **Marks** → **Submit · N** to export the batch

### What you get

With `EditHereFileDestination`, Submit writes a folder under the app Documents directory, for example:

```text
EditHereExport/
  agent-prompt.txt
  manifest.json
  assets/
    page-annotated.png
```

Hand the folder (or the prompt + images) to your coding agent. Automatic code edits require a separate execution destination; the file destination only exports.

## Sample app

```bash
cd Examples/EditHereSample
xcodegen generate
open EditHereSample.xcodeproj
```

Run on a physical iPhone when one is available. See [docs/INTEGRATION_GUIDE.md](docs/INTEGRATION_GUIDE.md) for project-owned host configuration.

## Docs

- [Integration guide](docs/INTEGRATION_GUIDE.md)
- [Product rules](docs/PRODUCT_KNOWLEDGE_BASE.md)
- [Agent prompt design](docs/design/AGENT_PROMPT_CORE_DESIGN.md)
- [Architecture bounds](docs/design/ARCHITECTURE_BOUNDS.md)

## Benchmark notes

README structure borrowed from higher-attention visual-feedback tools ([Agentation](https://github.com/benjitaylor/agentation), [Sampler](https://github.com/gabrieltmitchell/sampler)): short install path, real device screenshots, explicit export inventory. EditHere does not claim web selectors, MCP auto-dispatch, or automatic source edits from the file destination.

## License

MIT
