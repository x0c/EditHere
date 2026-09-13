# EditHere integration guide

## Add the package

Public package URL:

```text
https://github.com/x0c/EditHere
```

Add the Swift package (Xcode **File → Add Package Dependencies…**, or a local checkout) and link:

- `EditHere` (UI + session)
- A destination product such as `EditHereFileDestination` or `EditHereLocalHostDestination`

Do not link a Corral adapter unless you intentionally want that destination.

## Install at app entry

Call once after the root scene is active:

```swift
let destination = try EditHereFileDestination.documentsDestination()
let configuration = EditHereConfiguration(
    destination: destination,
    sourceRevision: /* optional git SHA */,
    screenIDProvider: { /* optional stable screen id */ "home" }
)
_ = try await EditHereInstaller.install(configuration: configuration)
```

SwiftUI helper:

```swift
ContentView()
    .installEditHere(configuration: configuration)
```

## Destination setup

Configure the destination and project binding in the host app development project, following [Project-owned execution configuration](PRODUCT_KNOWLEDGE_BASE.md#project-owned-execution-configuration). The phone does not provide connection settings, pairing, project selection, reconnect or unbind controls.

Shareable project binding lives in `edithere.project.json` (bundled into the app for Debug). Machine-specific host registration uses a host config such as `edithere.host.example.json`. Sample files:

- `Examples/EditHereSample/edithere.project.json` — `projectID`, receiver `baseURL` / `submitPath` / token header hint, build scheme, delivery method, acceptance screens. When the Mac LAN IP changes, edit this project file (not the phone).
- `Examples/EditHereSample/edithere.host.example.json` — git-friendly host template (`listen`, `dataDir`, `tokenEnv`, per-project checkout). Copy and fill absolute paths locally; do not commit secrets.

Credentials: set `EDITHHERE_HOST_TOKEN` (or the name in `tokenEnvHint` / `tokenEnv`), and/or keep a gitignored `Examples/EditHereSample/edithere.credentials.json` (copy from `edithere.credentials.example.json`). The sample `preBuildScripts` phase embeds that file into the app bundle when present, or writes one from `EDITHHERE_HOST_TOKEN` in the build environment so Archive / ios-deliver cold launches still authenticate. Link `EditHereLocalHostDestination` for the HTTP receiver, or `EditHereFileDestination` for Documents export (portability proof). When bundled `edithere.project.json` is present, a missing token is a hard error — never silent File Export. File Export only when project JSON is absent. Execution destinations must declare image support; EditHere refuses to submit when images are unsupported.

## Development-only recommendation

Gate installation with `#if DEBUG` or an internal build flag so production customers do not see the floating control unless product explicitly wants that.
