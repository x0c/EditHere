import Combine
import Foundation
import UIKit
import EditHereCore

@MainActor
public final class EditHereSession: ObservableObject {
    public enum Mode: Equatable {
        case idle
        case annotating
        case browsing
    }

    @Published public private(set) var mode: Mode = .idle
    @Published public private(set) var draft: EditHereDraftBatch
    @Published public private(set) var activeCaptureID: UUID?
    @Published public private(set) var frozenImage: UIImage?
    @Published public private(set) var frozenCandidates: [EditHereViewCandidate] = []
    @Published public private(set) var selectedCandidate: EditHereViewCandidate?
    @Published public private(set) var selectionKind: EditHereSelectionKind = .bounds
    @Published public private(set) var lastReceipt: EditHereSubmissionReceipt?
    @Published public private(set) var statusMessage: String?
    @Published public private(set) var isSubmitting = false
    @Published public private(set) var undoMessage: String?
    @Published public var composerText: String = ""
    @Published public var overallInstruction: String = ""

    public let configuration: EditHereConfiguration
    private let selector = EditHereViewSelector()
    private let draftStore: any EditHereDraftStore
    private let submitter: EditHereSubmitter
    private var lastTapPoint: CGPoint?
    private var frozenPixelSize: CGSize = .zero
    private var frozenScale: CGFloat = 1
    private var excludedWindowIDs: Set<ObjectIdentifier> = []
    private var preferredScene: UIWindowScene?
    /// Package IDs already handed to the submitter; completion must not wipe a newer draft.
    private var submittedPackageIDs: Set<UUID> = []
    private var lastRemovedAnnotation: EditHereAnnotation?
    private static let pointFallbackToken = NSObject()
    /// In-memory originals for live preview and background export. Never assign decoded PNG here.
    private var originalImages: [UUID: UIImage] = [:]
    private var originalEncodeTasks: [UUID: Task<Void, Never>] = [:]
    private var dirtyCaptureIDs: Set<UUID> = []
    private var idleEvidenceTask: Task<Void, Never>?
    /// Test hook: increments only when an annotated PNG is actually encoded.
    private(set) var annotatedExportCount = 0
    private(set) var originalEncodeCount = 0

    public init(
        configuration: EditHereConfiguration,
        draftStore: any EditHereDraftStore,
        submitter: EditHereSubmitter,
        existingDraft: EditHereDraftBatch? = nil
    ) {
        self.configuration = configuration
        self.draftStore = draftStore
        self.submitter = submitter
        if let existingDraft {
            self.draft = existingDraft
            self.overallInstruction = existingDraft.overallInstruction
        } else {
            self.draft = EditHereDraftBatch(
                package: EditHereEvidencePackage(
                    app: configuration.appBinding,
                    environment: configuration.environment
                )
            )
        }
    }

    public var annotationCount: Int { draft.package.annotations.count }

    /// Includes the active typed draft when it is a nonempty request.
    public var submitReadyCount: Int {
        annotationCount + (hasActiveTypedRequest ? 1 : 0)
    }

    public var hasActiveTypedRequest: Bool {
        !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedCandidate != nil
            && mode == .annotating
    }

    public func setExcludedWindows(_ windows: [UIWindow]) {
        excludedWindowIDs = Set(windows.map { ObjectIdentifier($0) })
    }

    public func setPreferredScene(_ scene: UIWindowScene?) {
        preferredScene = scene
    }

    public func enterAnnotationMode() {
        flushActiveDraftIfNeeded()
        do {
            let hostWindows = EditHereScreenCapture.hostWindows(
                excluding: excludedWindowIDs,
                preferring: preferredScene
            )
            let frame = try EditHereScreenCapture.capture(windows: hostWindows)
            let candidates = selector.snapshotCandidates(
                in: hostWindows,
                excluding: excludedWindowIDs
            )

            frozenImage = frame.image
            frozenCandidates = candidates
            frozenPixelSize = CGSize(width: frame.width, height: frame.height)
            frozenScale = CGFloat(frame.scale)

            let captureID = UUID()
            activeCaptureID = captureID
            originalImages[captureID] = frame.image
            let originalPath = "assets/\(captureID.uuidString)-original.png"
            let annotatedPath = "assets/\(captureID.uuidString)-annotated.png"
            let placeholder = EditHereImageAsset(
                relativePath: originalPath,
                sha256: "",
                byteCount: 0,
                width: frame.width,
                height: frame.height,
                scale: frame.scale
            )
            let capture = EditHereCapture(
                id: captureID,
                screenID: configuration.screenIDProvider(),
                orientation: currentOrientationName(),
                originalImage: placeholder,
                annotatedImage: EditHereImageAsset(
                    relativePath: annotatedPath,
                    sha256: "",
                    byteCount: 0,
                    width: frame.width,
                    height: frame.height,
                    scale: frame.scale
                )
            )
            draft.package.captures.append(capture)
            mode = .annotating
            selectedCandidate = nil
            composerText = ""
            statusMessage = nil
            encodeOriginalOffMain(captureID: captureID, image: frame.image)
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    public func resumeBrowsing() {
        flushActiveDraftIfNeeded()
        mode = .browsing
        clearFrozenFrame(keepingBatch: true)
    }

    public func minimize() {
        flushActiveDraftIfNeeded()
        mode = .idle
        clearFrozenFrame(keepingBatch: true)
    }

    public func handleTap(at windowPoint: CGPoint, windows _: [UIWindow] = []) {
        guard mode == .annotating, activeCaptureID != nil else { return }
        flushActiveDraftIfNeeded()

        let samePoint: Bool = {
            guard let last = lastTapPoint else { return false }
            let dx = last.x - windowPoint.x
            let dy = last.y - windowPoint.y
            return (dx * dx + dy * dy) <= 100
        }()
        lastTapPoint = windowPoint

        let candidates = selector.candidates(at: windowPoint, from: frozenCandidates)
        if let preferred = selector.preferredCandidate(
            from: candidates,
            previous: selectedCandidate,
            samePointRetap: samePoint
        ) {
            selectedCandidate = preferred
            selectionKind = .bounds
        } else {
            selectionKind = .point
            selectedCandidate = EditHereViewCandidate(
                viewObjectIdentifier: ObjectIdentifier(EditHereSession.pointFallbackToken),
                parentObjectIdentifier: nil,
                boundsInWindow: CGRect(x: windowPoint.x - 1, y: windowPoint.y - 1, width: 2, height: 2),
                className: "PointFallback",
                accessibilityLabel: nil,
                accessibilityIdentifier: nil,
                visibleText: nil,
                isControlLike: false,
                depth: 0,
                paintOrder: Int.max,
                isOpaque: false
            )
        }
        composerText = ""
    }

    /// Collapse the write surface without discarding the batch. Clears the provisional selection.
    public func dismissActiveSelection() {
        selectedCandidate = nil
        selectionKind = .bounds
        lastTapPoint = nil
    }

    /// Flush typed text into a committed annotation for the current selection.
    @discardableResult
    public func flushActiveDraftIfNeeded() -> Bool {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, selectedCandidate != nil, mode == .annotating else { return false }
        return commitAnnotation(action: .customRequest, requestOverride: text, clearSelection: true)
    }

    @discardableResult
    public func applyRemoveElement() -> Bool {
        guard selectedCandidate != nil else { return false }
        let ok = commitAnnotation(
            action: .removeElement,
            requestOverride: EditHereAnnotationAction.removeElement.defaultPrompt,
            clearSelection: true
        )
        if ok {
            undoMessage = "Marked for removal"
        }
        return ok
    }

    /// Change-text shortcut: seeds the editor; does not commit until the user types a replacement.
    public func beginChangeText() {
        guard selectedCandidate != nil else { return }
        if composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            composerText = "Change the text to: "
        }
    }

    @discardableResult
    public func commitAnnotation(
        action: EditHereAnnotationAction,
        requestOverride: String? = nil,
        clearSelection: Bool = true
    ) -> Bool {
        guard let captureID = activeCaptureID else { return false }
        guard let selected = selectedCandidate else { return false }
        guard frozenImage != nil else { return false }

        let text = (requestOverride ?? composerText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if action == .customRequest, text.isEmpty { return false }
        if action == .changeText, text.isEmpty || text == "Change the text to:" { return false }
        let resolvedText: String
        if text.isEmpty {
            resolvedText = action.defaultPrompt
        } else {
            resolvedText = text
        }
        guard !resolvedText.isEmpty else { return false }

        let number = draft.package.annotations.count + 1
        let pixelBounds = EditHereGeometryTransform.pixelRect(
            fromWindowRect: selected.boundsInWindow,
            imageScale: frozenScale
        )
        let kind: EditHereSelectionKind
        let confidence: EditHereSelectionConfidence
        var bounds: EditHereRect?
        var point: EditHerePoint?
        var normalized: EditHereNormalizedRect?

        if selectionKind == .point || selected.className == "PointFallback" {
            kind = .point
            confidence = .pointFallback
            let center = CGPoint(x: selected.boundsInWindow.midX, y: selected.boundsInWindow.midY)
            point = EditHereGeometryTransform.pixelPoint(fromWindowPoint: center, imageScale: frozenScale)
        } else {
            kind = .bounds
            confidence = selected.isControlLike ? .high : .medium
            bounds = pixelBounds
            normalized = pixelBounds.normalized(
                againstImageWidth: frozenPixelSize.width,
                height: frozenPixelSize.height
            )
        }

        let annotation = EditHereAnnotation(
            number: number,
            captureID: captureID,
            selectionKind: kind,
            bounds: bounds,
            normalizedBounds: normalized,
            point: point,
            action: action,
            requestText: resolvedText,
            targetHint: EditHereTargetHint(
                accessibilityLabel: selected.accessibilityLabel,
                accessibilityIdentifier: selected.accessibilityIdentifier,
                className: selected.className == "PointFallback" ? nil : selected.className,
                visibleText: selected.visibleText
            ),
            confidence: confidence
        )
        draft.package.annotations.append(annotation)
        composerText = ""
        if clearSelection {
            selectedCandidate = nil
        }
        markCaptureDirty(captureID)
        return true
    }

    public func updateAnnotationRequest(id: UUID, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = draft.package.annotations.firstIndex(where: { $0.id == id })
        else { return }
        draft.package.annotations[index].requestText = trimmed
        markCaptureDirty(draft.package.annotations[index].captureID)
    }

    public func removeAnnotation(id: UUID) {
        guard let removed = draft.package.annotations.first(where: { $0.id == id }) else { return }
        lastRemovedAnnotation = removed
        undoMessage = "Mark deleted"
        draft.package.annotations.removeAll { $0.id == id }
        draft.package.annotations = draft.package.renumberedAnnotations()
        var dirty: Set<UUID> = [removed.captureID]
        for annotation in draft.package.annotations {
            dirty.insert(annotation.captureID)
        }
        for captureID in dirty {
            markCaptureDirty(captureID)
        }
    }

    public func undoLastRemoval() {
        guard let annotation = lastRemovedAnnotation else { return }
        draft.package.annotations.append(annotation)
        draft.package.annotations = draft.package.renumberedAnnotations()
        lastRemovedAnnotation = nil
        undoMessage = nil
        var dirty: Set<UUID> = [annotation.captureID]
        for item in draft.package.annotations {
            dirty.insert(item.captureID)
        }
        for captureID in dirty {
            markCaptureDirty(captureID)
        }
    }

    public func submit() async {
        flushActiveDraftIfNeeded()
        guard annotationCount > 0 else {
            statusMessage = "Add at least one request before submitting."
            return
        }
        guard !isSubmitting else { return }

        idleEvidenceTask?.cancel()
        idleEvidenceTask = nil
        await prepareEvidenceForSubmit()

        isSubmitting = true
        defer { isSubmitting = false }

        draft.overallInstruction = overallInstruction
        draft.package.overallInstruction = overallInstruction

        // Immutable snapshot for this submission; open a fresh editable batch immediately.
        let snapshot = draft
        let submittedID = snapshot.package.id
        submittedPackageIDs.insert(submittedID)

        draft = EditHereDraftBatch(
            package: EditHereEvidencePackage(
                app: configuration.appBinding,
                environment: configuration.environment
            )
        )
        overallInstruction = ""
        composerText = ""
        selectedCandidate = nil
        originalImages.removeAll()
        originalEncodeTasks.removeAll()
        dirtyCaptureIDs.removeAll()
        try? await draftStore.clear()

        do {
            let receipt = try await submitter.submit(
                draft: snapshot,
                destination: configuration.destination
            )
            lastReceipt = receipt
            statusMessage = receipt.message ?? "Sent"
            // Only minimize if the user has not already started a new batch.
            if draft.package.annotations.isEmpty && !hasActiveTypedRequest {
                minimize()
            }
        } catch {
            // Restore the snapshot only if the live draft is still empty (no newer work).
            if draft.package.annotations.isEmpty,
               draft.assets.isEmpty,
               !hasActiveTypedRequest {
                draft = snapshot
                overallInstruction = snapshot.overallInstruction
                statusMessage = error.localizedDescription
                try? await draftStore.save(draft)
            } else {
                statusMessage = "Previous submission failed: \(error.localizedDescription). Current marks kept."
            }
        }
    }

    /// Rebuild export screenshots after idle so tap/Done/swipe stay fluid.
    private func markCaptureDirty(_ captureID: UUID) {
        dirtyCaptureIDs.insert(captureID)
        idleEvidenceTask?.cancel()
        idleEvidenceTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.exportDirtyCapturesAndPersist()
        }
    }

    /// Canonical prompt plus the page images an Agent would receive. Flushes the
    /// typed draft and numbered composites first. Preview-only decoding must not
    /// be assigned onto the frozen canvas.
    func promptPreviewContent() async -> EditHerePromptPreviewContent {
        _ = flushActiveDraftIfNeeded()
        draft.package.overallInstruction = overallInstruction
        await prepareEvidenceForSubmit()
        var package = draft.package
        package.annotations = package.renumberedAnnotations()
        let prompt = EditHerePromptBuilder.batchPrompt(for: package)
        let captures = EditHerePromptBuilder.captures(usedBy: package.annotations, in: package)
        let pages = captures.enumerated().map { index, capture in
            let source = originalImages[capture.id] ?? image(from: capture.originalImage)
            let annotated = image(from: capture.annotatedImage)
                ?? annotatedPreview(from: source, captureID: capture.id)
            return EditHerePromptPreviewPage(
                pageIndex: index + 1,
                screenID: capture.screenID,
                annotated: annotated
            )
        }
        return EditHerePromptPreviewContent(prompt: prompt, pages: pages)
    }

    private func image(from asset: EditHereImageAsset) -> UIImage? {
        guard let data = draft.assets[asset.relativePath] else { return nil }
        return UIImage(data: data, scale: CGFloat(max(asset.scale, 1)))
    }

    private func annotatedPreview(from original: UIImage?, captureID: UUID) -> UIImage? {
        guard let original else { return nil }
        let marks = draft.package.annotations.filter { $0.captureID == captureID }
        return EditHereAnnotatedImageRenderer.render(original: original, annotations: marks)
    }

    func prepareEvidenceForSubmit() async {
        idleEvidenceTask?.cancel()
        idleEvidenceTask = nil
        for task in originalEncodeTasks.values {
            await task.value
        }
        await exportDirtyCapturesAndPersist()
    }

    private func encodeOriginalOffMain(captureID: UUID, image: UIImage) {
        guard let cgImage = image.cgImage else {
            statusMessage = "Failed to encode the captured screenshot."
            return
        }
        let scale = image.scale
        let size = image.size
        originalEncodeTasks[captureID] = Task.detached(priority: .userInitiated) {
            let png = EditHereImageEncoding.pngData(from: cgImage)
            let hash = png.map(EditHereHashing.sha256Hex(of:))
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.originalEncodeCount += 1
                self.originalEncodeTasks[captureID] = nil
                guard let png, let hash else {
                    self.statusMessage = "Failed to encode the captured screenshot."
                    return
                }
                guard let index = self.draft.package.captures.firstIndex(where: { $0.id == captureID }) else { return }
                let originalPath = self.draft.package.captures[index].originalImage.relativePath
                let annotatedPath = self.draft.package.captures[index].annotatedImage.relativePath
                let asset = EditHereImageAsset(
                    relativePath: originalPath,
                    sha256: hash,
                    byteCount: png.count,
                    width: Double(size.width * scale),
                    height: Double(size.height * scale),
                    scale: Double(scale)
                )
                self.draft.assets[originalPath] = png
                if self.draft.assets[annotatedPath] == nil {
                    self.draft.assets[annotatedPath] = png
                    self.draft.package.captures[index].annotatedImage = EditHereImageAsset(
                        relativePath: annotatedPath,
                        sha256: hash,
                        byteCount: png.count,
                        width: asset.width,
                        height: asset.height,
                        scale: asset.scale
                    )
                }
                self.draft.package.captures[index].originalImage = asset
                Task { await self.persistDraft() }
            }
        }
    }

    private func exportDirtyCapturesAndPersist() async {
        let ids = dirtyCaptureIDs
        dirtyCaptureIDs.removeAll()
        for id in ids {
            await exportAnnotatedPNG(for: id)
        }
        await persistDraft()
    }

    private func exportAnnotatedPNG(for captureID: UUID) async {
        guard let index = draft.package.captures.firstIndex(where: { $0.id == captureID }) else { return }
        let capture = draft.package.captures[index]
        let sourceImage = originalImages[captureID]
        let cgImage: CGImage?
        let scale: CGFloat
        let size: CGSize
        if let sourceImage, let existing = sourceImage.cgImage {
            cgImage = existing
            scale = sourceImage.scale
            size = sourceImage.size
        } else if let data = draft.assets[capture.originalImage.relativePath],
                  let decoded = UIImage(data: data, scale: CGFloat(max(capture.originalImage.scale, 1))),
                  let existing = decoded.cgImage {
            // Export-only decode. Never assign onto frozenImage / the live canvas.
            cgImage = existing
            scale = decoded.scale
            size = decoded.size
        } else {
            return
        }
        guard let cgImage else { return }
        let annotations = draft.package.annotations.filter { $0.captureID == captureID }
        let exported = await Task.detached(priority: .utility) {
            guard let png = EditHereAnnotatedImageRenderer.exportPNGData(
                original: cgImage,
                scale: scale,
                size: size,
                annotations: annotations
            ) else { return nil as (Data, String)? }
            return (png, EditHereHashing.sha256Hex(of: png))
        }.value
        guard let (png, hash) = exported else { return }
        annotatedExportCount += 1
        let path = capture.annotatedImage.relativePath
        draft.assets[path] = png
        draft.package.captures[index].annotatedImage = EditHereImageAsset(
            relativePath: path,
            sha256: hash,
            byteCount: png.count,
            width: capture.originalImage.width,
            height: capture.originalImage.height,
            scale: capture.originalImage.scale
        )
    }

    func testing_prepareFrozenCapture(image: UIImage, candidates: [EditHereViewCandidate]) {
        let captureID = UUID()
        activeCaptureID = captureID
        frozenImage = image
        frozenCandidates = candidates
        frozenScale = image.scale
        frozenPixelSize = CGSize(
            width: image.size.width * image.scale,
            height: image.size.height * image.scale
        )
        originalImages[captureID] = image
        mode = .annotating
        let originalPath = "assets/\(captureID.uuidString)-original.png"
        let annotatedPath = "assets/\(captureID.uuidString)-annotated.png"
        let asset = EditHereImageAsset(
            relativePath: originalPath,
            sha256: "",
            byteCount: 0,
            width: Double(frozenPixelSize.width),
            height: Double(frozenPixelSize.height),
            scale: Double(image.scale)
        )
        draft.package.captures.append(
            EditHereCapture(
                id: captureID,
                screenID: "test",
                orientation: "portrait",
                originalImage: asset,
                annotatedImage: EditHereImageAsset(
                    relativePath: annotatedPath,
                    sha256: "",
                    byteCount: 0,
                    width: asset.width,
                    height: asset.height,
                    scale: asset.scale
                )
            )
        )
    }

    private func clearFrozenFrame(keepingBatch _: Bool) {
        frozenImage = nil
        frozenCandidates = []
        activeCaptureID = nil
        selectedCandidate = nil
        lastTapPoint = nil
    }

    private func persistDraft() async {
        draft.overallInstruction = overallInstruction
        draft.package.overallInstruction = overallInstruction
        do {
            try await draftStore.save(draft)
        } catch {
            statusMessage = "Failed to save draft: \(error.localizedDescription)"
        }
    }

    private func currentOrientationName() -> String {
        switch UIDevice.current.orientation {
        case .landscapeLeft: return "landscapeLeft"
        case .landscapeRight: return "landscapeRight"
        case .portraitUpsideDown: return "portraitUpsideDown"
        default: return "portrait"
        }
    }
}
