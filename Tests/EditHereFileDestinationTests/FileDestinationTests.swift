import Foundation
import Testing
import EditHereCore
import EditHereFileDestination

struct EditHereFileDestinationTests {
    @Test func submitExportsManifestAndPrompt() async throws {
        let exportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("edithere-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: exportRoot) }

        let packageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("edithere-pkg-\(UUID().uuidString)", isDirectory: true)
        let png = Data(repeating: 1, count: 32)
        let captureID = UUID()
        let originalPath = "assets/\(captureID.uuidString)-original.png"
        let annotatedPath = "assets/\(captureID.uuidString)-annotated.png"
        let hash = EditHereHashing.sha256Hex(of: png)
        let package = EditHereEvidencePackage(
            app: EditHereAppBinding(
                bundleIdentifier: "demo.edithere",
                displayName: "Demo",
                marketingVersion: "1.0",
                buildNumber: "1"
            ),
            environment: EditHereEnvironment(
                screenWidth: 100,
                screenHeight: 200,
                screenScale: 2,
                localeIdentifier: "en_US"
            ),
            captures: [
                EditHereCapture(
                    id: captureID,
                    screenID: "home",
                    orientation: "portrait",
                    originalImage: EditHereImageAsset(
                        relativePath: originalPath,
                        sha256: hash,
                        byteCount: png.count,
                        width: 100,
                        height: 200,
                        scale: 2
                    ),
                    annotatedImage: EditHereImageAsset(
                        relativePath: annotatedPath,
                        sha256: hash,
                        byteCount: png.count,
                        width: 100,
                        height: 200,
                        scale: 2
                    )
                )
            ],
            annotations: [
                EditHereAnnotation(
                    number: 1,
                    captureID: captureID,
                    selectionKind: .bounds,
                    bounds: EditHereRect(x: 1, y: 2, width: 3, height: 4),
                    action: .changeText,
                    requestText: "Rename title",
                    confidence: .high
                )
            ]
        )
        _ = try EditHereEvidenceWriter().write(
            package: package,
            to: packageRoot,
            assets: [originalPath: png, annotatedPath: png]
        )

        let destination = EditHereFileDestination(exportRootURL: exportRoot)
        let receipt = try await destination.submit(package: package, assetRootURL: packageRoot)
        #expect(receipt.state == .submitted)

        let exported = exportRoot.appendingPathComponent(package.id.uuidString)
        #expect(FileManager.default.fileExists(atPath: exported.appendingPathComponent("manifest.json").path))
        let prompt = try String(
            contentsOf: exported.appendingPathComponent("agent-prompt.txt"),
            encoding: .utf8
        )
        #expect(prompt.contains("Rename title"))
        #expect(prompt.contains("Page 1: page-1.png"))
        #expect(!prompt.contains("Open these numbered screenshots before editing"))
        #expect(!prompt.contains("- Original:"))
        #expect(
            FileManager.default.fileExists(
                atPath: exported.appendingPathComponent("page-1.png").path
            )
        )
        #expect(
            !FileManager.default.fileExists(
                atPath: exported.appendingPathComponent(originalPath).path
            )
        )
        #expect(
            FileManager.default.fileExists(
                atPath: exported.appendingPathComponent(annotatedPath).path
            )
        )
    }
}
