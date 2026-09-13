import Foundation

/// Pure helpers for numbering and prompt assembly. Image drawing lives in the UI module.
///
/// The evidence package is the source of truth. This builder is a versioned derived view.
/// Bump `currentTemplateVersion` when section layout or rules change; do not bump evidence schema
/// for wording-only iteration. Never print that number in the Agent-facing text.
public enum EditHerePromptBuilder {
    public static let currentTemplateVersion = 6

    public static func batchPrompt(for package: EditHereEvidencePackage) -> String {
        let annotations = package.renumberedAnnotations()
        let usedCaptures = captures(usedBy: annotations, in: package)
        var pageIndexByCapture: [UUID: Int] = [:]
        for (index, capture) in usedCaptures.enumerated() {
            pageIndexByCapture[capture.id] = index + 1
        }

        var lines: [String] = []
        let app = package.app.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !app.isEmpty {
            lines.append("App: \(app)")
        }
        if let revision = package.app.sourceRevision?.trimmingCharacters(in: .whitespacesAndNewlines),
           !revision.isEmpty
        {
            lines.append("Source: \(revision)")
        }
        lines.append(
            "Marks: blue rounded outline, white number on a blue pill at the top-left of the box. A point mark is a blue ring and crosshair with the same numbered pill."
        )
        if usedCaptures.isEmpty {
            lines.append("No screenshots with marks were included.")
        } else {
            for capture in usedCaptures {
                let page = pageIndexByCapture[capture.id] ?? 0
                let marks = annotations.filter { $0.captureID == capture.id }.map(\.number)
                let markList = marks.map(String.init).joined(separator: ", ")
                lines.append("Page \(page) · \(capture.screenID) — marks \(markList)")
            }
        }
        let overall = package.overallInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if !overall.isEmpty {
            lines.append("")
            lines.append(overall)
        }
        lines.append("")
        if annotations.isEmpty {
            lines.append("No requests.")
        } else {
            for annotation in annotations {
                let capture = package.captures.first(where: { $0.id == annotation.captureID })
                let page = pageIndexByCapture[annotation.captureID]
                let screen = capture?.screenID ?? "unknown-screen"
                let pageLabel = page.map { "Page \($0) · \(screen)" } ?? screen
                lines.append("\(annotation.number). \(pageLabel)")
                lines.append(requestLine(for: annotation))
                lines.append(contentsOf: hintLines(for: annotation))
                if annotation.selectionKind == .point {
                    lines.append(
                        "This mark is a numbered point (outline not recognized). Confirm the control on the screenshot."
                    )
                }
                if !isComplete(annotation) {
                    lines.append("The change is not specific. Do not guess.")
                }
                lines.append("")
            }
            if lines.last == "" {
                lines.removeLast()
            }
        }
        lines.append("")
        lines.append(
            "If several rows look the same, edit only the numbered one. Change only what is requested."
        )
        return lines.joined(separator: "\n")
    }

    public static func captures(
        usedBy annotations: [EditHereAnnotation],
        in package: EditHereEvidencePackage
    ) -> [EditHereCapture] {
        let used = Set(annotations.map(\.captureID))
        return package.captures.filter { used.contains($0.id) }
    }

    static func isComplete(_ annotation: EditHereAnnotation) -> Bool {
        let text = annotation.requestText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch annotation.action {
        case .removeElement:
            return true
        case .customRequest:
            return !text.isEmpty
        case .changeText:
            return !text.isEmpty
                && text != EditHereAnnotationAction.changeText.defaultPrompt
                && text != "Change the text to:"
        case .adjustAppearance:
            return !text.isEmpty && text != EditHereAnnotationAction.adjustAppearance.defaultPrompt
        }
    }

    private static func requestLine(for annotation: EditHereAnnotation) -> String {
        let text = annotation.effectiveRequestText
        let canned = text == annotation.action.defaultPrompt
        if canned {
            switch annotation.action {
            case .removeElement:
                return "Remove the marked element from the product."
            case .changeText:
                return "Change the text of the marked element."
            case .adjustAppearance:
                return "Adjust the appearance of the marked element."
            case .customRequest:
                return text
            }
        }
        return text
    }

    private static func hintLines(for annotation: EditHereAnnotation) -> [String] {
        var lines: [String] = []
        let hint = annotation.targetHint
        let onScreen = nonEmpty(hint.visibleText)
        if let onScreen {
            lines.append("On screen: \(onScreen)")
        }
        if let label = nonEmpty(hint.accessibilityLabel), label != hint.visibleText {
            lines.append("Accessibility name: \(label)")
        }
        if let identifier = usefulIdentifier(hint.accessibilityIdentifier) {
            lines.append("Accessibility id: \(identifier)")
        }
        if onScreen == nil, let kind = publicControlKind(hint.className) {
            lines.append("Control: \(kind)")
        }
        if let instance = hint.instanceIndex {
            lines.append("Similar on-screen row #\(instance)")
        }
        return lines
    }

    /// Human control kind for the Agent. Never emit private or raw UIKit class names.
    static func publicControlKind(_ className: String?) -> String? {
        guard let raw = nonEmpty(className) else { return nil }
        if raw.hasPrefix("_") { return nil }
        let name = raw.split(whereSeparator: { $0 == "." || $0 == " " }).last.map(String.init) ?? raw
        if name.hasPrefix("_") { return nil }
        if name.contains("Hosting") { return nil }
        if name.contains("Button") { return "button" }
        if name.contains("Switch") { return "switch" }
        if name.contains("Slider") { return "slider" }
        if name.contains("TextField") || name.contains("TextView") { return "text field" }
        if name.contains("TabBar") { return "tab item" }
        if name.contains("Cell") { return "list row" }
        if name.contains("ImageView") || name.hasSuffix("Image") { return "image" }
        if name == "UILabel" || name.hasSuffix("Label") { return "label" }
        return nil
    }

    private static func usefulIdentifier(_ value: String?) -> String? {
        guard let value = nonEmpty(value) else { return nil }
        if value.hasPrefix("_") { return nil }
        if value.count > 64 { return nil }
        if UUID(uuidString: value) != nil { return nil }
        return value
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
