import Foundation
import UIKit
import EditHereCore

public struct EditHereConfiguration: @unchecked Sendable {
    public var appBinding: EditHereAppBinding
    public var environment: EditHereEnvironment
    public var destination: any EditHereDestination
    public var sourceRevision: String?
    public var screenIDProvider: @MainActor () -> String

    public init(
        destination: any EditHereDestination,
        appBinding: EditHereAppBinding? = nil,
        environment: EditHereEnvironment? = nil,
        sourceRevision: String? = nil,
        screenIDProvider: (@MainActor () -> String)? = nil
    ) {
        let binding = appBinding ?? EditHereAppBinding.fromMainBundle(sourceRevision: sourceRevision)
        self.appBinding = binding
        self.sourceRevision = sourceRevision
        self.destination = destination
        if let environment {
            self.environment = environment
        } else {
            let screen = UIScreen.main
            self.environment = EditHereEnvironment(
                screenWidth: Double(screen.bounds.width * screen.scale),
                screenHeight: Double(screen.bounds.height * screen.scale),
                screenScale: Double(screen.scale),
                localeIdentifier: Locale.current.identifier,
                preferredContentSizeCategory: UIApplication.shared.preferredContentSizeCategory.rawValue
            )
        }
        self.screenIDProvider = screenIDProvider ?? {
            "screen"
        }
    }
}
