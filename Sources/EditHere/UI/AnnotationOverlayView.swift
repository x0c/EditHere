import UIKit
import EditHereCore

@MainActor
final class EditHereAnnotationOverlayView: UIView, EditHereChromeViewMarker {
    var onPress: ((CGPoint) -> Void)?

    var frozenImage: UIImage? {
        didSet {
            if imageView.image !== frozenImage {
                imageView.image = frozenImage
            }
            marksView.imageScale = frozenImage?.scale ?? 1
        }
    }

    var selectionRect: CGRect? {
        didSet { marksView.selectionRect = selectionRect }
    }

    var selectionIsPoint = false {
        didSet { marksView.selectionIsPoint = selectionIsPoint }
    }

    var provisionalNumber: Int? {
        didSet { marksView.provisionalNumber = provisionalNumber }
    }

      var annotations: [EditHereAnnotation] = [] {
          didSet { marksView.annotations = annotations }
      }

      /// Centered instructional line while waiting for the first canvas tap.
      var showsMarkingHint = false {
          didSet {
              guard showsMarkingHint != oldValue else { return }
              hintLabel.isHidden = !showsMarkingHint
          }
      }
  
      private let imageView = UIImageView()
      private let dimView = UIView()
      private let hintLabel = UILabel()
      private let marksView = EditHereMarksOverlayView()
  
      enum CanvasScrim {
          static let alpha: CGFloat = 0.26
          static let reduceTransparencyAlpha: CGFloat = 0.38
      }

      enum MarkingHint {
          static let text = "Tap an on-screen element to mark it"
      }
  
      override init(frame: CGRect) {
          super.init(frame: frame)
          backgroundColor = .clear
          isOpaque = false
          isMultipleTouchEnabled = false
          accessibilityIdentifier = "EditHere.canvas"
  
          imageView.translatesAutoresizingMaskIntoConstraints = false
          imageView.contentMode = .scaleToFill
          imageView.isUserInteractionEnabled = false
          imageView.isOpaque = true
          imageView.backgroundColor = .black
  
          dimView.translatesAutoresizingMaskIntoConstraints = false
          dimView.isUserInteractionEnabled = false
          dimView.isAccessibilityElement = false
          dimView.accessibilityIdentifier = "EditHere.canvasScrim"
          dimView.isOpaque = false
          applyCanvasScrim()

          hintLabel.translatesAutoresizingMaskIntoConstraints = false
          hintLabel.text = MarkingHint.text
          // Watermark-style: large bold type at low opacity; wrapping is fine.
          hintLabel.font = UIFontMetrics(forTextStyle: .title1).scaledFont(
              for: .systemFont(ofSize: 28, weight: .bold)
          )
          hintLabel.adjustsFontForContentSizeCategory = true
          hintLabel.textColor = UIColor.white.withAlphaComponent(0.42)
          hintLabel.textAlignment = .center
          hintLabel.numberOfLines = 0
          hintLabel.lineBreakMode = .byWordWrapping
          hintLabel.isUserInteractionEnabled = false
          hintLabel.isHidden = true
          hintLabel.accessibilityIdentifier = "EditHere.markingHint"
          hintLabel.layer.shadowOpacity = 0
          hintLabel.isAccessibilityElement = true
          hintLabel.accessibilityTraits = .staticText
  
          marksView.translatesAutoresizingMaskIntoConstraints = false
          marksView.isUserInteractionEnabled = false
          marksView.backgroundColor = .clear
          marksView.isOpaque = false
  
          addSubview(imageView)
          addSubview(dimView)
          addSubview(hintLabel)
          addSubview(marksView)
          NSLayoutConstraint.activate([
              imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
              imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
              imageView.topAnchor.constraint(equalTo: topAnchor),
              imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
              dimView.leadingAnchor.constraint(equalTo: leadingAnchor),
              dimView.trailingAnchor.constraint(equalTo: trailingAnchor),
              dimView.topAnchor.constraint(equalTo: topAnchor),
              dimView.bottomAnchor.constraint(equalTo: bottomAnchor),
              hintLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
              hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
              hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
              hintLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
              marksView.leadingAnchor.constraint(equalTo: leadingAnchor),
              marksView.trailingAnchor.constraint(equalTo: trailingAnchor),
              marksView.topAnchor.constraint(equalTo: topAnchor),
              marksView.bottomAnchor.constraint(equalTo: bottomAnchor)
          ])
      }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        applyCanvasScrim()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyCanvasScrim()
    }

    private func applyCanvasScrim() {
        let alpha = UIAccessibility.isReduceTransparencyEnabled
            ? CanvasScrim.reduceTransparencyAlpha
            : CanvasScrim.alpha
        dimView.backgroundColor = UIColor.black.withAlphaComponent(alpha)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        guard let point = touches.first?.location(in: self) else { return }
        onPress?(point)
    }
}

@MainActor
private final class EditHereMarksOverlayView: UIView {
    var imageScale: CGFloat = 1 {
        didSet { setNeedsDisplay() }
    }
    var selectionRect: CGRect? {
        didSet { setNeedsDisplay() }
    }
    var selectionIsPoint = false {
        didSet { setNeedsDisplay() }
    }
    var provisionalNumber: Int? {
        didSet { setNeedsDisplay() }
    }
    var annotations: [EditHereAnnotation] = [] {
        didSet { setNeedsDisplay() }
    }

    override func draw(_ rect: CGRect) {
        EditHereAnnotatedImageRenderer.drawAnnotations(
            annotations,
            imageScale: imageScale,
            accent: .systemBlue,
            solid: false,
            badgeFont: UIFont.preferredFont(forTextStyle: .caption1)
        )

        UIColor.systemBlue.setStroke()
        if selectionIsPoint, let selectionRect {
            let center = CGPoint(x: selectionRect.midX, y: selectionRect.midY)
            let ring = UIBezierPath(arcCenter: center, radius: 9, startAngle: 0, endAngle: .pi * 2, clockwise: true)
            ring.lineWidth = 1.5
            ring.stroke()
            let cross = UIBezierPath()
            cross.move(to: CGPoint(x: center.x - 5, y: center.y))
            cross.addLine(to: CGPoint(x: center.x + 5, y: center.y))
            cross.move(to: CGPoint(x: center.x, y: center.y - 5))
            cross.addLine(to: CGPoint(x: center.x, y: center.y + 5))
            cross.lineWidth = 1.25
            cross.stroke()
            if let provisionalNumber {
                drawBadge(provisionalNumber, near: CGPoint(x: center.x - 8, y: max(0, center.y - 26)))
            }
        } else if let selectionRect {
            let path = UIBezierPath(roundedRect: selectionRect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4)
            path.lineWidth = 1.5
            path.stroke()
            if let provisionalNumber {
                let origin = CGPoint(x: selectionRect.minX, y: max(0, selectionRect.minY - 20))
                drawBadge(provisionalNumber, near: origin)
            }
        }
    }

    private func drawBadge(_ number: Int, near origin: CGPoint) {
        let text = "\(number)" as NSString
        let font = UIFont.preferredFont(forTextStyle: .caption1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let bg = CGRect(x: origin.x, y: origin.y, width: max(20, size.width + 10), height: size.height + 4)
        UIColor.systemBlue.setFill()
        UIBezierPath(roundedRect: bg, cornerRadius: 8).fill()
        text.draw(
            at: CGPoint(x: bg.midX - size.width / 2, y: bg.minY + 2),
            withAttributes: attributes
        )
    }
}
