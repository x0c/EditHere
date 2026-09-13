import XCTest
import UIKit
@testable import EditHere
import EditHereCore

actor CountingDestination: EditHereDestination {
    nonisolated let destinationID = "review"
    nonisolated let displayName = "Review"
    nonisolated let capabilities = EditHereDestinationCapabilities(
        supportsImages: true,
        supportsDirectExecution: true
    )
    var calls = 0

    func submit(
        package: EditHereEvidencePackage,
        assetRootURL: URL
    ) async throws -> EditHereSubmissionReceipt {
        calls += 1
        try await Task.sleep(nanoseconds: 100_000_000)
        return EditHereSubmissionReceipt(
            destinationID: destinationID,
            remoteTaskID: UUID().uuidString,
            submissionID: package.id,
            state: .working
        )
    }
}

final class EditHereRegressionTests: XCTestCase {
    func package() -> EditHereEvidencePackage {
        EditHereEvidencePackage(
            app: EditHereAppBinding(
                bundleIdentifier: "review",
                displayName: "Review",
                marketingVersion: "1",
                buildNumber: "1"
            ),
            environment: EditHereEnvironment(
                screenWidth: 900,
                screenHeight: 1800,
                screenScale: 3,
                localeIdentifier: "en"
            )
        )
    }

    @MainActor
    func testRendererCoordinatesMatchScreenshotPixels() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let original = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 600), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 300, height: 600))
        }
        let annotation = EditHereAnnotation(
            number: 1,
            captureID: UUID(),
            selectionKind: .bounds,
            bounds: EditHereRect(x: 450, y: 900, width: 180, height: 180),
            action: .removeElement,
            requestText: "remove",
            confidence: .high
        )
        let output = EditHereAnnotatedImageRenderer.render(
            original: original,
            annotations: [annotation]
        )
        let cg = try XCTUnwrap(output.cgImage)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let ctx = CGContext(
            data: &pixels,
            width: cg.width,
            height: cg.height,
            bitsPerComponent: 8,
            bytesPerRow: cg.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))

        var minX = cg.width
        var maxX = 0
        for y in 0..<cg.height {
            for x in 0..<cg.width {
                let i = (y * cg.width + x) * 4
                // System blue stroke: strong blue channel, lower red.
                if pixels[i + 2] > 150 && pixels[i] < 120 && pixels[i + 1] < 180 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                }
            }
        }
        XCTAssertGreaterThan(minX, 400, "Exported marker incorrectly shifted left; x=\(minX)...\(maxX)")
        XCTAssertLessThan(maxX, 700, "Exported marker incorrectly oversized; x=\(minX)...\(maxX)")
    }

    func testDuplicateSubmissionIsSingleFlight() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edithere-outbox-\(UUID().uuidString)", isDirectory: true)
        let outbox = try EditHereOutbox(directoryURL: root)
        let submitter = EditHereSubmitter(outbox: outbox)
        let dest = CountingDestination()
        let draft = EditHereDraftBatch(package: package())
        async let a = submitter.submit(draft: draft, destination: dest)
        async let b = submitter.submit(draft: draft, destination: dest)
        _ = try await (a, b)
        let calls = await dest.calls
        let records = await outbox.allRecords()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(records.count, 1)
        try? FileManager.default.removeItem(at: root)
    }

    @MainActor
    func testSelectorIgnoresOpaqueCover() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        let button = UIButton(frame: CGRect(x: 20, y: 100, width: 200, height: 60))
        button.setTitle("Hidden action", for: .normal)
        window.addSubview(button)
        let cover = UIView(frame: window.bounds)
        cover.backgroundColor = .white
        cover.isOpaque = true
        window.addSubview(cover)
        window.isHidden = false
        defer { window.isHidden = true }

        let selector = EditHereViewSelector()
        let candidates = selector.candidates(
            at: CGPoint(x: 100, y: 130),
            in: [window],
            excluding: []
        )
        let chosen = selector.preferredCandidate(
            from: candidates,
            previous: nil,
            samePointRetap: false
        )
        XCTAssertNotEqual(
            chosen?.viewObjectIdentifier,
            ObjectIdentifier(button),
            "Selected hidden button behind opaque cover"
        )
    }

    @MainActor
    func testSelectorCollectsDescendantLabelText() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 300, height: 600))
        let cell = UIView(frame: CGRect(x: 20, y: 100, width: 260, height: 80))
        let title = UILabel(frame: CGRect(x: 8, y: 8, width: 240, height: 24))
        title.text = "Promo card"
        let subtitle = UILabel(frame: CGRect(x: 8, y: 36, width: 240, height: 24))
        subtitle.text = "Tap Edit to remove"
        cell.addSubview(title)
        cell.addSubview(subtitle)
        window.addSubview(cell)
        window.isHidden = false
        defer { window.isHidden = true }

        let selector = EditHereViewSelector()
        let snapshot = selector.snapshotCandidates(in: [window], excluding: [])
        let hit = snapshot.first { $0.viewObjectIdentifier == ObjectIdentifier(cell) }
        XCTAssertTrue(
            hit?.visibleText?.contains("Promo card") == true,
            "Parent mark must include descendant wording for the Agent prompt"
        )
    }

    @MainActor
    func testWriteControllerConfigureBeforeViewLoads() {
        let write = EditHereWriteViewController()
        write.configure(text: "Remove this card")
        XCTAssertFalse(write.isViewLoaded, "configure must not force the view to load")

        _ = UINavigationController(rootViewController: write)
        write.loadViewIfNeeded()

        XCTAssertEqual(write.navigationItem.title, "EditHere")
        XCTAssertEqual(write.composerBar.items?.compactMap(\.title), ["Quick Actions"])
        XCTAssertEqual(write.composerBar.items?.count, 2, "Leading flexible space keeps Quick Actions trailing")
        XCTAssertNil(write.composerBar.items?.first?.title)
        XCTAssertEqual(write.composerBar.items?.last?.title, "Quick Actions")
        XCTAssertFalse(
            write.composerBar.items?.contains(where: { $0.title == "Marks" }) == true,
            "Marks belongs on the selection toolbar, not the write composer"
        )
        XCTAssertNotNil(write.composerBar.items?.last?.menu)
        XCTAssertTrue(
            write.view.constraints.contains {
                ($0.firstItem === write.composerBar && $0.firstAttribute == .bottom
                    && $0.secondItem === write.view.keyboardLayoutGuide
                    && $0.constant == -EditHereWriteViewController.composerBarKeyboardGap)
            },
            "Composer row must sit a fixed gap above the keyboard top, not on the sheet bottom"
        )
        XCTAssertEqual(write.view.backgroundColor, .systemBackground)
        XCTAssertEqual(write.navigationItem.rightBarButtonItem?.title, "Done")
        XCTAssertEqual(write.navigationItem.rightBarButtonItem?.isEnabled, true)
        XCTAssertTrue(write.view.subviews.compactMap { $0 as? UILabel }.isEmpty)

        write.configure(text: "Change the text to: Hello")
        XCTAssertEqual(write.navigationItem.rightBarButtonItem?.title, "Done")
        XCTAssertEqual(write.navigationItem.rightBarButtonItem?.isEnabled, true)
        if #available(iOS 26.0, *) {
            XCTAssertNil(write.navigationItem.subtitle)
        }
    }

    @MainActor
    func testWriteControllerRequestsKeyboardDuringWillAppear() {
        let write = EditHereWriteViewController()
        let nav = UINavigationController(rootViewController: write)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = nav
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        write.loadViewIfNeeded()
        write.beginAppearanceTransition(true, animated: false)
        let editor = firstTextView(in: write.view)
        XCTAssertNotNil(editor, "Write surface must keep a system text view")
        XCTAssertTrue(
            editor?.isFirstResponder == true,
            "Keyboard focus must start in viewWillAppear so the card slides with the keyboard, not after present completes"
        )
        write.endAppearanceTransition()
    }

    @MainActor
    private func firstTextView(in view: UIView) -> UITextView? {
        if let textView = view as? UITextView { return textView }
        for child in view.subviews {
            if let found = firstTextView(in: child) { return found }
        }
        return nil
    }

    @MainActor
    func testWriteSheetStaysOnCompactDetent() throws {
        let nav = UINavigationController(rootViewController: UIViewController())
        nav.modalPresentationStyle = .pageSheet
        let sheet = try XCTUnwrap(nav.sheetPresentationController)
        EditHereSheetDetents.configure(sheet)

        XCTAssertEqual(sheet.detents.count, 1)
        XCTAssertEqual(sheet.selectedDetentIdentifier, EditHereSheetDetents.compactID)
        XCTAssertEqual(sheet.largestUndimmedDetentIdentifier, EditHereSheetDetents.compactID)
        XCTAssertFalse(sheet.prefersScrollingExpandsWhenScrolledToEdge)
        XCTAssertTrue(sheet.prefersEdgeAttachedInCompactHeight)
    }

    func testCompactStripHeightExcludesKeyboard() {
        XCTAssertEqual(EditHereSheetDetents.stripHeight(maximumDetentValue: 800, accessibility: false), 260)
        XCTAssertEqual(EditHereSheetDetents.stripHeight(maximumDetentValue: 500, accessibility: false), 170)
        XCTAssertEqual(EditHereSheetDetents.stripHeight(maximumDetentValue: 800, accessibility: true), 336)
    }

    @MainActor
    func testCommitDoesNotEncodeAnnotatedPNGOnTheSameTurn() async throws {
        let session = try makeSession()
        let image = makeTestImage()
        var tokens: [NSObject] = []
        session.testing_prepareFrozenCapture(
            image: image,
            candidates: (0..<5).map { index in
                let token = NSObject()
                tokens.append(token)
                return makeCandidate(
                    token: token,
                    rect: CGRect(x: 10, y: CGFloat(20 + index * 50), width: 120, height: 36)
                )
            }
        )
        XCTAssertNotNil(image.cgImage)

        for index in 0..<5 {
            session.handleTap(at: CGPoint(x: 40, y: CGFloat(30 + index * 50)))
            session.composerText = "Change item \(index + 1)"
            XCTAssertEqual(
                session.annotatedExportCount,
                0,
                "Evidence PNG must not encode on the tap/type turn (mark \(index + 1))"
            )
        }
        XCTAssertTrue(session.flushActiveDraftIfNeeded())
        XCTAssertEqual(session.annotationCount, 5)
        XCTAssertEqual(session.annotatedExportCount, 0)

        await session.prepareEvidenceForSubmit()
        XCTAssertGreaterThan(session.annotatedExportCount, 0)
        let capture = try XCTUnwrap(session.draft.package.captures.first)
        XCTAssertGreaterThan(session.draft.assets[capture.annotatedImage.relativePath]?.count ?? 0, 0)
        XCTAssertFalse(capture.annotatedImage.sha256.isEmpty)
        _ = tokens
    }

    @MainActor
    func testRemoveAnnotationDoesNotEncodeOnTheCall() async throws {
        let session = try makeSession()
        let token = NSObject()
        session.testing_prepareFrozenCapture(
            image: makeTestImage(),
            candidates: [makeCandidate(token: token, rect: CGRect(x: 10, y: 20, width: 120, height: 36))]
        )
        session.handleTap(at: CGPoint(x: 40, y: 30))
        session.composerText = "First mark"
        XCTAssertTrue(session.flushActiveDraftIfNeeded())
        session.handleTap(at: CGPoint(x: 40, y: 30))
        session.composerText = "Second mark"
        XCTAssertTrue(session.flushActiveDraftIfNeeded())
        XCTAssertEqual(session.annotationCount, 2)

        let encodedBeforeDelete = session.annotatedExportCount
        let firstID = session.draft.package.annotations[0].id
        session.removeAnnotation(id: firstID)

        XCTAssertEqual(session.annotationCount, 1)
        XCTAssertEqual(
            session.annotatedExportCount,
            encodedBeforeDelete,
            "Delete must not encode evidence PNGs on the swipe turn"
        )
    }

    @MainActor
    func testMarksListDeleteDoesNotMutateSessionOnTheSwipeTurn() async throws {
        let session = try makeSession()
        let token = NSObject()
        session.testing_prepareFrozenCapture(
            image: makeTestImage(),
            candidates: [makeCandidate(token: token, rect: CGRect(x: 10, y: 20, width: 120, height: 36))]
        )
        session.handleTap(at: CGPoint(x: 40, y: 30))
        session.composerText = "First mark"
        XCTAssertTrue(session.flushActiveDraftIfNeeded())
        session.handleTap(at: CGPoint(x: 40, y: 30))
        session.composerText = "Second mark"
        XCTAssertTrue(session.flushActiveDraftIfNeeded())
        XCTAssertEqual(session.annotationCount, 2)

        let controller = EditHereMarksViewController(session: session)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        controller.tableView.reloadData()
        controller.tableView.layoutIfNeeded()
        XCTAssertTrue(controller.tableView.style == .insetGrouped)
        XCTAssertEqual(controller.tableView(controller.tableView, numberOfRowsInSection: 0), 2)
        let actions = controller.tableView(
            controller.tableView,
            trailingSwipeActionsConfigurationForRowAt: IndexPath(row: 0, section: 0)
        )
        XCTAssertNil(actions?.actions.first?.title)
        XCTAssertNotNil(actions?.actions.first?.image)
        for remaining in [1, 0] {
            await withCheckedContinuation { continuation in
                let encodedBeforeDelete = session.annotatedExportCount
                controller.deleteRow(at: IndexPath(row: 0, section: 0)) { success in
                    XCTAssertTrue(success)
                    continuation.resume()
                }
                XCTAssertEqual(session.annotatedExportCount, encodedBeforeDelete)
            }
            XCTAssertEqual(session.annotationCount, remaining)
            XCTAssertEqual(controller.tableView(controller.tableView, numberOfRowsInSection: 0), remaining)
        }
    }

    @MainActor
    func testMarksToolbarHasTrailingPreviewNotSubmit() throws {
        let session = try makeSession()
        let controller = EditHereMarksViewController(session: session)
        let nav = UINavigationController(rootViewController: controller)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = nav
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.toolbarItems?.last?.title, "Preview")
        XCTAssertEqual(controller.toolbarItems?.last?.accessibilityLabel, "Preview prompt")
        XCTAssertTrue(controller.navigationItem.rightBarButtonItem?.title?.hasPrefix("Submit") == true)
        XCTAssertEqual(controller.toolbarItems?.last?.isEnabled, false)
    }

    @MainActor
    func testPromptPreviewIncludesAnnotatedPageAndCanonicalText() async throws {
        let session = try makeSession()
        let token = NSObject()
        session.testing_prepareFrozenCapture(
            image: makeTestImage(),
            candidates: [makeCandidate(token: token, rect: CGRect(x: 10, y: 20, width: 120, height: 36))]
        )
        session.handleTap(at: CGPoint(x: 40, y: 30))
        session.composerText = "Move this title lower"
        XCTAssertTrue(session.flushActiveDraftIfNeeded())
        let content = await session.promptPreviewContent()
        XCTAssertFalse(content.prompt.contains("Prompt template:"))
        XCTAssertFalse(content.prompt.contains("plan approval"))
        XCTAssertFalse(content.prompt.contains("single session"))
        XCTAssertFalse(content.prompt.contains("EditHere change request"))
        XCTAssertFalse(content.prompt.contains("Bundle:"))
        XCTAssertFalse(content.prompt.contains("## Task"))
        XCTAssertTrue(content.prompt.contains("Move this title lower"))
        XCTAssertFalse(content.prompt.contains("Request:"))
        XCTAssertTrue(content.prompt.contains("On screen: Item"))
        XCTAssertFalse(content.prompt.contains("- Original:"))
        XCTAssertFalse(content.prompt.contains("assets/"))
        XCTAssertFalse(content.prompt.contains("Normalized bounds"))
        XCTAssertEqual(content.pages.count, 1)
        XCTAssertNotNil(content.pages[0].annotated)
    }

    @MainActor
    func testOverlayUsesImageViewForFrozenCapture() {
        let overlay = EditHereAnnotationOverlayView(frame: CGRect(x: 0, y: 0, width: 120, height: 240))
        let image = makeTestImage()
        overlay.frozenImage = image
        let imageView = overlay.subviews.compactMap { $0 as? UIImageView }.first
        XCTAssertIdentical(imageView?.image, image)
        overlay.selectionRect = CGRect(x: 10, y: 10, width: 40, height: 20)
        XCTAssertIdentical(imageView?.image, image, "Selection changes must not replace the frozen capture")
        let scrim = overlay.subviews.first { $0.accessibilityIdentifier == "EditHere.canvasScrim" }
        XCTAssertNotNil(scrim)
        let expected = UIAccessibility.isReduceTransparencyEnabled
            ? EditHereAnnotationOverlayView.CanvasScrim.reduceTransparencyAlpha
            : EditHereAnnotationOverlayView.CanvasScrim.alpha
        XCTAssertEqual(scrim?.backgroundColor?.cgColor.alpha ?? 0, expected, accuracy: 0.001)
        XCTAssertEqual(EditHereAnnotationOverlayView.CanvasScrim.alpha, 0.26, accuracy: 0.001)
        XCTAssertGreaterThan(expected, 0.18, "Annotation-mode wash must stay clearly darker than a faint overlay")
    }

    @MainActor
    func testMarkingHintShowsWhenCurrentPageHasNoBlueBoxes() throws {
        let overlay = EditHereAnnotationOverlayView(frame: CGRect(x: 0, y: 0, width: 120, height: 240))
        let hint = overlay.subviews.first { $0.accessibilityIdentifier == "EditHere.markingHint" } as? UILabel
        XCTAssertEqual(hint?.text, EditHereAnnotationOverlayView.MarkingHint.text)
        XCTAssertTrue(hint?.isHidden ?? false)

        overlay.showsMarkingHint = true
        XCTAssertFalse(hint?.isHidden ?? true)

        let session = try makeSession()
        let token = NSObject()
        session.testing_prepareFrozenCapture(
            image: makeTestImage(),
            candidates: [makeCandidate(token: token, rect: CGRect(x: 10, y: 20, width: 120, height: 36))]
        )
        let root = EditHereRootViewController(session: session, windowsProvider: { [] })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        root.loadViewIfNeeded()
        root.refreshChrome()

        let liveHint = root.view.subviews
            .flatMap(\.subviews)
            .first { $0.accessibilityIdentifier == "EditHere.markingHint" } as? UILabel
        XCTAssertNotNil(liveHint)
        XCTAssertNil(session.selectedCandidate)
        XCTAssertFalse(liveHint?.isHidden ?? true, "Empty frozen page must show the watermark")

        root.applyCanvasPress(at: CGPoint(x: 40, y: 30))
        root.refreshChrome()
        XCTAssertNotNil(session.selectedCandidate)
        XCTAssertTrue(
            liveHint?.isHidden ?? false,
            "A provisional blue box on this page must hide the watermark"
        )

        XCTAssertTrue(session.applyRemoveElement())
        root.refreshChrome()
        XCTAssertGreaterThan(session.annotationCount, 0)
        XCTAssertTrue(liveHint?.isHidden ?? false, "Committed blue boxes on this page keep the watermark hidden")
    }

    @MainActor
    func testPresentedCardDoesNotRetargetFrozenCanvas() throws {
        let session = try makeSession()
        let token = NSObject()
        session.testing_prepareFrozenCapture(
            image: makeTestImage(),
            candidates: [makeCandidate(token: token, rect: CGRect(x: 10, y: 20, width: 120, height: 36))]
        )
        let root = EditHereRootViewController(session: session, windowsProvider: { [] })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        root.loadViewIfNeeded()

        let blocker = UIViewController()
        blocker.modalPresentationStyle = .overFullScreen
        root.present(blocker, animated: false)
        XCTAssertNotNil(root.presentedViewController)
        XCTAssertTrue(root.locksCanvasSelection)

        root.applyCanvasPress(at: CGPoint(x: 40, y: 30))
        XCTAssertNil(
            session.selectedCandidate,
            "A presented card must not move the annotation target on the frozen page"
        )
    }

    @MainActor
    func testCanvasPressSelectsWhenNoPresentedCard() throws {
        let session = try makeSession()
        let token = NSObject()
        session.testing_prepareFrozenCapture(
            image: makeTestImage(),
            candidates: [makeCandidate(token: token, rect: CGRect(x: 10, y: 20, width: 120, height: 36))]
        )
        let root = EditHereRootViewController(session: session, windowsProvider: { [] })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        root.loadViewIfNeeded()

        XCTAssertFalse(root.locksCanvasSelection)
        root.applyCanvasPress(at: CGPoint(x: 40, y: 30))
        XCTAssertEqual(session.selectedCandidate?.viewObjectIdentifier, ObjectIdentifier(token))
    }

    @MainActor
    func testSelectionToolbarTrailsMarksThenClose() throws {
        let session = try makeSession()
        let token = NSObject()
        session.testing_prepareFrozenCapture(
            image: makeTestImage(),
            candidates: [makeCandidate(token: token, rect: CGRect(x: 10, y: 20, width: 120, height: 36))]
        )
        let root = EditHereRootViewController(session: session, windowsProvider: { [] })
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        root.loadViewIfNeeded()
        root.refreshChrome()

        let toolbar = root.view.subviews.compactMap { $0 as? UIToolbar }.first
        XCTAssertEqual(toolbar?.items?.count, 3, "Leading flexible space, Marks, then Close")
        XCTAssertNil(toolbar?.items?.first?.title)
        XCTAssertNil(toolbar?.items?.first?.image)
        XCTAssertEqual(toolbar?.items?[1].title, "0 Marks")
        XCTAssertEqual(toolbar?.items?.last?.accessibilityLabel, "Close")
        XCTAssertNil(toolbar?.items?.last?.title)
    }

    @MainActor
    private func makeSession() throws -> EditHereSession {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edithere-smooth-\(UUID().uuidString)", isDirectory: true)
        let store = EditHereFileDraftStore(directoryURL: root)
        let outbox = try EditHereOutbox(directoryURL: root.appendingPathComponent("outbox", isDirectory: true))
        return EditHereSession(
            configuration: EditHereConfiguration(destination: CountingDestination()),
            draftStore: store,
            submitter: EditHereSubmitter(outbox: outbox)
        )
    }

    @MainActor
    private func makeTestImage() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 200, height: 400), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 400))
        }
    }

    private func makeCandidate(token: NSObject, rect: CGRect) -> EditHereViewCandidate {
        EditHereViewCandidate(
            viewObjectIdentifier: ObjectIdentifier(token),
            parentObjectIdentifier: nil,
            boundsInWindow: rect,
            className: "UIButton",
            accessibilityLabel: "Item",
            accessibilityIdentifier: nil,
            visibleText: "Item",
            isControlLike: true,
            depth: 2,
            paintOrder: 1,
            isOpaque: false
        )
    }
}
