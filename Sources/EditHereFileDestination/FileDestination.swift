import Foundation
import EditHereCore

/// Writes evidence packages to a local folder. Proves portability; does not execute Agent work.
public struct EditHereFileDestination: EditHereDestination, Sendable {
    public let destinationID: String
    public let displayName: String
    public let capabilities: EditHereDestinationCapabilities
    public let exportRootURL: URL

    public init(
        exportRootURL: URL,
        destinationID: String = "file-export",
        displayName: String = "File Export"
    ) {
        self.exportRootURL = exportRootURL
        self.destinationID = destinationID
        self.displayName = displayName
        self.capabilities = EditHereDestinationCapabilities(
            supportsImages: true,
            supportsProgress: false,
            supportsCancellation: false,
            supportsClarification: false,
            supportsDirectExecution: false
        )
    }

    public static func documentsDestination(
        folderName: String = "EditHereExports"
    ) throws -> EditHereFileDestination {
        let docs = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = docs.appendingPathComponent(folderName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return EditHereFileDestination(exportRootURL: root)
    }

    public func submit(
        package: EditHereEvidencePackage,
        assetRootURL: URL
    ) async throws -> EditHereSubmissionReceipt {
        try validateImageCapability()
        for capture in package.captures {
            for asset in [capture.originalImage, capture.annotatedImage] {
                let url = assetRootURL.appendingPathComponent(asset.relativePath)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw EditHereDestinationError.incompleteAttachments
                }
                let hash = try EditHereHashing.sha256Hex(ofFileAt: url)
                guard hash == asset.sha256 else {
                    throw EditHereDestinationError.incompleteAttachments
                }
            }
        }

        let destination = exportRootURL.appendingPathComponent(package.id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: assetRootURL, to: destination)
        // Agent packet is numbered screenshots only. Keep the clean capture in the
        // local package so marks can be redrawn; do not hand it to the Agent.
        for capture in package.captures {
            let originalURL = destination.appendingPathComponent(capture.originalImage.relativePath)
            try? FileManager.default.removeItem(at: originalURL)
        }

        let annotations = package.renumberedAnnotations()
        let used = EditHerePromptBuilder.captures(usedBy: annotations, in: package)
        var envelope: [String] = []
        for (index, capture) in used.enumerated() {
            let page = index + 1
            let fileName = "page-\(page).png"
                let source = destination.appendingPathComponent(capture.annotatedImage.relativePath)
                let copyURL = destination.appendingPathComponent(fileName)
                if FileManager.default.fileExists(atPath: source.path),
                   !FileManager.default.fileExists(atPath: copyURL.path)
                {
                    try? FileManager.default.copyItem(at: source, to: copyURL)
                }
            envelope.append("Page \(page): \(fileName)")
        }
        if !envelope.isEmpty {
            envelope.append("")
        }
        let prompt = (envelope + [EditHerePromptBuilder.batchPrompt(for: package)])
            .joined(separator: "\n")
        try prompt.write(
            to: destination.appendingPathComponent("agent-prompt.txt"),
            atomically: true,
            encoding: .utf8
        )

        return EditHereSubmissionReceipt(
            destinationID: destinationID,
            remoteTaskID: package.id.uuidString,
            submissionID: package.id,
            state: .submitted,
            message: "Exported to \(destination.path)"
        )
    }

    public func lookup(remoteTaskID: String) async throws -> EditHereTaskStatus {
        let destination = exportRootURL.appendingPathComponent(remoteTaskID, isDirectory: true)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw EditHereDestinationError.notFound
        }
        return EditHereTaskStatus(
            destinationID: destinationID,
            remoteTaskID: remoteTaskID,
            state: .submitted,
            summary: "Exported package is available on disk."
        )
    }
}
