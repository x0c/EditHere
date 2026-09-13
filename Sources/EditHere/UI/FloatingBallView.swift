import UIKit

/// Floating entry control: system-configured button only (no painted disk/shadow).
@MainActor
final class EditHereFloatingBallView: UIView, EditHereChromeViewMarker {
    var onTap: (() -> Void)?
    private let button = UIButton(type: .system)
    private let badge = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false

        button.translatesAutoresizingMaskIntoConstraints = false
        button.configuration = Self.entryConfiguration()
        button.addAction(UIAction { [weak self] _ in self?.onTap?() }, for: .touchUpInside)
        button.accessibilityLabel = "Edit screen"
        button.accessibilityIdentifier = "EditHere.entry"
        addSubview(button)

        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.isUserInteractionEnabled = false
        badge.isHidden = true
        badge.configuration = Self.badgeConfiguration()
        addSubview(badge)

        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            badge.topAnchor.constraint(equalTo: topAnchor, constant: -6),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 6)
        ])

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        addGestureRecognizer(pan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setBadge(_ count: Int) {
        badge.isHidden = count == 0
        badge.configuration?.title = "\(count)"
    }

    private static func entryConfiguration() -> UIButton.Configuration {
        var config: UIButton.Configuration
        if #available(iOS 26.0, *) {
            config = .prominentGlass()
        } else {
            config = .filled()
        }
        config.image = UIImage(systemName: "pencil")
        config.cornerStyle = .capsule
        config.buttonSize = .large
        return config
    }

    private static func badgeConfiguration() -> UIButton.Configuration {
        var config: UIButton.Configuration
        if #available(iOS 26.0, *) {
            config = .prominentGlass()
        } else {
            config = .borderedProminent()
        }
        config.cornerStyle = .capsule
        config.contentInsets = NSDirectionalEdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 6)
        config.baseBackgroundColor = .systemRed
        config.baseForegroundColor = .white
        return config
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard let superview else { return }
        let translation = gesture.translation(in: superview)
        var next = CGPoint(x: center.x + translation.x, y: center.y + translation.y)
        let inset = superview.safeAreaInsets
        let minX = inset.left + bounds.width / 2 + 8
        let maxX = superview.bounds.width - inset.right - bounds.width / 2 - 8
        let minY = inset.top + bounds.height / 2 + 8
        let maxY = superview.bounds.height - inset.bottom - bounds.height / 2 - 8
        next.x = min(max(next.x, minX), maxX)
        next.y = min(max(next.y, minY), maxY)
        center = next
        gesture.setTranslation(.zero, in: superview)
    }
}
