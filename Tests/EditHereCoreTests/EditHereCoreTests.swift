import Foundation
import Testing
import EditHereCore

struct EditHereCoreTests {
    @Test func evidenceRoundTripPreservesAnnotations() throws {
        let package = samplePackage()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edithere-test-\(UUID().uuidString)", isDirectory: true)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let assets = [
            package.captures[0].originalImage.relativePath: png,
            package.captures[0].annotatedImage.relativePath: png
        ]
        let writer = EditHereEvidenceWriter()
        _ = try writer.write(package: package, to: root, assets: assets)
        let loaded = try writer.loadPackage(from: root)
        #expect(loaded.id == package.id)
        #expect(loaded.annotations.count == 2)
        #expect(loaded.annotations[0].effectiveRequestText.contains("Remove"))
        try? FileManager.default.removeItem(at: root)
    }

    @Test func evidenceWriterWritesCanonicalAgentPrompt() throws {
        let package = samplePackage()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edithere-prompt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])
        _ = try EditHereEvidenceWriter().write(
            package: package,
            to: root,
            assets: [
                package.captures[0].originalImage.relativePath: png,
                package.captures[0].annotatedImage.relativePath: png
            ]
        )
        let prompt = try String(
            contentsOf: root.appendingPathComponent("agent-prompt.txt"),
            encoding: .utf8
        )
        #expect(prompt.contains("Page 1: page-1.png"))
        #expect(prompt.contains("Move this title lower"))
        #expect(prompt.contains("Remove the marked element from the product."))
        #expect(!prompt.contains("Prompt template:"))
        #expect(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("page-1.png").path)
        )
    }

    @Test func executionContentDigestUsesAnnotatedImagesOnly() throws {
        let package = samplePackage()
        let annotated = Data(repeating: 9, count: 12)
        let original = Data(repeating: 3, count: 12)
        let annotatedPath = package.captures[0].annotatedImage.relativePath
        let originalPath = package.captures[0].originalImage.relativePath
        let execution = try EditHereHashing.executionContentDigest(
            for: package,
            assets: [annotatedPath: annotated, originalPath: original]
        )
        let annotatedOnly = try EditHereHashing.contentDigest(
            for: package,
            assets: [annotatedPath: annotated]
        )
        let both = try EditHereHashing.contentDigest(
            for: package,
            assets: [annotatedPath: annotated, originalPath: original]
        )
        #expect(execution == annotatedOnly)
        #expect(execution != both)
    }

    @Test func taskStatusDecodesMissingMarkOutcomesAsEmpty() throws {
        let json = """
        {
          "destinationID": "local-host",
          "remoteTaskID": "task-1",
          "state": "submitted",
          "updatedAt": "2026-09-12T00:00:00Z"
        }
        """.data(using: .utf8)!
        let status = try EditHereJSONCoding.decoder.decode(EditHereTaskStatus.self, from: json)
        #expect(status.markOutcomes.isEmpty)
        #expect(status.remoteTaskID == "task-1")
    }

    @Test func promptBuilderIncludesNumbersAndScreens() {
        let prompt = EditHerePromptBuilder.batchPrompt(for: samplePackage())
        #expect(prompt.contains("1. Page 1 · home"))
        #expect(prompt.contains("2. Page 1 · home"))
        #expect(prompt.contains("Page 1 · home — marks 1, 2"))
        #expect(prompt.contains("On screen: Save"))
        #expect(prompt.contains("Remove the marked element from the product."))
        #expect(prompt.contains("Move this title lower"))
        #expect(prompt.contains("Keep existing style."))
        #expect(prompt.contains("blue rounded outline"))
        for junk in Self.forbiddenPromptPhrases {
            #expect(!prompt.contains(junk), "Prompt must not contain “\(junk)”")
        }
    }

    @Test func promptBuilderOmitsUnusedCapturesAndFlagsIncompleteAppearance() {
        var package = samplePackage()
        let unusedID = UUID()
        package.captures.append(
            EditHereCapture(
                id: unusedID,
                screenID: "ghost",
                orientation: "portrait",
                originalImage: package.captures[0].originalImage,
                annotatedImage: package.captures[0].annotatedImage
            )
        )
        package.annotations.append(
            EditHereAnnotation(
                number: 3,
                captureID: package.captures[0].id,
                selectionKind: .bounds,
                bounds: EditHereRect(x: 1, y: 2, width: 3, height: 4),
                action: .adjustAppearance,
                requestText: "",
                confidence: .medium
            )
        )
        let prompt = EditHerePromptBuilder.batchPrompt(for: package)
        #expect(!prompt.contains("ghost"))
        #expect(prompt.contains("The change is not specific. Do not guess."))
        #expect(prompt.contains("3. Page 1 · home"))
        #expect(!prompt.contains("Completeness:"))
    }

    @Test func promptBuilderOmitsPrivateClassNamesAndAssetPaths() {
        var package = samplePackage()
        package.annotations[0].targetHint.className = "_UICollectionViewListCellContentView"
        package.annotations[0].normalizedBounds = EditHereNormalizedRect(
            x: 0.041, y: 0.313, width: 0.918, height: 0.109
        )
        let prompt = EditHerePromptBuilder.batchPrompt(for: package)
        #expect(!prompt.contains("_UI"))
        #expect(!prompt.contains("0.041"))
        #expect(prompt.contains("On screen: Save"))
        #expect(!prompt.contains("Control:"))
    }

    @Test func renumberKeepsOrder() {
        var package = samplePackage()
        package.annotations[0].number = 9
        package.annotations[1].number = 3
        let renumbered = package.renumberedAnnotations()
        #expect(renumbered.map(\.number) == [1, 2])
    }

    @Test func semanticHeuristicPrefersButtons() {
        let button = EditHereSemanticParentHeuristic.score(
            className: "UIButton",
            hasText: true,
            isControlLike: true
        )
        let label = EditHereSemanticParentHeuristic.score(
            className: "UILabel",
            hasText: true,
            isControlLike: false
        )
        #expect(button > label)
    }

    private static let forbiddenPromptPhrases = [
        "Prompt template:",
        "EditHere change request",
        "plan approval",
        "single session",
        "new session",
        "authorized batch",
        "Completeness:",
        "## Task",
        "## Rules",
        "## Output",
        "## Requests",
        "## Screenshots",
        "Bundle:",
        "source identity",
        "runtime observations",
        "There is no second clean copy",
        "per-mark crops",
        "Request:",
        "changed, not changed, unresolved",
        "needs information",
        "Normalized bounds",
        "Visible text (hint)",
        "Control type (hint)",
        "assets/",
        "- Original:",
        "Use the original image"
    ]

    private func samplePackage() -> EditHereEvidencePackage {
        let captureID = UUID()
        let asset = EditHereImageAsset(
            relativePath: "assets/\(captureID.uuidString)-original.png",
            sha256: EditHereHashing.sha256Hex(of: Data([0x89, 0x50, 0x4E, 0x47])),
            byteCount: 4,
            width: 100,
            height: 200,
            scale: 2
        )
        let annotated = EditHereImageAsset(
            relativePath: "assets/\(captureID.uuidString)-annotated.png",
            sha256: asset.sha256,
            byteCount: 4,
            width: 100,
            height: 200,
            scale: 2
        )
        let capture = EditHereCapture(
            id: captureID,
            screenID: "home",
            orientation: "portrait",
            originalImage: asset,
            annotatedImage: annotated
        )
        let annotations = [
            EditHereAnnotation(
                number: 1,
                captureID: captureID,
                selectionKind: .bounds,
                bounds: EditHereRect(x: 10, y: 20, width: 30, height: 40),
                normalizedBounds: EditHereNormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2),
                action: .removeElement,
                requestText: "",
                targetHint: EditHereTargetHint(
                    accessibilityLabel: "Save",
                    className: "UIButton",
                    visibleText: "Save"
                ),
                confidence: .high
            ),
            EditHereAnnotation(
                number: 2,
                captureID: captureID,
                selectionKind: .point,
                point: EditHerePoint(x: 50, y: 60),
                action: .customRequest,
                requestText: "Move this title lower",
                confidence: .pointFallback
            )
        ]
        return EditHereEvidencePackage(
            app: EditHereAppBinding(
                bundleIdentifier: "demo.edithere",
                displayName: "EditHere Demo",
                marketingVersion: "0.1.0",
                buildNumber: "1"
            ),
            environment: EditHereEnvironment(
                screenWidth: 1170,
                screenHeight: 2532,
                screenScale: 3,
                localeIdentifier: "en_US"
            ),
            overallInstruction: "Keep existing style.",
            captures: [capture],
            annotations: annotations
        )
    }
}
