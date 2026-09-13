import UIKit
import EditHereCore

public struct EditHereCapturedFrame: Sendable {
    public var image: UIImage
    public var width: Double
    public var height: Double
    public var scale: Double
    public var captureWindows: [ObjectIdentifier]
}

@MainActor
public enum EditHereScreenCapture {
    /// Capture only the provided host windows (same set used for candidate snapshot).
    public static func capture(
        windows: [UIWindow]
    ) throws -> EditHereCapturedFrame {
        let visible = windows
            .filter { $0.isHidden == false && $0.alpha > 0.01 }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }

        guard let primary = visible.last ?? visible.first else {
            throw EditHereCaptureError.noVisibleWindow
        }

        let size = primary.bounds.size
        let scale = primary.screen.scale
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            for window in visible {
                let origin = window.convert(window.bounds.origin, to: primary)
                context.cgContext.saveGState()
                context.cgContext.translateBy(x: origin.x, y: origin.y)
                let ok = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
                if !ok {
                    window.layer.render(in: context.cgContext)
                }
                context.cgContext.restoreGState()
            }
        }

        return EditHereCapturedFrame(
            image: image,
            width: Double(image.size.width * image.scale),
            height: Double(image.size.height * image.scale),
            scale: Double(image.scale),
            captureWindows: visible.map { ObjectIdentifier($0) }
        )
    }

    public static func hostWindows(
        excluding excludedWindows: Set<ObjectIdentifier>,
        preferring scene: UIWindowScene?
    ) -> [UIWindow] {
        let scenes: [UIWindowScene]
        if let scene {
            scenes = [scene]
        } else {
            scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        }
        return scenes
            .flatMap(\.windows)
            .filter { $0.isHidden == false && $0.alpha > 0.01 }
            .filter { !excludedWindows.contains(ObjectIdentifier($0)) }
            .sorted { $0.windowLevel.rawValue < $1.windowLevel.rawValue }
    }
}

public enum EditHereCaptureError: Error, LocalizedError, Sendable {
    case noVisibleWindow
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .noVisibleWindow:
            return "No visible application window to capture."
        case .encodingFailed:
            return "Failed to encode the captured screenshot."
        }
    }
}
