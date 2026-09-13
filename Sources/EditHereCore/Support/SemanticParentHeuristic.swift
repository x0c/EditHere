import Foundation

/// Prefers tappable controls over nearby labels when several views share a point.
public enum EditHereSemanticParentHeuristic {
    public static func score(className: String?, hasText: Bool, isControlLike: Bool) -> Int {
        var score = 0
        if isControlLike { score += 40 }
        if hasText { score += 10 }
        let name = className ?? ""
        if name.contains("Button") { score += 30 }
        if name.contains("Cell") || name.contains("Row") { score += 20 }
        if name.contains("Card") { score += 15 }
        if name.contains("Label") || name.contains("Image") { score -= 5 }
        if name.contains("Window") || name.contains("Hosting") { score -= 20 }
        return score
    }
}
