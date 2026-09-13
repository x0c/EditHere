import Foundation

public enum EditHereTaskUserState: String, Codable, Hashable, Sendable {
    case savedLocally
    case uploading
    case submitted
    case waitingForComputer
    case working
    case needsInformation
    case readyForReview
    case failed
    case cancelled
}

public struct EditHereDestinationCapabilities: Codable, Hashable, Sendable {
    public var supportsImages: Bool
    public var supportsProgress: Bool
    public var supportsCancellation: Bool
    public var supportsClarification: Bool
    public var supportsDirectExecution: Bool

    public init(
        supportsImages: Bool,
        supportsProgress: Bool = false,
        supportsCancellation: Bool = false,
        supportsClarification: Bool = false,
        supportsDirectExecution: Bool = false
    ) {
        self.supportsImages = supportsImages
        self.supportsProgress = supportsProgress
        self.supportsCancellation = supportsCancellation
        self.supportsClarification = supportsClarification
        self.supportsDirectExecution = supportsDirectExecution
    }
}

public struct EditHereSubmissionReceipt: Codable, Hashable, Sendable {
    public var destinationID: String
    public var remoteTaskID: String
    public var submissionID: UUID
    public var state: EditHereTaskUserState
    public var message: String?
    public var createdAt: Date

    public init(
        destinationID: String,
        remoteTaskID: String,
        submissionID: UUID,
        state: EditHereTaskUserState,
        message: String? = nil,
        createdAt: Date = Date()
    ) {
        self.destinationID = destinationID
        self.remoteTaskID = remoteTaskID
        self.submissionID = submissionID
        self.state = state
        self.message = message
        self.createdAt = createdAt
    }
}

public enum EditHereMarkOutcomeStatus: String, Codable, Hashable, Sendable {
    case changed
    case unresolved
    case skipped
    case failed
}

public struct EditHereMarkOutcome: Codable, Hashable, Sendable {
    public var number: Int
    public var status: EditHereMarkOutcomeStatus
    public var summary: String
    public var paths: [String]

    public init(
        number: Int,
        status: EditHereMarkOutcomeStatus,
        summary: String,
        paths: [String] = []
    ) {
        self.number = number
        self.status = status
        self.summary = summary
        self.paths = paths
    }
}

public struct EditHereVerificationFacts: Codable, Hashable, Sendable {
    public var codeChanged: Bool
    public var checksPassed: Bool?
    public var artifactReady: Bool
    public var installed: Bool
    public var visuallyVerified: Bool

    public init(
        codeChanged: Bool = false,
        checksPassed: Bool? = nil,
        artifactReady: Bool = false,
        installed: Bool = false,
        visuallyVerified: Bool = false
    ) {
        self.codeChanged = codeChanged
        self.checksPassed = checksPassed
        self.artifactReady = artifactReady
        self.installed = installed
        self.visuallyVerified = visuallyVerified
    }
}

public struct EditHereTaskStatus: Codable, Hashable, Sendable {
    public var destinationID: String
    public var remoteTaskID: String
    public var state: EditHereTaskUserState
    public var summary: String?
    public var updatedAt: Date
    public var submissionID: UUID?
    public var markOutcomes: [EditHereMarkOutcome]
    public var verification: EditHereVerificationFacts?

    public init(
        destinationID: String,
        remoteTaskID: String,
        state: EditHereTaskUserState,
        summary: String? = nil,
        updatedAt: Date = Date(),
        submissionID: UUID? = nil,
        markOutcomes: [EditHereMarkOutcome] = [],
        verification: EditHereVerificationFacts? = nil
    ) {
        self.destinationID = destinationID
        self.remoteTaskID = remoteTaskID
        self.state = state
        self.summary = summary
        self.updatedAt = updatedAt
        self.submissionID = submissionID
        self.markOutcomes = markOutcomes
        self.verification = verification
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        destinationID = try container.decode(String.self, forKey: .destinationID)
        remoteTaskID = try container.decode(String.self, forKey: .remoteTaskID)
        state = try container.decode(EditHereTaskUserState.self, forKey: .state)
        summary = try container.decodeIfPresent(String.self, forKey: .summary)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        submissionID = try container.decodeIfPresent(UUID.self, forKey: .submissionID)
        markOutcomes = try container.decodeIfPresent([EditHereMarkOutcome].self, forKey: .markOutcomes) ?? []
        verification = try container.decodeIfPresent(EditHereVerificationFacts.self, forKey: .verification)
    }
}

public enum EditHereDestinationError: Error, LocalizedError, Sendable {
    case missingImageSupport
    case incompleteAttachments
    case conflict(String)
    case notFound
    case cancelled
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .missingImageSupport:
            return "This destination does not support image evidence required by EditHere."
        case .incompleteAttachments:
            return "Attachments are incomplete; the task was not accepted for execution."
        case .conflict(let message):
            return message
        case .notFound:
            return "Task was not found at this destination."
        case .cancelled:
            return "Task was cancelled."
        case .underlying(let message):
            return message
        }
    }
}

/// Destination contract. Corral (or ACP, or a custom receiver) is an optional adapter.
public protocol EditHereDestination: Sendable {
    var destinationID: String { get }
    var displayName: String { get }
    var capabilities: EditHereDestinationCapabilities { get }

    func submit(
        package: EditHereEvidencePackage,
        assetRootURL: URL
    ) async throws -> EditHereSubmissionReceipt

    func lookup(remoteTaskID: String) async throws -> EditHereTaskStatus

    func lookup(submissionID: UUID) async throws -> EditHereTaskStatus

    func cancel(remoteTaskID: String) async throws
}

public extension EditHereDestination {
    func lookup(remoteTaskID: String) async throws -> EditHereTaskStatus {
        throw EditHereDestinationError.underlying("Progress lookup is not supported by \(displayName).")
    }

    func lookup(submissionID: UUID) async throws -> EditHereTaskStatus {
        throw EditHereDestinationError.underlying("Submission lookup is not supported by \(displayName).")
    }

    func cancel(remoteTaskID: String) async throws {
        throw EditHereDestinationError.underlying("Cancellation is not supported by \(displayName).")
    }

    func validateImageCapability() throws {
        guard capabilities.supportsImages else {
            throw EditHereDestinationError.missingImageSupport
        }
    }
}
