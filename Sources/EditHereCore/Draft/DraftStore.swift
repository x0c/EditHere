import Foundation

/// Local draft batch while the developer is still marking screens.
public struct EditHereDraftBatch: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var overallInstruction: String
    public var package: EditHereEvidencePackage
    /// Relative asset path -> PNG bytes stored alongside the draft.
    public var assets: [String: Data]

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        overallInstruction: String = "",
        package: EditHereEvidencePackage,
        assets: [String: Data] = [:]
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.overallInstruction = overallInstruction
        self.package = package
        self.assets = assets
    }
}

public protocol EditHereDraftStore: Sendable {
    func load() async throws -> EditHereDraftBatch?
    func save(_ draft: EditHereDraftBatch) async throws
    func clear() async throws
}

public actor EditHereFileDraftStore: EditHereDraftStore {
    private let directoryURL: URL
    private let draftURL: URL
    private let assetsDirectoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
        self.draftURL = directoryURL.appendingPathComponent("draft.json")
        self.assetsDirectoryURL = directoryURL.appendingPathComponent("assets", isDirectory: true)
    }

    public static func applicationSupportStore(
        subdirectory: String = "EditHere/Drafts"
    ) throws -> EditHereFileDraftStore {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent(subdirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return EditHereFileDraftStore(directoryURL: directory)
    }

    public func load() async throws -> EditHereDraftBatch? {
        guard FileManager.default.fileExists(atPath: draftURL.path) else { return nil }
        let data = try Data(contentsOf: draftURL)
        var draft = try EditHereJSONCoding.decoder.decode(EditHereDraftBatch.self, from: data)
        var assets: [String: Data] = [:]
        for capture in draft.package.captures {
            for path in [capture.originalImage.relativePath, capture.annotatedImage.relativePath] {
                let url = directoryURL.appendingPathComponent(path)
                if let bytes = try? Data(contentsOf: url) {
                    assets[path] = bytes
                }
            }
        }
        draft.assets = assets
        return draft
    }

    public func save(_ draft: EditHereDraftBatch) async throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assetsDirectoryURL, withIntermediateDirectories: true)
        for (path, data) in draft.assets {
            let url = directoryURL.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
        }
        var persisted = draft
        persisted.assets = [:]
        persisted.updatedAt = Date()
        let data = try EditHereJSONCoding.encoder.encode(persisted)
        try data.write(to: draftURL, options: .atomic)
    }

    public func clear() async throws {
        if FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.removeItem(at: directoryURL)
        }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }
}
