import UIKit
import Combine
import EditHereCore

/// Overlay window that hosts EditHere chrome and passes unrelated touches to the host app.
///
/// Idle: only visible SDK controls (entry button) claim hits.
/// Annotating: the visible frozen canvas is a real subview, so it owns remaining points.
/// A presented card stays in this same window and owns interaction; the canvas
/// behind it must not retarget. Do not add a second higher window.
@MainActor
final class EditHereHostWindow: UIWindow, EditHereChromeViewMarker {
    private var handledEvents = Set<UIEvent>()

    override init(windowScene: UIWindowScene) {
        super.init(windowScene: windowScene)
        windowLevel = .alert + 1
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let rootView = rootViewController?.view else { return nil }

        guard let event else {
            return super.hitTest(point, with: nil)
        }

        // Presented chrome uses stock UIKit routing in this same window.
        // Swallow misses so they never reach the live host, and do not treat
        // the frozen canvas as a retarget target.
        if rootViewController?.presentedViewController != nil {
            return super.hitTest(point, with: event) ?? rootView
        }

        guard let hitView = super.hitTest(point, with: event) else {
            handledEvents.removeAll()
            return nil
        }

        if handledEvents.contains(event) {
            handledEvents.removeAll()
            return hitView
        }

        if hitView === self || hitView === rootView || hitView.isHidden || hitView.alpha < 0.01 {
            return nil
        }

        if #available(iOS 18.0, *) {
            handledEvents.insert(event)
        }
        return hitView
    }
}

@MainActor
final class EditHereRootViewController: UIViewController, UIPopoverPresentationControllerDelegate {
    let session: EditHereSession
    private let floatingBall = EditHereFloatingBallView()
    private let annotationOverlay = EditHereAnnotationOverlayView()
    private let toolbar = UIToolbar()
    private var windowsProvider: () -> [UIWindow]
    private var cancellables = Set<AnyCancellable>()

    private var closeItem: UIBarButtonItem!
    private var marksItem: UIBarButtonItem!
    private var isBottomToolbarPresented = false
    private var toolbarVisibilityAnimator: UIViewPropertyAnimator?

    private weak var writeNavigation: UINavigationController?
    private weak var writeController: EditHereWriteViewController?
    private weak var previousKeyWindow: UIWindow?
    private var lastAnnouncedStatus: String?
      private var isDismissingWrite = false
      private var suppressCombineChrome = false
      private var chromeRefreshQueued = false
      #if DEBUG
      private var didRunPromptPreviewProbe = false
      private var didRunSelectionBarProbe = false
      private var didRunMarkingHintProbe = false
      #endif

    init(session: EditHereSession, windowsProvider: @escaping () -> [UIWindow]) {
        self.session = session
        self.windowsProvider = windowsProvider
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        session.setPreferredScene(view.window?.windowScene)

        floatingBall.translatesAutoresizingMaskIntoConstraints = false
        annotationOverlay.translatesAutoresizingMaskIntoConstraints = false
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        annotationOverlay.isHidden = true
        toolbar.isHidden = true
        toolbar.alpha = 0
        makeToolbarItems()

        // Canvas first, toolbar and entry above it so they stay tappable.
        view.addSubview(annotationOverlay)
        view.addSubview(toolbar)
        view.addSubview(floatingBall)

        NSLayoutConstraint.activate([
            annotationOverlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            annotationOverlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            annotationOverlay.topAnchor.constraint(equalTo: view.topAnchor),
            annotationOverlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            toolbar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            toolbar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            floatingBall.widthAnchor.constraint(equalToConstant: 48),
            floatingBall.heightAnchor.constraint(equalToConstant: 48),
            floatingBall.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            floatingBall.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24)
        ])

        floatingBall.onTap = { [weak self] in
            self?.handleBallTap()
        }
        annotationOverlay.onPress = { [weak self] point in
            self?.applyCanvasPress(at: point)
        }

        session.$mode
            .combineLatest(session.$selectedCandidate, session.$frozenImage, session.$selectionKind)
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleChromeRefresh()
            }
            .store(in: &cancellables)

        session.$draft
            .map { $0.package.annotations.map(\.id) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                self?.scheduleChromeRefresh()
            }
            .store(in: &cancellables)

        session.$statusMessage
            .dropFirst()
            .sink { [weak self] _ in
                self?.announceStatusIfNeeded()
            }
            .store(in: &cancellables)

        refreshChrome()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        session.setPreferredScene(view.window?.windowScene)
          #if DEBUG
          runPromptPreviewProbeIfNeeded()
          runSelectionBarProbeIfNeeded()
          runMarkingHintProbeIfNeeded()
          #endif
      }

    private func makeToolbarItems() {
        closeItem = UIBarButtonItem(
            image: UIImage(systemName: "xmark"),
            primaryAction: UIAction { [weak self] _ in
                self?.dismissWriteIfNeeded(flush: true) {
                    self?.session.minimize()
                }
            }
        )
        closeItem.accessibilityLabel = "Close"

        marksItem = UIBarButtonItem(
            title: "Marks",
            primaryAction: UIAction { [weak self] _ in
                self?.presentMarks()
            }
        )
    }

    private func bottomToolbarItems() -> [UIBarButtonItem] {
        [.flexibleSpace(), marksItem, closeItem]
    }

    /// System toolbar-item dissolve plus a short bottom settle. Instant `isHidden`
    /// with items already installed is what made the bar flash in.
    private func setBottomToolbarPresented(_ presented: Bool, animated: Bool) {
        guard presented != isBottomToolbarPresented else { return }
        isBottomToolbarPresented = presented

        toolbarVisibilityAnimator?.stopAnimation(true)
        toolbarVisibilityAnimator = nil

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        let shouldAnimate = animated && view.window != nil
        let itemAnimation = shouldAnimate && !reduceMotion

        if presented {
            let startFromHidden = toolbar.alpha < 0.01
            toolbar.isHidden = false
            toolbar.isUserInteractionEnabled = true
            toolbar.alpha = 1
            if shouldAnimate, !reduceMotion, startFromHidden {
                toolbar.transform = CGAffineTransform(translationX: 0, y: 16)
            }
            toolbar.layoutIfNeeded()
            toolbar.setItems(bottomToolbarItems(), animated: itemAnimation)
            guard shouldAnimate else {
                toolbar.transform = .identity
                return
            }
            let animator = UIViewPropertyAnimator(
                duration: reduceMotion ? 0.12 : 0.28,
                dampingRatio: 1
            ) {
                self.toolbar.transform = .identity
            }
            toolbarVisibilityAnimator = animator
            animator.startAnimation()
            return
        }

        toolbar.isUserInteractionEnabled = false
        toolbar.setItems([], animated: itemAnimation)

        let conceal = {
            self.toolbar.alpha = 0
            if !reduceMotion {
                self.toolbar.transform = CGAffineTransform(translationX: 0, y: 16)
            }
        }
        let finishHide = { [weak self] in
            guard let self, !self.isBottomToolbarPresented else { return }
            self.toolbar.isHidden = true
            self.toolbar.transform = .identity
        }
        guard shouldAnimate else {
            conceal()
            finishHide()
            return
        }
        let animator = UIViewPropertyAnimator(
            duration: reduceMotion ? 0.12 : 0.22,
            dampingRatio: 1,
            animations: conceal
        )
        animator.addCompletion { position in
            if position == .end {
                finishHide()
            }
        }
        toolbarVisibilityAnimator = animator
        animator.startAnimation()
    }

    private func handleBallTap() {
        switch session.mode {
        case .idle, .browsing:
            session.enterAnnotationMode()
            refreshChrome()
        case .annotating:
            dismissWriteIfNeeded(flush: true) {
                self.session.minimize()
                self.refreshChrome()
            }
        }
    }

    /// True while a presented card (composer, Marks, alert) occupies interaction.
    /// Dismiss-in-flight stays false so Done → next press is not dropped.
    var locksCanvasSelection: Bool {
        presentedViewController != nil && !isDismissingWrite
    }

    func applyCanvasPress(at point: CGPoint) {
        guard !locksCanvasSelection else { return }
        suppressCombineChrome = true
        session.handleTap(at: point, windows: windowsProvider())
        refreshChrome()
        suppressCombineChrome = false
    }

    private func scheduleChromeRefresh() {
        if suppressCombineChrome { return }
        guard !chromeRefreshQueued else { return }
        chromeRefreshQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.chromeRefreshQueued = false
            self?.refreshChrome()
        }
    }

    private func updateMarksBadge() {
        let count = session.submitReadyCount
        marksItem?.title = "\(count) Marks"
        floatingBall.setBadge(count)
    }

    func refreshChrome() {
        let annotating = session.mode == .annotating
        let writeVisible = writeNavigation != nil && presentedViewController != nil

          annotationOverlay.isHidden = !annotating
          floatingBall.isHidden = annotating
          setBottomToolbarPresented(annotating && !writeVisible, animated: true)

          let pageMarks = session.draft.package.annotations.filter {
              $0.captureID == session.activeCaptureID
          }
          // Watermark only while this frozen page has no blue-box marks
          // (committed outlines or the provisional selection).
          annotationOverlay.showsMarkingHint =
              annotating && pageMarks.isEmpty && session.selectedCandidate == nil

          annotationOverlay.frozenImage = session.frozenImage
          annotationOverlay.selectionRect = session.selectedCandidate?.boundsInWindow
          annotationOverlay.selectionIsPoint = session.selectionKind == .point
              || session.selectedCandidate?.className == "PointFallback"
          annotationOverlay.annotations = pageMarks
          annotationOverlay.provisionalNumber = session.selectedCandidate == nil
              ? nil
              : max(1, session.annotationCount + 1)

        updateMarksBadge()

        if annotating, session.selectedCandidate != nil {
            if isDismissingWrite {
                announceStatusIfNeeded()
                return
            }
            presentOrUpdateWriteSheet()
        } else if writeVisible, !isDismissingWrite {
            dismissWriteIfNeeded(flush: false) { [weak self] in
                self?.announceStatusIfNeeded()
            }
            return
        }

        announceStatusIfNeeded()
    }

    /// Remember the host key window, but do not steal key until the composer
    /// is actually focusing. `makeKey()` before `present` skips the slide-up.
    private func rememberHostKeyWindowIfNeeded() {
        guard let overlay = view.window, overlay.isKeyWindow == false else { return }
        if previousKeyWindow == nil {
            previousKeyWindow = windowsProvider().first(where: \.isKeyWindow)
                ?? overlay.windowScene?.windows.first(where: \.isKeyWindow)
        }
    }

    private func restoreHostKeyWindowIfNeeded() {
        let host = previousKeyWindow
            ?? windowsProvider().first(where: { !$0.isHidden && $0.alpha > 0.01 })
        previousKeyWindow = nil
        guard view.window?.isKeyWindow == true else { return }
        host?.makeKey()
    }

    private func presentOrUpdateWriteSheet() {
        rememberHostKeyWindowIfNeeded()
        if let writeController, presentedViewController === writeNavigation {
            writeController.configure(text: session.composerText)
            writeController.focusEditor()
            return
        }
        guard presentedViewController == nil, !isDismissingWrite else { return }

        let write = EditHereWriteViewController()
        wireWriteCallbacks(write)
        write.configure(text: session.composerText)
        let nav = UINavigationController(rootViewController: write)
        nav.modalPresentationStyle = .popover
        nav.preferredContentSize = CGSize(width: view.bounds.width - 16, height: 206)
        if let popover = nav.popoverPresentationController {
            popover.delegate = self
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - view.safeAreaInsets.bottom, width: 1, height: 1)
            popover.permittedArrowDirections = []
            // Do not passthrough the frozen canvas: that lets a tap behind the
            // card move the annotation target. Taps on the screenshot must be
            // claimed by presentation chrome, not the live host, and must not
            // retarget. Tap-outside also must not dismiss the write composer.
            popover.passthroughViews = []
            popover.popoverLayoutMargins = UIEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        }
        nav.presentationController?.delegate = self
        writeNavigation = nav
        writeController = write
        setBottomToolbarPresented(false, animated: true)
        // Match the stock software-keyboard presentation (~0.25s). The
        // default popover duration is slower; stretching keyboard to it
        // feels late, and skipping animation flashes the card in place.
        CATransaction.begin()
        CATransaction.setAnimationDuration(EditHereKeyboardMotion.duration)
        present(nav, animated: true)
        CATransaction.commit()
        #if DEBUG
        runCanvasLockProbeIfNeeded()
        #endif
    }

    #if DEBUG
    /// Same installed sample plus a launch argument; no UI-test runner.
    private func runPromptPreviewProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-EditHerePromptPreviewProbe") else { return }
        guard !didRunPromptPreviewProbe else { return }
        didRunPromptPreviewProbe = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.2))
            if session.mode != .annotating {
                session.enterAnnotationMode()
                try? await Task.sleep(for: .seconds(0.6))
                session.handleTap(at: CGPoint(x: 195, y: 270))
            }
            if session.selectedCandidate == nil {
                session.handleTap(at: CGPoint(x: 195, y: 270))
                try? await Task.sleep(for: .seconds(0.4))
            }
            _ = session.applyRemoveElement()
            try? await Task.sleep(for: .seconds(1.0))
            if session.annotationCount == 0 {
                print("EditHerePromptPreviewProbe failed=no-mark")
                return
            }
            presentMarks()
            try? await Task.sleep(for: .seconds(0.7))
            guard let nav = presentedViewController as? UINavigationController,
                  let marks = nav.viewControllers.first as? EditHereMarksViewController
            else {
                print("EditHerePromptPreviewProbe failed=no-marks")
                return
            }
            let toolbarTitles = marks.toolbarItems?.compactMap(\.title) ?? []
            print(
                "EditHerePromptPreviewProbe marksToolbar=\(toolbarTitles) submit=\(marks.navigationItem.rightBarButtonItem?.title ?? "")"
            )
            try? await Task.sleep(for: .seconds(2.5))
            marks.openPromptPreview()
        }
    }

    /// Same installed sample plus a launch argument; no UI-test runner.
    private func runSelectionBarProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-EditHereSelectionBarProbe") else { return }
        guard !didRunSelectionBarProbe else { return }
        didRunSelectionBarProbe = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.2))
            if session.mode != .annotating {
                session.enterAnnotationMode()
                try? await Task.sleep(for: .seconds(0.6))
            }
            if session.selectedCandidate == nil {
                session.handleTap(at: CGPoint(x: 195, y: 270))
                try? await Task.sleep(for: .seconds(0.4))
            }
            if session.annotationCount == 0 {
                _ = session.applyRemoveElement()
                try? await Task.sleep(for: .seconds(0.8))
            }
            if presentedViewController != nil {
                dismissWriteIfNeeded(flush: false) {}
                try? await Task.sleep(for: .seconds(0.6))
            }
            refreshChrome()
            let titles = toolbar.items?.compactMap(\.title) ?? []
            let lastLabel = toolbar.items?.last?.accessibilityLabel ?? ""
            print(
                "EditHereSelectionBarProbe titles=\(titles) last=\(lastLabel) count=\(toolbar.items?.count ?? -1) marks=\(session.submitReadyCount)"
            )
        }
    }

    /// Same installed sample plus a launch argument; no UI-test runner.
    private func runMarkingHintProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-EditHereMarkingHintProbe") else { return }
        guard !didRunMarkingHintProbe else { return }
        didRunMarkingHintProbe = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.2))
            if session.mode != .annotating {
                session.enterAnnotationMode()
                try? await Task.sleep(for: .seconds(0.6))
            }
            refreshChrome()
            print(
                "EditHereMarkingHintProbe emptyPage shown=\(annotationOverlay.showsMarkingHint) pageMarks=\(session.draft.package.annotations.filter { $0.captureID == session.activeCaptureID }.count) text=\(EditHereAnnotationOverlayView.MarkingHint.text)"
            )
            // Hold so a full-device screenshot can capture the watermark.
            try? await Task.sleep(for: .seconds(8.0))
            applyCanvasPress(at: CGPoint(x: 195, y: 270))
            try? await Task.sleep(for: .seconds(0.4))
            _ = session.applyRemoveElement()
            try? await Task.sleep(for: .seconds(0.8))
            if presentedViewController != nil {
                dismissWriteIfNeeded(flush: false) {}
                try? await Task.sleep(for: .seconds(0.6))
            }
            refreshChrome()
            print(
                "EditHereMarkingHintProbe afterMark shown=\(annotationOverlay.showsMarkingHint) pageMarks=\(session.draft.package.annotations.filter { $0.captureID == session.activeCaptureID }.count)"
            )
        }
    }

    /// Same installed sample plus a launch argument; no UI-test runner.
    private func runCanvasLockProbeIfNeeded() {
        guard ProcessInfo.processInfo.arguments.contains("-EditHereCanvasLockProbe") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            reportCanvasLockProbe(stage: "composer")
            print(
                "EditHereCanvasLockProbe composerBar=\(writeController?.composerBar.items?.compactMap(\.title) ?? [])"
            )
            // Marks is only on the selection toolbar, never pushed from the composer.
        }
    }

    private func reportCanvasLockProbe(stage: String) {
        let before = session.selectedCandidate?.boundsInWindow
        let beforeID = session.selectedCandidate?.viewObjectIdentifier
        let hitPoint = CGPoint(x: 40, y: 140)
        let hit = view.window?.hitTest(hitPoint, with: nil)
        print(
            "EditHereCanvasLockProbe \(stage)-ready locked=\(locksCanvasSelection) presented=\(presentedViewController != nil) hit=\(String(describing: type(of: hit))) before=\(String(describing: before))"
        )
        applyCanvasPress(at: hitPoint)
        let after = session.selectedCandidate?.boundsInWindow
        let afterID = session.selectedCandidate?.viewObjectIdentifier
        print(
            "EditHereCanvasLockProbe \(stage)-after changed=\(beforeID != afterID) after=\(String(describing: after))"
        )
    }
    #endif

    private func wireWriteCallbacks(_ write: EditHereWriteViewController) {
        write.onTextChange = { [weak self] text in
            self?.session.composerText = text
            self?.updateMarksBadge()
        }
        write.onDone = { [weak self] in
            guard let self else { return }
            _ = self.session.flushActiveDraftIfNeeded()
            self.session.dismissActiveSelection()
            self.dismissWriteIfNeeded(flush: false) {
                self.refreshChrome()
            }
        }
        write.onRemoveElement = { [weak self] in
            _ = self?.session.applyRemoveElement()
            self?.refreshChrome()
        }
        write.onChangeText = { [weak self] in
            self?.session.beginChangeText()
            self?.writeController?.focusEditor()
            self?.refreshChrome()
        }
    }

    func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
        .none
    }

    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }

    func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
        // Write composer: tapping the frozen page must not close the card.
        // Marks presented on its own sheet still allows the system swipe-down.
        presentationController.presentedViewController !== writeNavigation
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        let programmatic = isDismissingWrite
        isDismissingWrite = false
        writeNavigation = nil
        writeController = nil
        restoreHostKeyWindowIfNeeded()
        if !programmatic {
            _ = session.flushActiveDraftIfNeeded()
            session.dismissActiveSelection()
        }
        refreshChrome()
    }

    private func dismissWriteIfNeeded(flush: Bool, completion: (() -> Void)? = nil) {
        if flush {
            _ = session.flushActiveDraftIfNeeded()
        }
        guard let presented = presentedViewController, writeNavigation != nil else {
            writeNavigation = nil
            writeController = nil
            isDismissingWrite = false
            restoreHostKeyWindowIfNeeded()
            completion?()
            return
        }
        isDismissingWrite = true
        CATransaction.begin()
        CATransaction.setAnimationDuration(EditHereKeyboardMotion.duration)
        presented.dismiss(animated: true) { [weak self] in
            self?.isDismissingWrite = false
            self?.writeNavigation = nil
            self?.writeController = nil
            self?.restoreHostKeyWindowIfNeeded()
            completion?()
            self?.refreshChrome()
        }
        CATransaction.commit()
    }

    private func presentMarks() {
        // Marks opens only from the selection toolbar. Do not push it onto the
        // write composer — that was a duplicate entry and a duplicate panel.
        guard presentedViewController == nil else { return }
        let list = EditHereMarksViewController(session: session)
        let nav = UINavigationController(rootViewController: list)
        present(nav, animated: true)
    }

    private func announceStatusIfNeeded() {
        guard let message = session.statusMessage, message != lastAnnouncedStatus else { return }
        lastAnnouncedStatus = message
        presentStatus(message)
    }

    private func presentStatus(_ message: String) {
        let alert = UIAlertController(title: "EditHere", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        let presenter = presentedViewController ?? self
        if presenter.presentedViewController != nil {
            return
        }
        presenter.present(alert, animated: true)
    }
}

@MainActor
final class EditHereMarkEditViewController: UIViewController, UITextViewDelegate {
    private let session: EditHereSession
    private let annotationID: UUID
    private let textView = UITextView()

    init(session: EditHereSession, annotation: EditHereAnnotation) {
        self.session = session
        self.annotationID = annotation.id
        super.init(nibName: nil, bundle: nil)
        title = "Mark \(annotation.number)"
        textView.text = annotation.requestText
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.delegate = self
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8)
        ])
    }

    func textViewDidChange(_ textView: UITextView) {
        session.updateAnnotationRequest(id: annotationID, text: textView.text ?? "")
    }
}
