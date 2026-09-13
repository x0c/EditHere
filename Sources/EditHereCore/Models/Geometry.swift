import Foundation

/// Pixel bounds in the capture's coordinate space (origin top-left of the captured image).
public struct EditHereRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func normalized(againstImageWidth imageWidth: Double, height imageHeight: Double) -> EditHereNormalizedRect {
        guard imageWidth > 0, imageHeight > 0 else {
            return EditHereNormalizedRect(x: 0, y: 0, width: 0, height: 0)
        }
        return EditHereNormalizedRect(
            x: x / imageWidth,
            y: y / imageHeight,
            width: width / imageWidth,
            height: height / imageHeight
        )
    }
}

/// Bounds normalized to the capture image size (0...1).
public struct EditHereNormalizedRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public struct EditHerePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}
