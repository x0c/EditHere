import Foundation

public struct EditHereImageAsset: Codable, Hashable, Sendable {
    public var relativePath: String
    public var sha256: String
    public var byteCount: Int
    public var width: Double
    public var height: Double
    public var scale: Double

    public init(
        relativePath: String,
        sha256: String,
        byteCount: Int,
        width: Double,
        height: Double,
        scale: Double
    ) {
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.width = width
        self.height = height
        self.scale = scale
    }
}

public struct EditHereCapture: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var screenID: String
    public var sceneID: String?
    public var capturedAt: Date
    public var orientation: String
    public var originalImage: EditHereImageAsset
    public var annotatedImage: EditHereImageAsset
    public var coordinateSpace: String

    public init(
        id: UUID = UUID(),
        screenID: String,
        sceneID: String? = nil,
        capturedAt: Date = Date(),
        orientation: String,
        originalImage: EditHereImageAsset,
        annotatedImage: EditHereImageAsset,
        coordinateSpace: String = "capture-pixels-top-left"
    ) {
        self.id = id
        self.screenID = screenID
        self.sceneID = sceneID
        self.capturedAt = capturedAt
        self.orientation = orientation
        self.originalImage = originalImage
        self.annotatedImage = annotatedImage
        self.coordinateSpace = coordinateSpace
    }
}

public struct EditHereAppBinding: Codable, Hashable, Sendable {
    public var bundleIdentifier: String
    public var displayName: String
    public var marketingVersion: String
    public var buildNumber: String
    public var sourceRevision: String?

    public init(
        bundleIdentifier: String,
        displayName: String,
        marketingVersion: String,
        buildNumber: String,
        sourceRevision: String? = nil
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.marketingVersion = marketingVersion
        self.buildNumber = buildNumber
        self.sourceRevision = sourceRevision
    }

    public static func fromMainBundle(sourceRevision: String? = nil) -> EditHereAppBinding {
        let bundle = Bundle.main
        return EditHereAppBinding(
            bundleIdentifier: bundle.bundleIdentifier ?? "unknown",
            displayName: (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? "App",
            marketingVersion: (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0",
            buildNumber: (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "0",
            sourceRevision: sourceRevision
        )
    }
}

public struct EditHereEnvironment: Codable, Hashable, Sendable {
    public var screenWidth: Double
    public var screenHeight: Double
    public var screenScale: Double
    public var localeIdentifier: String
    public var preferredContentSizeCategory: String?

    public init(
        screenWidth: Double,
        screenHeight: Double,
        screenScale: Double,
        localeIdentifier: String,
        preferredContentSizeCategory: String? = nil
    ) {
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.screenScale = screenScale
        self.localeIdentifier = localeIdentifier
        self.preferredContentSizeCategory = preferredContentSizeCategory
    }
}

/// Portable evidence package. Processor-specific fields must not be required here.
public struct EditHereEvidencePackage: Codable, Hashable, Identifiable, Sendable {
    public static let currentSchemaVersion = "1.0.0"

    public var id: UUID
    public var schemaVersion: String
    public var createdAt: Date
    public var app: EditHereAppBinding
    public var environment: EditHereEnvironment
    public var overallInstruction: String
    public var captures: [EditHereCapture]
    public var annotations: [EditHereAnnotation]
    public var destinationID: String?

    public init(
        id: UUID = UUID(),
        schemaVersion: String = EditHereEvidencePackage.currentSchemaVersion,
        createdAt: Date = Date(),
        app: EditHereAppBinding,
        environment: EditHereEnvironment,
        overallInstruction: String = "",
        captures: [EditHereCapture] = [],
        annotations: [EditHereAnnotation] = [],
        destinationID: String? = nil
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.app = app
        self.environment = environment
        self.overallInstruction = overallInstruction
        self.captures = captures
        self.annotations = annotations
        self.destinationID = destinationID
    }

    public var annotationCount: Int { annotations.count }

    public func renumberedAnnotations() -> [EditHereAnnotation] {
        annotations.enumerated().map { index, item in
            var copy = item
            copy.number = index + 1
            return copy
        }
    }
}
