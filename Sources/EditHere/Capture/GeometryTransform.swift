import CoreGraphics
import UIKit
import EditHereCore

/// Single screenshot-pixel coordinate system for preview and export.
public enum EditHereGeometryTransform {
    /// Convert screenshot-pixel bounds into the image's point drawing space.
    public static func pointRect(fromPixelBounds bounds: EditHereRect, imageScale: CGFloat) -> CGRect {
        let scale = max(imageScale, 1)
        return CGRect(
            x: bounds.x / Double(scale),
            y: bounds.y / Double(scale),
            width: bounds.width / Double(scale),
            height: bounds.height / Double(scale)
        )
    }

    public static func point(fromPixelPoint point: EditHerePoint, imageScale: CGFloat) -> CGPoint {
        let scale = max(imageScale, 1)
        return CGPoint(x: point.x / Double(scale), y: point.y / Double(scale))
    }

    public static func pixelRect(fromWindowRect windowRect: CGRect, imageScale: CGFloat) -> EditHereRect {
        let scale = Double(max(imageScale, 1))
        return EditHereRect(
            x: Double(windowRect.origin.x) * scale,
            y: Double(windowRect.origin.y) * scale,
            width: Double(windowRect.size.width) * scale,
            height: Double(windowRect.size.height) * scale
        )
    }

    public static func pixelPoint(fromWindowPoint windowPoint: CGPoint, imageScale: CGFloat) -> EditHerePoint {
        let scale = Double(max(imageScale, 1))
        return EditHerePoint(x: Double(windowPoint.x) * scale, y: Double(windowPoint.y) * scale)
    }
}
