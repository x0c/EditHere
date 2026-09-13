import Foundation

public struct EditHereOutboxRecord: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var packageID: UUID
    public var contentDigest: String
    public var destinationID: String
    public var remoteTaskID: String?
    public var state: EditHereTaskUserState
    public var packageRootRelativePath: String
    public var lastError: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        packageID: UUID,
        contentDigest: String,
        destinationID: String,
        remoteTaskID: String? = nil,
        state: EditHereTaskUserState,
        packageRootRelativePath: String,
        lastError: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.packageID = packageID
        self.contentDigest = contentDigest
        self.destinationID = destinationID
        self.remoteTaskID = remoteTaskID
        self.state = state
        self.packageRootRelativePath = packageRootRelativePath
        self.lastError = lastError
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum EditHereSubmitError: Error, LocalizedError, Sendable {
    case conflictingPayload(existingDigest: String)
    case incompleteAssets

    public var errorDescription: String? {
        switch self {
        case .conflictingPayload:
            return "A different payload was already submitted under this identity."
        case .incompleteAssets:
            return "Evidence assets are incomplete."
        }
    }
}

public actor EditHereOutbox {
    private let directoryURL: URL
    private let indexURL: URL
    private var records: [EditHereOutboxRecord] = []

    public init(directoryURL: URL) throws {
        self.directoryURL = directoryURL
        self.indexURL = directoryURL.appendingPathComponent("outbox.json")
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: indexURL.path) {
            let data = try Data(contentsOf: indexURL)
            records = try EditHereJSONCoding.decoder.decode([EditHereOutboxRecord].self, from: data)
        }
    }

    public static func applicationSupportOutbox(
        subdirectory: String = "EditHere/Outbox"
    ) throws -> EditHereOutbox {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base.appendingPathComponent(subdirectory, isDirectory: true)
        return try EditHereOutbox(directoryURL: directory)
    }

    public func allRecords() -> [EditHereOutboxRecord] {
        records.sorted { $0.createdAt > $1.createdAt }
    }

    public func record(packageID: UUID) -> EditHereOutboxRecord? {
        records.first { $0.packageID == packageID }
    }

    public func upsert(_ record: EditHereOutboxRecord) throws {
        if let index = records.firstIndex(where: { $0.packageID == record.packageID }) {
            records[index] = record
        } else if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        try persist()
    }

    public func packageDirectory(for record: EditHereOutboxRecord) -> URL {
        directoryURL.appendingPathComponent(record.packageRootRelativePath, isDirectory: true)
    }

    public func makePackageDirectory(packageID: UUID) throws -> URL {
        let relative = "packages/\(packageID.uuidString)"
        let url = directoryURL.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func persist() throws {
        let data = try EditHereJSONCoding.encoder.encode(records)
        try data.write(to: indexURL, options: .atomic)
    }
}

/// Submits a draft through a destination with single-flight per package identity.
public actor EditHereSubmitter {
    private let outbox: EditHereOutbox
    private let writer: EditHereEvidenceWriter
    private var inFlight: [UUID: Task<EditHereSubmissionReceipt, Error>] = [:]

    public init(outbox: EditHereOutbox, writer: EditHereEvidenceWriter = EditHereEvidenceWriter()) {
        self.outbox = outbox
        self.writer = writer
    }

    public func submit(
        draft: EditHereDraftBatch,
        destination: any EditHereDestination
    ) async throws -> EditHereSubmissionReceipt {
        try destination.validateImageCapability()

        var package = draft.package
        package.overallInstruction = draft.overallInstruction
        package.annotations = package.renumberedAnnotations()
        let usedCaptureIDs = Set(package.annotations.map(\.captureID))
        package.captures = package.captures.filter { usedCaptureIDs.contains($0.id) }
        package.destinationID = destination.destinationID
        let referencedPaths = Set(
            package.captures.flatMap { [$0.originalImage.relativePath, $0.annotatedImage.relativePath] }
        )
        let assets = draft.assets.filter { referencedPaths.contains($0.key) }
        let digest = try EditHereHashing.contentDigest(for: package, assets: assets)

          if let existing = await outbox.record(packageID: package.id) {
              if existing.contentDigest != digest {
                  throw EditHereSubmitError.conflictingPayload(existingDigest: existing.contentDigest)
              }
              if let remote = existing.remoteTaskID,
                 existing.state == .submitted
                    || existing.state == .working
                    || existing.state == .readyForReview
                    || existing.state == .waitingForComputer
                    || existing.state == .needsInformation {
                  return EditHereSubmissionReceipt(
                      destinationID: existing.destinationID,
                      remoteTaskID: remote,
                      submissionID: existing.packageID,
                      state: existing.state,
                      message: "Reused existing submission."
                  )
              }
              // Lost acknowledgement: ask the destination by stable submission id before a second launch.
              if existing.state == .uploading || existing.state == .failed || existing.remoteTaskID == nil {
                  if let recovered = try? await destination.lookup(submissionID: package.id),
                     recovered.state != .failed,
                     recovered.state != .cancelled,
                     recovered.destinationID == existing.destinationID,
                     recovered.destinationID == destination.destinationID {
                      var updated = existing
                      updated.remoteTaskID = recovered.remoteTaskID
                      updated.state = recovered.state
                      updated.lastError = nil
                      updated.updatedAt = Date()
                      try await outbox.upsert(updated)
                      return EditHereSubmissionReceipt(
                          destinationID: recovered.destinationID,
                          remoteTaskID: recovered.remoteTaskID,
                          submissionID: package.id,
                          state: recovered.state,
                          message: recovered.summary ?? "Recovered existing submission."
                      )
                  }
              }
          }

        if let existingTask = inFlight[package.id] {
            return try await existingTask.value
        }

        let task = Task<EditHereSubmissionReceipt, Error> {
            try await self.performSubmit(
                package: package,
                assets: assets,
                digest: digest,
                destination: destination
            )
        }
        inFlight[package.id] = task
        defer { inFlight[package.id] = nil }
        return try await task.value
    }

    private func performSubmit(
        package: EditHereEvidencePackage,
        assets: [String: Data],
        digest: String,
        destination: any EditHereDestination
    ) async throws -> EditHereSubmissionReceipt {
        let packageRoot = try await outbox.makePackageDirectory(packageID: package.id)
        // Stage to a sibling then replace atomically via writer (writer replaces root).
        _ = try writer.write(package: package, to: packageRoot, assets: assets)

        var record = EditHereOutboxRecord(
            id: package.id,
            packageID: package.id,
            contentDigest: digest,
            destinationID: destination.destinationID,
            state: .uploading,
            packageRootRelativePath: "packages/\(package.id.uuidString)"
        )
        try await outbox.upsert(record)

        do {
            let receipt = try await destination.submit(package: package, assetRootURL: packageRoot)
            record.remoteTaskID = receipt.remoteTaskID
            record.state = receipt.state
            record.updatedAt = Date()
            record.lastError = nil
            try await outbox.upsert(record)
            return receipt
        } catch {
            record.state = .failed
            record.lastError = error.localizedDescription
            record.updatedAt = Date()
            try await outbox.upsert(record)
            throw error
        }
    }
}
