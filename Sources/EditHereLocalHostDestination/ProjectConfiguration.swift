import Foundation
import EditHereCore

/// Shareable project binding loaded from `edithere.project.json` (not phone settings).
public struct EditHereProjectConfiguration: Codable, Hashable, Sendable {
    public var schemaVersion: String
    public var projectID: String
    public var displayName: String
    public var receiver: Receiver
    public var build: Build?
    public var delivery: Delivery?
    public var acceptance: Acceptance?

    public struct Receiver: Codable, Hashable, Sendable {
        public var baseURL: URL
        public var submitPath: String
        public var tokenHeader: String
        public var tokenEnvHint: String

        public init(
            baseURL: URL,
            submitPath: String = "/v1/submissions",
            tokenHeader: String = "X-EditHere-Token",
            tokenEnvHint: String = "EDITHHERE_HOST_TOKEN"
        ) {
            self.baseURL = baseURL
            self.submitPath = submitPath
            self.tokenHeader = tokenHeader
            self.tokenEnvHint = tokenEnvHint
        }
    }

    public struct Build: Codable, Hashable, Sendable {
        public var scheme: String

        public init(scheme: String) {
            self.scheme = scheme
        }
    }

    public struct Delivery: Codable, Hashable, Sendable {
        public var method: String

        public init(method: String) {
            self.method = method
        }
    }

    public struct Acceptance: Codable, Hashable, Sendable {
        public var screens: [String]

        public init(screens: [String]) {
            self.screens = screens
        }
    }

    public init(
        schemaVersion: String = "1",
        projectID: String,
        displayName: String,
        receiver: Receiver,
        build: Build? = nil,
        delivery: Delivery? = nil,
        acceptance: Acceptance? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.displayName = displayName
        self.receiver = receiver
        self.build = build
        self.delivery = delivery
        self.acceptance = acceptance
    }

    public static func load(from url: URL) throws -> EditHereProjectConfiguration {
        let data = try Data(contentsOf: url)
        return try EditHereJSONCoding.decoder.decode(EditHereProjectConfiguration.self, from: data)
    }
}
