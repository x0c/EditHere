import UIKit
import EditHereCore

struct EditHerePromptPreviewPage {
    let pageIndex: Int
    let screenID: String
    let annotated: UIImage?
}

struct EditHerePromptPreviewContent {
    let prompt: String
    let pages: [EditHerePromptPreviewPage]
}

/// Read-only view of the Agent packet. Not a Submit or plan-approval gate.
@MainActor
final class EditHerePromptPreviewViewController: UIViewController {
    private let session: EditHereSession
    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var loadTask: Task<Void, Never>?

    init(session: EditHereSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
        title = "Prompt"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.alwaysBounceVertical = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .vertical
        stack.spacing = 16
        stack.alignment = .fill
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.frameLayoutGuide.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.frameLayoutGuide.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.frameLayoutGuide.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.frameLayoutGuide.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor, constant: -32)
        ])
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let content = await session.promptPreviewContent()
            guard !Task.isCancelled else { return }
            render(content)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(true, animated: animated)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-EditHerePromptPreviewProbe") {
            print(
                "EditHerePromptPreviewProbe title=\(title ?? "") views=\(stack.arrangedSubviews.count)"
            )
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                if let promptView = stack.arrangedSubviews.compactMap({ $0 as? UITextView }).first {
                    let rect = promptView.convert(promptView.bounds, to: scrollView)
                    scrollView.setContentOffset(CGPoint(x: 0, y: max(0, rect.minY - 12)), animated: false)
                    print("EditHerePromptPreviewProbe scrolledToPrompt")
                }
            }
        }
        #endif
    }

    deinit {
        loadTask?.cancel()
    }

    private func render(_ content: EditHerePromptPreviewContent) {
        contentUnavailableConfiguration = nil
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if content.pages.isEmpty {
            stack.addArrangedSubview(heading("Screenshots", style: .title3))
            stack.addArrangedSubview(caption("No page captures with marks were included."))
        } else {
            for page in content.pages {
                stack.addArrangedSubview(
                    heading("Page \(page.pageIndex) · \(page.screenID)", style: .title3)
                )
                stack.addArrangedSubview(imageView(page.annotated))
            }
        }
        let text = UITextView()
        text.isEditable = false
        text.isScrollEnabled = false
        text.backgroundColor = .clear
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.text = content.prompt
        text.textContainerInset = .zero
        text.textContainer.lineFragmentPadding = 0
        text.setContentCompressionResistancePriority(.required, for: .vertical)
        stack.addArrangedSubview(text)
        view.layoutIfNeeded()
        scrollView.setContentOffset(.zero, animated: false)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-EditHerePromptPreviewProbe") {
            let hasAnnotated = content.pages.contains { $0.annotated != nil }
            let listsOriginal = content.prompt.contains("- Original:")
                || content.prompt.contains("Use the original image")
            print(
                "EditHerePromptPreviewProbe pages=\(content.pages.count) annotated=\(hasAnnotated) originalListed=\(listsOriginal) onScreen=\(content.prompt.contains("On screen:")) privateClass=\(content.prompt.contains("_UI")) boundsDump=\(content.prompt.contains("Normalized bounds")) metaJunk=\(content.prompt.contains("Prompt template:") || content.prompt.contains("plan approval") || content.prompt.contains("single session") || content.prompt.contains("## Task"))"
            )
        }
        #endif
    }

    private func heading(_ text: String, style: UIFont.TextStyle) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }

    private func caption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.textColor = .secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0
        return label
    }

    private func imageView(_ image: UIImage?) -> UIView {
        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.backgroundColor = .secondarySystemFill
        view.adjustsImageSizeForAccessibilityContentSizeCategory = true
        let width = image?.size.width ?? 1
        let height = image?.size.height ?? 1
        view.heightAnchor.constraint(
            equalTo: view.widthAnchor,
            multiplier: height / max(width, 1)
        ).isActive = true
        view.accessibilityLabel = image == nil ? "Missing screenshot" : "Screenshot"
        return view
    }
}
