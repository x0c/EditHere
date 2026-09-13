import SwiftUI
import EditHere
import EditHereCore
import EditHereFileDestination
import EditHereLocalHostDestination

@main
struct EditHereSampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    await installEditHereIfNeeded()
                }
        }
    }

    @MainActor
    private func installEditHereIfNeeded() async {
        do {
            let destination = try makeDestination()
            let configuration = EditHereConfiguration(
                destination: destination,
                screenIDProvider: { "sample-home" }
            )
            let session = try await EditHereInstaller.install(configuration: configuration)
            #if DEBUG
            // Real-device probes without a UI-test runner:
            // `devicectl device process launch --console ... -- -EditHereGeometryProbe`
            // or `-EditHereCanvasLockProbe` / `-EditHerePromptPreviewProbe` /
            // `-EditHereSelectionBarProbe`.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-EditHereGeometryProbe")
                || arguments.contains("-EditHereCanvasLockProbe")
                || arguments.contains("-EditHerePromptPreviewProbe")
                || arguments.contains("-EditHereSelectionBarProbe") {
                try await Task.sleep(for: .seconds(1.5))
                session.enterAnnotationMode()
                try await Task.sleep(for: .seconds(0.8))
                session.handleTap(at: CGPoint(x: 195, y: 270))
            }
            #endif
        } catch {
            print("EditHere install failed: \(error)")
        }
    }

    /// Prefer Local Host when bundled project config is present and a token is available.
    /// Token resolution: `EDITHHERE_HOST_TOKEN` env, else bundled `edithere.credentials.json`.
    /// File Export only when project JSON is absent (portability demo). Never silent-fallback when
    /// project config exists but the token is missing.
    private func makeDestination() throws -> any EditHereDestination {
        guard let configURL = Bundle.main.url(forResource: "edithere.project", withExtension: "json") else {
            let destination = try EditHereFileDestination.documentsDestination()
            print(
                "EditHere destination: File Export (bundled edithere.project.json missing — portability demo)"
            )
            return destination
        }

        let projectConfig = try EditHereProjectConfiguration.load(from: configURL)
        guard let token = resolveHostToken(expectedProjectID: projectConfig.projectID) else {
            let message = """
            EditHere Local Host requires a project-scoped receiver token because edithere.project.json is bundled. \
            Set EDITHHERE_TOKEN_EDITHHERE_SAMPLE (or EDITHHERE_HOST_TOKEN), or add \
            Examples/EditHereSample/edithere.credentials.json with matching projectID \
            (see edithere.credentials.example.json). File Export is not used when project config is present.
            """
            print(message)
            throw EditHereDestinationError.underlying(message)
        }

        let destination = try EditHereLocalHostDestination(
            projectConfigURL: configURL,
            token: token
        )
        print(
            "EditHere destination: Local Host (\(destination.projectID) → discovery _edithere._tcp, fallback \(destination.baseURL.absoluteString))"
        )
        return destination
    }

    private func resolveHostToken(expectedProjectID: String) -> String? {
        for key in ["EDITHHERE_TOKEN_EDITHHERE_SAMPLE", "EDITHHERE_HOST_TOKEN"] {
            let env = ProcessInfo.processInfo.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let env, !env.isEmpty {
                return env
            }
        }
        guard let url = Bundle.main.url(forResource: "edithere.credentials", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = object["token"] as? String
        else {
            return nil
        }
        if let credentialProject = object["projectID"] as? String,
           !credentialProject.isEmpty,
           credentialProject != expectedProjectID {
            print(
                "EditHere credentials projectID \(credentialProject) does not match \(expectedProjectID)."
            )
            return nil
        }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, token != "replace-me" else {
            return nil
        }
        return token
    }
}

struct ContentView: View {
    /// Gate-1 fixture applied: promo removed; title renamed; only list row 3 relabeled.
    @State private var showPromo = false
    @State private var title = "Recently used"
    @State private var notificationsEnabled = true

    var body: some View {
        NavigationStack {
            List {
                Section("Home") {
                    Text(title)
                        .font(.largeTitle.bold())
                    if showPromo {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Promo card")
                                .font(.headline)
                            Text("Tap Edit, select this card, then choose Remove.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    Toggle("Notifications", isOn: $notificationsEnabled)
                    Button("Open settings style page") {}
                }
                Section("List") {
                    ForEach(1...6, id: \.self) { index in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(index == 3 ? "Pinned item" : "Item \(index)")
                                Text("Secondary line")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .navigationTitle("EditHere Sample")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Rename") {
                        title = title == "Recently used" ? "Recent items" : "Recently used"
                    }
                }
            }
        }
    }
}
