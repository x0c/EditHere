import UIKit
import EditHereCore

public struct EditHereViewCandidate: Hashable, Sendable {
    public var viewObjectIdentifier: ObjectIdentifier
    public var parentObjectIdentifier: ObjectIdentifier?
    public var boundsInWindow: CGRect
    public var className: String
    public var accessibilityLabel: String?
    public var accessibilityIdentifier: String?
    public var visibleText: String?
    public var isControlLike: Bool
    public var depth: Int
    public var paintOrder: Int
    public var isOpaque: Bool
}

@MainActor
public final class EditHereViewSelector {
    public init() {}

    /// Snapshot all visible candidates in paint order for a frozen frame.
    public func snapshotCandidates(
        in windows: [UIWindow],
        excluding excludedWindows: Set<ObjectIdentifier>
    ) -> [EditHereViewCandidate] {
        var collected: [EditHereViewCandidate] = []
        var paint = 0
        for window in windows where !excludedWindows.contains(ObjectIdentifier(window)) {
            collectAll(
                view: window,
                window: window,
                depth: 0,
                paintOrder: &paint,
                into: &collected
            )
        }
        return collected
    }

    /// Live convenience used by tests; production selection should use a frozen snapshot.
    public func candidates(
        at windowPoint: CGPoint,
        in windows: [UIWindow],
        excluding excludedWindows: Set<ObjectIdentifier>
    ) -> [EditHereViewCandidate] {
        candidates(
            at: windowPoint,
            from: snapshotCandidates(in: windows, excluding: excludedWindows)
        )
    }

    public func candidates(
        at windowPoint: CGPoint,
        from snapshot: [EditHereViewCandidate]
    ) -> [EditHereViewCandidate] {
        let hits = snapshot
            .filter { $0.boundsInWindow.contains(windowPoint) }
            .sorted(by: { $0.paintOrder < $1.paintOrder })
        // Later opaque paint hides earlier hits at the same point.
        return hits.filter { candidate in
            !hits.contains { cover in
                cover.paintOrder > candidate.paintOrder
                    && cover.isOpaque
                    && cover.boundsInWindow.contains(windowPoint)
                    && cover.viewObjectIdentifier != candidate.viewObjectIdentifier
            }
        }
    }

    public func preferredCandidate(
        from candidates: [EditHereViewCandidate],
        previous: EditHereViewCandidate?,
        samePointRetap: Bool
    ) -> EditHereViewCandidate? {
        guard !candidates.isEmpty else { return nil }
        let ancestryOrdered = ancestryChain(from: candidates)

        if samePointRetap, let previous,
           let index = ancestryOrdered.firstIndex(where: { $0.viewObjectIdentifier == previous.viewObjectIdentifier }) {
            if index + 1 < ancestryOrdered.count {
                return ancestryOrdered[index + 1]
            }
            return ancestryOrdered.first
        }

        let scored = candidates.map { candidate -> (EditHereViewCandidate, Int) in
            let score = EditHereSemanticParentHeuristic.score(
                className: candidate.className,
                hasText: !(candidate.visibleText?.isEmpty ?? true),
                isControlLike: candidate.isControlLike
            ) + candidate.depth
            return (candidate, score)
        }
        return scored.max(by: { $0.1 < $1.1 })?.0 ?? candidates.last
    }

    /// Deepest → root among candidates that form a parent chain.
    private func ancestryChain(from candidates: [EditHereViewCandidate]) -> [EditHereViewCandidate] {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.viewObjectIdentifier, $0) })
        guard let deepest = candidates.max(by: { $0.depth < $1.depth }) else { return candidates }
        var chain: [EditHereViewCandidate] = [deepest]
        var current = deepest
        while let parentID = current.parentObjectIdentifier, let parent = byID[parentID] {
            chain.append(parent)
            current = parent
        }
        return chain
    }

    private func collectAll(
        view: UIView,
        window: UIWindow,
        depth: Int,
        paintOrder: inout Int,
        into collected: inout [EditHereViewCandidate]
    ) {
        for subview in view.subviews {
            if shouldSkip(subview) {
                collectAll(
                    view: subview,
                    window: window,
                    depth: depth,
                    paintOrder: &paintOrder,
                    into: &collected
                )
                continue
            }
            let isHidden = subview.isHidden || subview.alpha < 0.01
            if isHidden { continue }

            paintOrder += 1
            let boundsInWindow = subview.convert(subview.bounds, to: window)
            let id = ObjectIdentifier(subview)
            collected.append(
                EditHereViewCandidate(
                    viewObjectIdentifier: id,
                    parentObjectIdentifier: ObjectIdentifier(view),
                    boundsInWindow: boundsInWindow,
                    className: String(describing: type(of: subview)),
                    accessibilityLabel: subview.accessibilityLabel,
                    accessibilityIdentifier: subview.accessibilityIdentifier,
                    visibleText: extractText(from: subview),
                    isControlLike: isControlLike(subview),
                    depth: depth + 1,
                    paintOrder: paintOrder,
                    isOpaque: isVisuallyOpaque(subview)
                )
            )
            collectAll(
                view: subview,
                window: window,
                depth: depth + 1,
                paintOrder: &paintOrder,
                into: &collected
            )
        }
    }

    private func isVisuallyOpaque(_ view: UIView) -> Bool {
        guard view.isOpaque, view.alpha >= 0.99 else { return false }
        if let color = view.backgroundColor {
            return color.cgColor.alpha >= 0.99
        }
        // No background fill: do not treat as an occluder even if UIView.isOpaque is true.
        return false
    }

    private func shouldSkip(_ view: UIView) -> Bool {
        if view is EditHereChromeViewMarker { return true }
        let name = String(describing: type(of: view))
        let skipped = [
            "FloatingBarHostingView",
            "FloatingBarContainerView",
            "_UITabBarContainerView",
            "_UITouchPassthroughView",
            "_UIContextMenuContainerView"
        ]
        return skipped.contains { name.contains($0) }
    }

    private func isControlLike(_ view: UIView) -> Bool {
        if view is UIControl { return true }
        if view is UITableViewCell || view is UICollectionViewCell { return true }
        let name = String(describing: type(of: view))
        return name.contains("Button") || name.contains("Cell") || name.contains("Card")
    }

    private func extractText(from view: UIView) -> String? {
        var seen = Set<String>()
        var parts: [String] = []
        func consider(_ raw: String?) {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  trimmed.count <= 80
            else { return }
            if seen.insert(trimmed).inserted {
                parts.append(trimmed)
            }
        }
        func directText(_ node: UIView) -> String? {
            if let label = node as? UILabel, let text = label.text, !text.isEmpty { return text }
            if let button = node as? UIButton {
                let title = button.title(for: .normal) ?? button.configuration?.title
                if let title, !title.isEmpty { return title }
            }
            if let field = node as? UITextField, let text = field.text, !text.isEmpty { return text }
            if let textView = node as? UITextView, let text = textView.text, !text.isEmpty { return text }
            return nil
        }
        func walk(_ node: UIView, depth: Int) {
            guard parts.count < 3, depth <= 8 else { return }
            consider(directText(node))
            for subview in node.subviews {
                walk(subview, depth: depth + 1)
            }
        }
        walk(view, depth: 0)
        if parts.isEmpty {
            let fallback = view.accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return fallback.isEmpty ? nil : fallback
        }
        let joined = parts.joined(separator: " · ")
        if joined.count > 160 {
            return String(joined.prefix(157)) + "..."
        }
        return joined
    }
}

@MainActor
public protocol EditHereChromeViewMarker: AnyObject {}
