import UIKit
import EditHereCore

/// One-time install of the floating EditHere chrome into the active window scene.
@MainActor
public enum EditHereInstaller {
    private static var hostWindow: EditHereHostWindow?
    private static var session: EditHereSession?

    @discardableResult
    public static func install(
        configuration: EditHereConfiguration,
        draftStore: (any EditHereDraftStore)? = nil,
        outbox: EditHereOutbox? = nil
    ) async throws -> EditHereSession {
        if let session {
            return session
        }

        let store = try draftStore ?? EditHereFileDraftStore.applicationSupportStore()
        let box = try outbox ?? EditHereOutbox.applicationSupportOutbox()
        let submitter = EditHereSubmitter(outbox: box)
        let existing = try await store.load()
        let session = EditHereSession(
            configuration: configuration,
            draftStore: store,
            submitter: submitter,
            existingDraft: existing
        )

        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
            ?? UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first
        else {
            throw EditHereInstallError.noWindowScene
        }

        let window = EditHereHostWindow(windowScene: scene)
        let root = EditHereRootViewController(session: session) {
            scene.windows.filter { !($0 is EditHereHostWindow) }
        }
        window.rootViewController = root
        window.isHidden = false
        session.setExcludedWindows([window])
        session.setPreferredScene(scene)

        self.hostWindow = window
        self.session = session
        return session
    }

    public static func sharedSession() -> EditHereSession? {
        session
    }

    public static func uninstall() {
        hostWindow?.isHidden = true
        hostWindow = nil
        session = nil
    }
}

public enum EditHereInstallError: Error, LocalizedError, Sendable {
    case noWindowScene

    public var errorDescription: String? {
        "EditHere could not find an active window scene to attach the floating control."
    }
}

#if canImport(SwiftUI)
import SwiftUI

public struct EditHereInstallModifier: ViewModifier {
    let configuration: EditHereConfiguration

    public func body(content: Content) -> some View {
        content.task {
            _ = try? await EditHereInstaller.install(configuration: configuration)
        }
    }
}

public extension View {
    /// Installs EditHere once the view appears. Intended for development builds.
    func installEditHere(configuration: EditHereConfiguration) -> some View {
        modifier(EditHereInstallModifier(configuration: configuration))
    }
}
#endif
