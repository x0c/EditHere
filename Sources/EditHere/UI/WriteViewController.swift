import UIKit

/// System sheet for writing a request. No custom rounded chrome.
///
/// Keyboard geometry, measured on iPhone 13 Pro / iOS 27 (XCUITest, 2026-09-12):
/// UIKit already grows a custom-detent sheet by the keyboard height so the
/// region *above* the keyboard stays at the detent height. Content pinned to the
/// view's safe-area bottom therefore ends up behind the keyboard. The composer
/// bar uses `keyboardLayoutGuide` with clearance above the keyboard
/// while the visible strip keeps its compact height. Do not add keyboard height
/// to the detent (double growth, tall empty card) and do not translate the
/// presented card (UIKit owns that frame).
@MainActor
final class EditHereWriteViewController: UIViewController, UITextViewDelegate {
    var onTextChange: ((String) -> Void)?
    var onDone: (() -> Void)?
    var onRemoveElement: (() -> Void)?
    var onChangeText: (() -> Void)?

    private let textView = UITextView()
    private let placeholderLabel = UILabel()
    /// A real system toolbar inside the compact sheet, above the keyboard.
    let composerBar = UIToolbar()
    private var actionsItem: UIBarButtonItem?
    /// Reserve space for the system toolbar's floating background as well as
    /// the visible clearance. Verify rendered items, not just the bar frame.
    static let composerBarKeyboardGap: CGFloat = 8
    #if DEBUG
    private var geometryObserver: NSObjectProtocol?
    #endif
    private var doneItem: UIBarButtonItem?

    private struct PendingConfiguration {
        var text: String
    }

    private var pending: PendingConfiguration?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.title = "EditHere"

        let collapse = UIBarButtonItem(
            image: UIImage(systemName: "chevron.down"),
            primaryAction: UIAction { [weak self] _ in
                self?.view.endEditing(true)
                self?.onDone?()
            }
        )
        collapse.accessibilityLabel = "Collapse"
        navigationItem.leftBarButtonItem = collapse

        let done = UIBarButtonItem(
            title: "Done",
            primaryAction: UIAction { [weak self] _ in
                self?.view.endEditing(true)
                self?.onDone?()
            }
        )
        if #available(iOS 26.0, *) {
            done.style = .prominent
        } else {
            done.style = .done
        }
        doneItem = done
        navigationItem.rightBarButtonItem = done

        composerBar.translatesAutoresizingMaskIntoConstraints = false
        composerBar.accessibilityIdentifier = "EditHere.composerBar"
        let actions = UIBarButtonItem(title: "Quick Actions", menu: makeActionsMenu())
        actions.accessibilityIdentifier = "Quick Actions"
        actionsItem = actions
        // Trailing, same slot Marks used to occupy. A lone item centers; do not
        // move Actions to leading just because Marks is gone.
        composerBar.setItems([.flexibleSpace(), actions], animated: false)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.font = .preferredFont(forTextStyle: .body)
        textView.delegate = self
        textView.backgroundColor = .clear
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        textView.adjustsFontForContentSizeCategory = true
        textView.keyboardDismissMode = .interactive
        textView.accessibilityLabel = "What should change?"

        placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        placeholderLabel.text = "What should change?"
        placeholderLabel.font = .preferredFont(forTextStyle: .body)
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.adjustsFontForContentSizeCategory = true

        view.addSubview(textView)
        view.addSubview(composerBar)
        textView.addSubview(placeholderLabel)

        if #available(iOS 17.0, *) {
            view.keyboardLayoutGuide.usesBottomSafeArea = true
        }

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            textView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: composerBar.topAnchor, constant: -8),

            composerBar.heightAnchor.constraint(equalToConstant: composerBar.sizeThatFits(CGSize(width: 390, height: 0)).height),
            composerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBar.bottomAnchor.constraint(
                equalTo: view.keyboardLayoutGuide.topAnchor,
                constant: -Self.composerBarKeyboardGap
            ),

            placeholderLabel.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 5),
            placeholderLabel.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8)
        ])

        applyPendingConfiguration()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: false)
        applyPendingConfiguration()
        #if DEBUG
        startGeometryProbeIfRequested()
        #endif
        // After `super` so the popover has its from-frame (bottom). Focusing
        // before `super` skipped the slide and flashed the card in place.
        // Do not wait for viewDidAppear / present completion — that starts
        // the keyboard after the card. Native keyboard timing (~0.25s) then
        // lifts this surface through `keyboardLayoutGuide`.
        requestKeyboardWithAppearance()
    }

    #if DEBUG
    /// In-app measurement avoids installing a separate UI-test runner.
    private func startGeometryProbeIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-EditHereGeometryProbe"),
              geometryObserver == nil else { return }
        geometryObserver = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let screenFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect) ?? .null
            MainActor.assumeIsolated {
                // The notification may precede the final sheet layout.
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(350))
                    self?.reportGeometry(keyboardScreen: screenFrame)
                }
            }
        }
    }

    private func reportGeometry(keyboardScreen: CGRect) {
        guard let window = view.window, !keyboardScreen.isNull, !keyboardScreen.isEmpty else { return }
        view.layoutIfNeeded()
        let keyboard = window.convert(keyboardScreen, from: window.screen.coordinateSpace)
        let convert: (UIView) -> CGRect = { $0.convert($0.bounds, to: window) }
        print("EditHereGeometryProbe keyboard=\(keyboard)")
        print("EditHereGeometryProbe sheet=\(convert(navigationController?.view ?? view))")
        print("EditHereGeometryProbe text=\(convert(textView))")
        print("EditHereGeometryProbe toolbar=\(convert(composerBar))")
        func report(_ child: UIView) {
            if !child.isHidden && child.alpha > 0 {
                let frame = convert(child)
                print("EditHereGeometryProbe child=\(type(of: child)) frame=\(frame) gap=\(keyboard.minY - frame.maxY)")
                child.subviews.forEach(report)
            }
        }
        composerBar.subviews.forEach(report)
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let screenshot = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        if let data = screenshot.pngData(),
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: documents.appendingPathComponent("EditHereGeometryProbe.png"))
        }
        print("EditHereGeometryProbe done")
    }
    #endif

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if shouldFocusEditor, !textView.isFirstResponder {
            focusEditor()
        }
    }

    /// Safe before and after the view loads. Bar buttons are created in `viewDidLoad`.
    func configure(text: String) {
        pending = PendingConfiguration(text: text)
        if isViewLoaded {
            applyPendingConfiguration()
        }
    }

    func focusEditor() {
        requestKeyboardWithAppearance()
    }

    private func requestKeyboardWithAppearance() {
        loadViewIfNeeded()
        guard shouldFocusEditor else { return }
        view.window?.makeKey()
        textView.becomeFirstResponder()
    }

    private var shouldFocusEditor: Bool {
        presentedViewController == nil
            && (navigationController?.topViewController === self || navigationController == nil)
    }

    func textViewDidChange(_ textView: UITextView) {
        placeholderLabel.isHidden = !(textView.text ?? "").isEmpty
        onTextChange?(textView.text ?? "")
    }

    private func applyPendingConfiguration() {
        guard isViewLoaded, let pending else { return }
        if textView.text != pending.text {
            textView.text = pending.text
        }
        placeholderLabel.isHidden = !pending.text.isEmpty
        doneItem?.title = "Done"
        doneItem?.isEnabled = true
        actionsItem?.menu = makeActionsMenu()
    }

    private func makeActionsMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: "Change text",
                image: UIImage(systemName: "textformat"),
                handler: { [weak self] _ in self?.onChangeText?() }
            ),
            UIAction(
                title: "Remove element",
                image: UIImage(systemName: "trash"),
                attributes: .destructive,
                handler: { [weak self] _ in self?.onRemoveElement?() }
            )
        ])
    }
}

enum EditHereKeyboardMotion {
    /// Stock software-keyboard presentation (`keyboardAnimationDurationUserInfoKey` on recent iOS).
    static let duration: TimeInterval = 0.25
}

enum EditHereSheetDetents {
    static let compactID = UISheetPresentationController.Detent.Identifier("edithere.compact")

    /// Visible composer height only. Never add keyboard overlap — UIKit already
    /// grows the sheet by the keyboard height behind the keyboard.
    static func stripHeight(maximumDetentValue: CGFloat, accessibility: Bool) -> CGFloat {
        let fraction: CGFloat = accessibility ? 0.42 : 0.34
        let cap: CGFloat = accessibility ? 360 : 260
        return min(cap, max(0, maximumDetentValue) * fraction)
    }

    /// Short composer strip. Medium/large are omitted so the keyboard cannot grow the
    /// sheet to the status bar (WWDC21: only medium sheets automatically expand).
    @MainActor
    static func configure(_ sheet: UISheetPresentationController) {
        let compact = UISheetPresentationController.Detent.custom(identifier: compactID) { context in
            let accessibility = context.containerTraitCollection.preferredContentSizeCategory.isAccessibilityCategory
            return stripHeight(
                maximumDetentValue: context.maximumDetentValue,
                accessibility: accessibility
            )
        }
        sheet.detents = [compact]
        sheet.selectedDetentIdentifier = compactID
        sheet.largestUndimmedDetentIdentifier = compactID
        sheet.prefersGrabberVisible = true
        sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        sheet.prefersEdgeAttachedInCompactHeight = true
    }
}
