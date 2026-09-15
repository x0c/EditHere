import Foundation

public enum EditHereAnnotationAction: String, Codable, Hashable, Sendable, CaseIterable {
    /// Free-form developer request text.
    case customRequest
    /// Request removing the marked UI element from the product (not live data deletion).
    case removeElement
    case changeText
    case adjustAppearance

    public var defaultPrompt: String {
        switch self {
        case .customRequest:
            return ""
        case .removeElement:
            return "Remove this element from the UI."
        case .changeText:
            return "Change the text of this element."
        case .adjustAppearance:
            return "Adjust the appearance of this element."
        }
    }

    public var displayTitle: String {
        switch self {
        case .customRequest:
            return "Custom"
        case .removeElement:
            return "Remove"
        case .changeText:
            return "Change text"
        case .adjustAppearance:
            return "Appearance"
        }
    }
}

public enum EditHereSelectionKind: String, Codable, Hashable, Sendable {
    case bounds
    case point
}

public enum EditHereSelectionConfidence: String, Codable, Hashable, Sendable {
    case high
    case medium
    case low
    case pointFallback
}

public struct EditHereTargetHint: Codable, Hashable, Sendable {
    public var accessibilityLabel: String?
    public var accessibilityIdentifier: String?
    public var className: String?
    public var visibleText: String?
    public var stableTargetID: String?
    public var instanceIndex: Int?
    /// Web-only. Stored for clients; never printed in the Agent prompt.
    public var pageURL: String?
    /// Web-only CSS selector. Stored; never printed in the Agent prompt.
    public var cssSelector: String?
    /// Optional source path from a web bundler (e.g. React). Stored; never printed.
    public var sourceFile: String?
    public var sourceLine: Int?

    public init(
        accessibilityLabel: String? = nil,
        accessibilityIdentifier: String? = nil,
        className: String? = nil,
        visibleText: String? = nil,
        stableTargetID: String? = nil,
        instanceIndex: Int? = nil,
        pageURL: String? = nil,
        cssSelector: String? = nil,
        sourceFile: String? = nil,
        sourceLine: Int? = nil
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityIdentifier = accessibilityIdentifier
        self.className = className
        self.visibleText = visibleText
        self.stableTargetID = stableTargetID
        self.instanceIndex = instanceIndex
        self.pageURL = pageURL
        self.cssSelector = cssSelector
        self.sourceFile = sourceFile
        self.sourceLine = sourceLine
    }
}

public struct EditHereAnnotation: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var number: Int
    public var captureID: UUID
    public var selectionKind: EditHereSelectionKind
    public var bounds: EditHereRect?
    public var normalizedBounds: EditHereNormalizedRect?
    public var point: EditHerePoint?
    public var action: EditHereAnnotationAction
    public var requestText: String
    public var targetHint: EditHereTargetHint
    public var confidence: EditHereSelectionConfidence
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        number: Int,
        captureID: UUID,
        selectionKind: EditHereSelectionKind,
        bounds: EditHereRect? = nil,
        normalizedBounds: EditHereNormalizedRect? = nil,
        point: EditHerePoint? = nil,
        action: EditHereAnnotationAction,
        requestText: String,
        targetHint: EditHereTargetHint = EditHereTargetHint(),
        confidence: EditHereSelectionConfidence,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.number = number
        self.captureID = captureID
        self.selectionKind = selectionKind
        self.bounds = bounds
        self.normalizedBounds = normalizedBounds
        self.point = point
        self.action = action
        self.requestText = requestText
        self.targetHint = targetHint
        self.confidence = confidence
        self.createdAt = createdAt
    }

    public var effectiveRequestText: String {
        let trimmed = requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return action.defaultPrompt
        }
        return trimmed
    }
}
