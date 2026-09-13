import UIKit
import EditHereCore

public enum EditHereAnnotatedImageRenderer {
    @MainActor
    public static func render(
        original: UIImage,
        annotations: [EditHereAnnotation]
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = original.scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: original.size, format: format)
        return renderer.image { _ in
            original.draw(in: CGRect(origin: .zero, size: original.size))
            drawAnnotations(
                annotations,
                imageScale: original.scale,
                accent: .systemBlue,
                badgeFont: UIFont.preferredFont(forTextStyle: .caption1).bold()
            )
        }
    }

    /// Shared stroke/badge drawing for export and live overlay (point space).
    public static func drawAnnotations(
        _ annotations: [EditHereAnnotation],
        imageScale: CGFloat,
        accent: UIColor,
        solid: Bool = true,
        badgeFont: UIFont
    ) {
        for annotation in annotations {
            accent.setStroke()
            accent.setFill()
            if annotation.selectionKind == .bounds, let bounds = annotation.bounds {
                let rect = EditHereGeometryTransform.pointRect(fromPixelBounds: bounds, imageScale: imageScale)
                    .insetBy(dx: -2, dy: -2)
                let path = UIBezierPath(roundedRect: rect, cornerRadius: 6)
                path.lineWidth = 2
                if !solid {
                    let dashes: [CGFloat] = [4, 3]
                    path.setLineDash(dashes, count: dashes.count, phase: 0)
                }
                path.stroke()
                let badgeOrigin = CGPoint(x: rect.minX, y: max(0, rect.minY - 18))
                drawBadge(number: annotation.number, at: badgeOrigin, fill: accent, font: badgeFont)
            } else if let point = annotation.point {
                let center = EditHereGeometryTransform.point(fromPixelPoint: point, imageScale: imageScale)
                let ring = UIBezierPath(arcCenter: center, radius: 10, startAngle: 0, endAngle: .pi * 2, clockwise: true)
                ring.lineWidth = 2
                ring.stroke()
                let cross = UIBezierPath()
                cross.move(to: CGPoint(x: center.x - 6, y: center.y))
                cross.addLine(to: CGPoint(x: center.x + 6, y: center.y))
                cross.move(to: CGPoint(x: center.x, y: center.y - 6))
                cross.addLine(to: CGPoint(x: center.x, y: center.y + 6))
                cross.lineWidth = 1.5
                cross.stroke()
                drawBadge(
                    number: annotation.number,
                    at: CGPoint(x: center.x - 8, y: max(0, center.y - 28)),
                    fill: accent,
                    font: badgeFont
                )
            }
        }
    }

    /// Bitmap PNG for the evidence package. Safe off the main thread for raster screenshots.
    nonisolated public static func exportPNGData(
        original: CGImage,
        scale: CGFloat,
        size: CGSize,
        annotations: [EditHereAnnotation]
    ) -> Data? {
        let image = UIImage(cgImage: original, scale: scale, orientation: .up)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
            drawAnnotations(
                annotations,
                imageScale: scale,
                accent: UIColor(red: 0, green: 0.478, blue: 1, alpha: 1),
                badgeFont: UIFont.systemFont(ofSize: 12, weight: .bold)
            )
        }
        guard let cgImage = rendered.cgImage else { return nil }
        return EditHereImageEncoding.pngData(from: cgImage)
    }

    private static func drawBadge(number: Int, at origin: CGPoint, fill: UIColor, font: UIFont) {
        let text = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white
        ]
        let size = text.size(withAttributes: attributes)
        let bg = CGRect(x: origin.x, y: origin.y, width: max(20, size.width + 10), height: size.height + 4)
        fill.setFill()
        UIBezierPath(roundedRect: bg, cornerRadius: 8).fill()
        text.draw(
            at: CGPoint(x: bg.midX - size.width / 2, y: bg.minY + 2),
            withAttributes: attributes
        )
    }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
