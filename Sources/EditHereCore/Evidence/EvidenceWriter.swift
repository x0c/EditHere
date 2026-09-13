import CryptoKit
import Foundation

public enum EditHereHashing {
    public static func sha256Hex(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(ofFileAt url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return sha256Hex(of: data)
    }

    /// Digest of package JSON plus sorted asset path/bytes — same algorithm as the outbox submitter.
    public static func contentDigest(
        for package: EditHereEvidencePackage,
        assets: [String: Data]
    ) throws -> String {
        let encoded = try EditHereJSONCoding.encoder.encode(package)
        var hasherData = encoded
        for key in assets.keys.sorted() {
            hasherData.append(Data(key.utf8))
            hasherData.append(assets[key] ?? Data())
        }
        return sha256Hex(of: hasherData)
    }

    /// Execution-destination digest: package JSON + annotated images + frozen agent-prompt.txt.
    /// Clean originals stay local for redraw and must not affect the claimed digest.
    public static func executionContentDigest(
        for package: EditHereEvidencePackage,
        assets: [String: Data]
    ) throws -> String {
        var digestAssets: [String: Data] = [:]
        for capture in package.captures {
            let path = capture.annotatedImage.relativePath
            guard let data = assets[path] else {
                throw EditHereDestinationError.incompleteAttachments
            }
            digestAssets[path] = data
        }
        if let prompt = assets["agent-prompt.txt"] {
            digestAssets["agent-prompt.txt"] = prompt
        }
        return try contentDigest(for: package, assets: digestAssets)
    }
}

public enum EditHereJSONCoding {
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Builds an on-disk evidence folder: `manifest.json`, `assets/`, numbered page composites, and `agent-prompt.txt`.
public struct EditHereEvidenceWriter: Sendable {
    public init() {}

    public func write(
        package: EditHereEvidencePackage,
        to rootURL: URL,
        assets: [String: Data]
    ) throws -> URL {
        let fm = FileManager.default
        if fm.fileExists(atPath: rootURL.path) {
            try fm.removeItem(at: rootURL)
        }
        let assetsURL = rootURL.appendingPathComponent("assets", isDirectory: true)
        try fm.createDirectory(at: assetsURL, withIntermediateDirectories: true)

        for (relativePath, data) in assets {
            let destination = rootURL.appendingPathComponent(relativePath)
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
        }

        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        let data = try EditHereJSONCoding.encoder.encode(package)
        try data.write(to: manifestURL, options: .atomic)

        // Canonical Agent packet (same style as FileDestination): page catalog + batch legend.
        let annotations = package.renumberedAnnotations()
        let used = EditHerePromptBuilder.captures(usedBy: annotations, in: package)
        var envelope: [String] = []
        for (index, capture) in used.enumerated() {
            let page = index + 1
            let fileName = "page-\(page).png"
            if let annotatedData = assets[capture.annotatedImage.relativePath] {
                try annotatedData.write(
                    to: rootURL.appendingPathComponent(fileName),
                    options: .atomic
                )
            }
            envelope.append("Page \(page): \(fileName)")
        }
        if !envelope.isEmpty {
            envelope.append("")
        }
        let prompt = (envelope + [EditHerePromptBuilder.batchPrompt(for: package)])
            .joined(separator: "\n")
        try prompt.write(
            to: rootURL.appendingPathComponent("agent-prompt.txt"),
            atomically: true,
            encoding: .utf8
        )

        return rootURL
    }

    public func loadPackage(from rootURL: URL) throws -> EditHereEvidencePackage {
        let manifestURL = rootURL.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        return try EditHereJSONCoding.decoder.decode(EditHereEvidencePackage.self, from: data)
    }
}
