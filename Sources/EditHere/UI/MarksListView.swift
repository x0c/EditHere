import UIKit
import Combine
import EditHereCore

@MainActor
struct EditHereMarksRow: Identifiable, Equatable {
    enum Kind: Equatable {
        case committed(EditHereAnnotation)
        case pending(String)
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String

    static func rows(from session: EditHereSession) -> [EditHereMarksRow] {
        var items = session.draft.package.annotations.map { annotation in
            EditHereMarksRow(
                id: annotation.id.uuidString,
                kind: .committed(annotation),
                title: "\(annotation.number). \(annotation.effectiveRequestText)",
                subtitle: annotation.targetHint.visibleText
                    ?? annotation.targetHint.accessibilityLabel
                    ?? "Mark"
            )
        }
        if session.hasActiveTypedRequest {
            items.append(
                EditHereMarksRow(
                    id: "pending",
                    kind: .pending(session.composerText),
                    title: "Draft. \(session.composerText)",
                    subtitle: "Not submitted yet"
                )
            )
        }
        return items
    }
}

@MainActor
final class EditHereMarksViewController: UITableViewController {
    var onEditPending: (() -> Void)?
    private let session: EditHereSession
    private var rows: [EditHereMarksRow]
    private var cancellables = Set<AnyCancellable>()
    private var previewItem: UIBarButtonItem?

    init(session: EditHereSession) {
        self.session = session
        self.rows = EditHereMarksRow.rows(from: session)
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Mark")
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                systemItem: .close,
                primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
            )
        }
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Submit",
            primaryAction: UIAction { [weak self] _ in
                Task { @MainActor in
                    await self?.session.submit()
                    if self?.session.annotationCount == 0 {
                        self?.dismiss(animated: true)
                    }
                }
            }
        )
        let preview = UIBarButtonItem(
            title: "Preview",
            image: UIImage(systemName: "text.viewfinder"),
            primaryAction: UIAction { [weak self] _ in
                self?.openPromptPreview()
            }
        )
        preview.accessibilityLabel = "Preview prompt"
        previewItem = preview
        toolbarItems = [.flexibleSpace(), preview]
        session.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshMarksChrome() }
            .store(in: &cancellables)
        refreshMarksChrome()
        updateEmptyState()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
        // Refresh edits on return from the editor, never during swipe deletion.
        rows = EditHereMarksRow.rows(from: session)
        tableView.reloadData()
        updateEmptyState()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Mark", for: indexPath)
        let row = rows[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = row.title
        content.secondaryText = row.subtitle
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        cell.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Delete") { [weak self] _ in
            guard let self, let index = self.rows.firstIndex(where: { $0.id == row.id }) else { return false }
            self.deleteRow(at: IndexPath(row: index, section: 0))
            return true
        }]
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch rows[indexPath.row].kind {
        case .committed(let annotation):
            navigationController?.pushViewController(
                EditHereMarkEditViewController(session: session, annotation: annotation), animated: true
            )
        case .pending:
            navigationController?.popViewController(animated: true)
            onEditPending?()
        }
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        let id = rows[indexPath.row].id
        let delete = UIContextualAction(style: .destructive, title: nil) { [weak self] _, _, completion in
            guard let self, let index = self.rows.firstIndex(where: { $0.id == id }) else {
                completion(false)
                return
            }
            self.deleteRow(at: IndexPath(row: index, section: 0), completion: completion)
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    func deleteRow(at indexPath: IndexPath, completion: @escaping (Bool) -> Void = { _ in }) {
        guard rows.indices.contains(indexPath.row) else {
            completion(false)
            return
        }
        let row = rows.remove(at: indexPath.row)
        tableView.performBatchUpdates {
            tableView.deleteRows(at: [indexPath], with: .fade)
        } completion: { [self] _ in
            completion(true)
            switch row.kind {
            case .committed(let annotation): session.removeAnnotation(id: annotation.id)
            case .pending: session.composerText = ""
            }
            // Keep surviving cell content and numbering current without reloading the list.
            let current = Dictionary(uniqueKeysWithValues: EditHereMarksRow.rows(from: session).map { ($0.id, $0) })
            rows = rows.map { current[$0.id] ?? $0 }
            for indexPath in tableView.indexPathsForVisibleRows ?? [] {
                guard rows.indices.contains(indexPath.row), let cell = tableView.cellForRow(at: indexPath) else { continue }
                var content = cell.defaultContentConfiguration()
                content.text = rows[indexPath.row].title
                content.secondaryText = rows[indexPath.row].subtitle
                cell.contentConfiguration = content
            }
            updateEmptyState()
            refreshMarksChrome()
        }
    }

    private func updateEmptyState() {
        if rows.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.text = "No marks yet"
            empty.image = UIImage(systemName: "square.dashed")
            empty.secondaryText = "Select something on screen to add a request."
            contentUnavailableConfiguration = empty
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func refreshMarksChrome() {
        let count = rows.count
        title = "Marks"
        navigationItem.rightBarButtonItem?.title = session.isSubmitting ? "Sending…" : "Submit \(count)"
        navigationItem.rightBarButtonItem?.isEnabled = count > 0 && !session.isSubmitting
        previewItem?.isEnabled = count > 0 && !session.isSubmitting
    }

    func openPromptPreview() {
        _ = session.flushActiveDraftIfNeeded()
        rows = EditHereMarksRow.rows(from: session)
        guard session.annotationCount > 0 else { return }
        navigationController?.pushViewController(
            EditHerePromptPreviewViewController(session: session),
            animated: true
        )
    }
}
