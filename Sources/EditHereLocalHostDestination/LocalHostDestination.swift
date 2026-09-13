import Foundation
import EditHereCore

/// HTTP destination that posts evidence packages to a development-host receiver.
public struct EditHereLocalHostDestination: EditHereDestination, Sendable {
    public let destinationID: String
    public let displayName: String
    public let capabilities: EditHereDestinationCapabilities

    public let baseURL: URL
    /// Discovery-first default: the phone browses `_edithere._tcp` for a TXT
    /// record whose `project` matches this destination, and uses that address
    /// before falling back to `baseURL`. Discovery only supplies the address;
    /// auth and project binding are still enforced in the host response.
    public let discoveryEnabled: Bool
    public let projectID: String
    public let submitPath: String
    public let token: String
    public let tokenHeader: String

    private let session: URLSession

    public init(
        baseURL: URL,
        projectID: String,
        submitPath: String = "/v1/submissions",
        token: String,
        tokenHeader: String = "X-EditHere-Token",
        session: URLSession = .shared,
        destinationID: String = "local-host",
        displayName: String = "Local Host",
        discoveryEnabled: Bool = true
    ) {
        self.baseURL = baseURL
        self.discoveryEnabled = discoveryEnabled
        self.projectID = projectID
        self.submitPath = submitPath
        self.token = token
        self.tokenHeader = tokenHeader
        self.session = session
        self.destinationID = destinationID
        self.displayName = displayName
        self.capabilities = EditHereDestinationCapabilities(
            supportsImages: true,
            supportsProgress: false,
            supportsCancellation: false,
            supportsClarification: false,
            supportsDirectExecution: true
        )
    }

    public init(projectConfigURL: URL, token: String, session: URLSession = .shared, discoveryEnabled: Bool = true) throws {
        let config = try EditHereProjectConfiguration.load(from: projectConfigURL)
        self.init(
            baseURL: config.receiver.baseURL,
            projectID: config.projectID,
            submitPath: config.receiver.submitPath,
            token: token,
            tokenHeader: config.receiver.tokenHeader,
            session: session,
            destinationID: "local-host:\(config.projectID)",
            discoveryEnabled: discoveryEnabled
        )
    }

    public func submit(
        package: EditHereEvidencePackage,
        assetRootURL: URL
    ) async throws -> EditHereSubmissionReceipt {
        try validateImageCapability()

        let originalPaths = Set(package.captures.map(\.originalImage.relativePath))
        var digestAssets: [String: Data] = [:]
        var uploadAssets: [String: Data] = [:]

        for capture in package.captures {
            // Verify originals locally for redraw integrity; never upload clean captures.
            let originalURL = assetRootURL.appendingPathComponent(capture.originalImage.relativePath)
            guard FileManager.default.fileExists(atPath: originalURL.path) else {
                throw EditHereDestinationError.incompleteAttachments
            }
            let originalData = try Data(contentsOf: originalURL)
            guard EditHereHashing.sha256Hex(of: originalData) == capture.originalImage.sha256 else {
                throw EditHereDestinationError.incompleteAttachments
            }

            let annotatedURL = assetRootURL.appendingPathComponent(capture.annotatedImage.relativePath)
            guard FileManager.default.fileExists(atPath: annotatedURL.path) else {
                throw EditHereDestinationError.incompleteAttachments
            }
            let annotatedData = try Data(contentsOf: annotatedURL)
            guard EditHereHashing.sha256Hex(of: annotatedData) == capture.annotatedImage.sha256 else {
                throw EditHereDestinationError.incompleteAttachments
            }
            digestAssets[capture.annotatedImage.relativePath] = annotatedData
            uploadAssets[capture.annotatedImage.relativePath] = annotatedData
        }

        // Upload canonical packet extras written by EvidenceWriter (prompt + page composites).
        let stagedFiles = try Self.collectFiles(under: assetRootURL)
        for (relativePath, data) in stagedFiles {
            if originalPaths.contains(relativePath) { continue }
            if relativePath == "agent-prompt.txt"
                || (relativePath.hasPrefix("page-") && relativePath.hasSuffix(".png"))
            {
                uploadAssets[relativePath] = data
            }
        }
        guard let promptData = uploadAssets["agent-prompt.txt"], !promptData.isEmpty else {
            throw EditHereDestinationError.incompleteAttachments
        }
        digestAssets["agent-prompt.txt"] = promptData

        let digest = try EditHereHashing.executionContentDigest(for: package, assets: digestAssets)

        let packageData = try EditHereJSONCoding.encoder.encode(package)
        let boundary = "edithere-\(UUID().uuidString)"
        var body = Data()
        Self.appendFormField(&body, name: "projectID", value: projectID, boundary: boundary)
        Self.appendFormField(&body, name: "submissionID", value: package.id.uuidString, boundary: boundary)
        Self.appendFormField(&body, name: "contentDigest", value: digest, boundary: boundary)
        Self.appendFormField(&body, name: "package", valueData: packageData, boundary: boundary, contentType: "application/json")

        for relativePath in uploadAssets.keys.sorted() {
            guard let data = uploadAssets[relativePath] else { continue }
            Self.appendFormFile(
                &body,
                name: relativePath,
                filename: (relativePath as NSString).lastPathComponent,
                data: data,
                boundary: boundary
            )
        }
        body.append(Data("--\(boundary)--\r\n".utf8))

        // Discovery first: advertised LAN address, then the bundled baseURL.
        // Discovery only changes the address; every attempt authenticates and
        // validates the project binding in the response, so a rogue service
        // that answers on the LAN fails closed instead of capturing Submit.
        var attempts: [URL] = []
        if discoveryEnabled, let discovered = await Self.discoveredSubmitURL(
            projectID: projectID, submitPath: submitPath
        ) {
            attempts.append(discovered)
        }
        let fallback = Self.submitURL(from: baseURL, submitPath: submitPath)
        if !attempts.contains(fallback) {
            attempts.append(fallback)
        }

        var lastError: Error?
        for url in attempts {
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.setValue(token, forHTTPHeaderField: tokenHeader)
                request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                request.httpBody = body

                let (responseData, response) = try await session.data(for: request)
                try Self.throwIfHTTPError(response: response, data: responseData)
                let payload = try Self.decodeEnvelope(responseData)
                let task = try Self.decodeTaskPayload(
                    payload.data,
                    fallbackDestinationID: destinationID,
                    expectedProjectID: projectID
                )
                return EditHereSubmissionReceipt(
                    destinationID: destinationID,
                    remoteTaskID: task.remoteTaskID,
                    submissionID: task.submissionID ?? package.id,
                    state: task.state,
                    message: task.summary ?? payload.message
                )
            } catch {
                lastError = error
            }
        }
        throw lastError ?? EditHereDestinationError.underlying("Host unreachable.")
    }

    public func lookup(remoteTaskID: String) async throws -> EditHereTaskStatus {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("v1")
                .appendingPathComponent("tasks")
                .appendingPathComponent(remoteTaskID),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "projectID", value: projectID)]
        guard let url = components?.url else {
            throw EditHereDestinationError.underlying("Invalid task lookup URL.")
        }
        return try await getStatus(url: url)
    }

    public func lookup(submissionID: UUID) async throws -> EditHereTaskStatus {
        var components = URLComponents(
            url: baseURL
                .appendingPathComponent("v1")
                .appendingPathComponent("submissions")
                .appendingPathComponent(submissionID.uuidString),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "projectID", value: projectID)]
        guard let url = components?.url else {
            throw EditHereDestinationError.underlying("Invalid submission lookup URL.")
        }
        return try await getStatus(url: url)
    }

    public func cancel(remoteTaskID: String) async throws {
        let url = baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("tasks")
            .appendingPathComponent(remoteTaskID)
            .appendingPathComponent("cancel")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(token, forHTTPHeaderField: tokenHeader)
        let (data, response) = try await session.data(for: request)
        try Self.throwIfHTTPError(response: response, data: data)
        _ = try Self.decodeEnvelope(data)
    }

    // MARK: - Internals

    /// Discovery contract with `edithere-host`: service type `_edithere._tcp`,
    /// TXT `project` equals this projectID. Mirror of the host TXT keys.
    static let discoveryServiceType = "_edithere._tcp."
    static let discoveryDomain = "local."
    /// One browse turn is short: discovery is a convenience, the bundled
    /// `baseURL` is the guarantee. Never pend Submit on the LAN.
    static let discoveryTimeoutSeconds = 1.5

    private static func submitURL(from base: URL, submitPath: String) -> URL {
        var baseString = base.absoluteString
        while baseString.hasSuffix("/") {
            baseString.removeLast()
        }
        let path = submitPath.hasPrefix("/") ? submitPath : "/\(submitPath)"
        guard let url = URL(string: baseString + path) else {
            return base
        }
        return url
    }

    /// Browse for the advertised project and return its Submit URL.
    /// Returns nil when nothing matching answers in time; the caller then
    /// uses the bundled `baseURL`. Never throws discovery errors upward.
    ///
    /// Bonjour via `NetServiceBrowser`: the host publishes one instance per
    /// project (`edithere-host serve` advertises automatically). Requires
    /// `NSBonjourServices: _edithere._tcp` in Info.plist plus the existing
    /// `NSLocalNetworkUsageDescription` — no multicast entitlement needed.
    ///
    /// No phone configuration UI: at most one matching host is ever used.
    /// Two different hosts advertising the same project is a setup error;
    /// the first usable answer wins and the user re-marks/resubmits if the
    /// wrong host answered — same recovery as a failed Submit.
    static func discoveredSubmitURL(projectID: String, submitPath: String) async -> URL? {
        await withCheckedContinuation { continuation in
            let search = DiscoverySearch(
                projectID: projectID, submitPath: submitPath, continuation: continuation
            )
            // NetServiceBrowser delivers on the current run loop; the main
            // thread always has one. Callbacks and timeout both land there.
            DispatchQueue.main.async {
                search.start()
            }
        }
    }

    /// One browse turn. Stops at the first service whose TXT `project`
    /// matches; unmatched LAN hosts stay silent and the bundled baseURL
    /// remains the fallback. First usable (or timeout) answer wins.
    private final class DiscoverySearch: NSObject, NetServiceBrowserDelegate, NetServiceDelegate, @unchecked Sendable {
        private let projectID: String
        private let submitPath: String
        private let continuation: CheckedContinuation<URL?, Never>
        private let browser = NetServiceBrowser()
        private var resolving: [NetService] = []
        private var resumed = false
        /// Delegate refs (`browser.delegate`, `service.delegate`) are weak:
        /// without this the search would deallocate mid-browse and Submit
        /// would hang past the timeout. Cleared in `finish`.
        private var selfRetain: DiscoverySearch?

        init(
            projectID: String,
            submitPath: String,
            continuation: CheckedContinuation<URL?, Never>
        ) {
            self.projectID = projectID
            self.submitPath = submitPath
            self.continuation = continuation
        }

        func start() {
            selfRetain = self
            browser.delegate = self
            browser.searchForServices(ofType: EditHereLocalHostDestination.discoveryServiceType, inDomain: EditHereLocalHostDestination.discoveryDomain)
            DispatchQueue.main.asyncAfter(deadline: .now() + EditHereLocalHostDestination.discoveryTimeoutSeconds) {
                self.finish(with: nil)
            }
        }

        func netServiceBrowser(
            _ browser: NetServiceBrowser,
            didFind service: NetService,
            moreComing: Bool
        ) {
            service.delegate = self
            resolving.append(service)
            service.resolve(withTimeout: 5.0)
        }

        func netServiceDidResolveAddress(_ service: NetService) {
            let txt = NetService.dictionary(fromTXTRecord: service.txtRecordData() ?? Data())
            guard let projectRaw = txt["project"],
                  let project = String(data: projectRaw, encoding: .utf8),
                  project == projectID,
                  let rawHost = service.hostName,
                  !rawHost.isEmpty,
                  // NetService returns a trailing-dot FQDN (`host.local.`);
                  // strip it so the Submit URL stays canonical.
                  let url = EditHereLocalHostDestination.submitURL(host: rawHost.trimmingCharacters(in: CharacterSet(charactersIn: ".")), port: service.port, submitPath: submitPath)
            else {
                resolving.removeAll { $0 === service }
                return
            }
            finish(with: url)
        }

        func netService(_ service: NetService, didNotResolve errorDict: [String: NSNumber]) {
            resolving.removeAll { $0 === service }
        }

        private func finish(with url: URL?) {
            guard !resumed else { return }
            resumed = true
            browser.stop()
            for service in resolving {
                service.stop()
            }
            resolving.removeAll()
            selfRetain = nil
            continuation.resume(returning: url)
        }
    }

    private static func submitURL(host: String, port: Int, submitPath: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = submitPath.hasPrefix("/") ? submitPath : "/\(submitPath)"
        return components.url
    }

    private var submitURL: URL {
        Self.submitURL(from: baseURL, submitPath: submitPath)
    }

    private func getStatus(url: URL) async throws -> EditHereTaskStatus {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: tokenHeader)
        let (data, response) = try await session.data(for: request)
        try Self.throwIfHTTPError(response: response, data: data)
        let payload = try Self.decodeEnvelope(data)
        return try Self.decodeTaskPayload(
            payload.data,
            fallbackDestinationID: destinationID,
            expectedProjectID: projectID
        )
    }

    private static func collectFiles(under root: URL) throws -> [String: Data] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }
        var files: [String: Data] = [:]
        let rootPath = root.standardizedFileURL.path
        for case let fileURL as URL in enumerator {
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { continue }
            let path = fileURL.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else { continue }
            var relative = String(path.dropFirst(rootPath.count))
            if relative.hasPrefix("/") {
                relative = String(relative.dropFirst())
            }
            guard !relative.isEmpty, relative != "manifest.json" else { continue }
            files[relative] = try Data(contentsOf: fileURL)
        }
        return files
    }

    private static func appendFormField(
        _ body: inout Data,
        name: String,
        value: String,
        boundary: String
    ) {
        appendFormField(&body, name: name, valueData: Data(value.utf8), boundary: boundary, contentType: nil)
    }

    private static func appendFormField(
        _ body: inout Data,
        name: String,
        valueData: Data,
        boundary: String,
        contentType: String?
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n".utf8))
        if let contentType {
            body.append(Data("Content-Type: \(contentType)\r\n".utf8))
        }
        body.append(Data("\r\n".utf8))
        body.append(valueData)
        body.append(Data("\r\n".utf8))
    }

    private static func appendFormFile(
        _ body: inout Data,
        name: String,
        filename: String,
        data: Data,
        boundary: String
    ) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n"
                    .utf8
            )
        )
        body.append(Data("Content-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    private struct Envelope: Decodable {
        var ok: Bool
        var data: PayloadData?
        var error: EnvelopeError?
        var message: String? {
            error?.message
        }
    }

    private struct EnvelopeError: Decodable {
        var code: String?
        var message: String?
        var hint: String?
    }

    /// Accepts either a flat task object or nested fields used by the host.
    private struct PayloadData: Decodable {
        var remoteTaskID: String?
        var submissionID: UUID?
        var destinationID: String?
        var projectID: String?
        var state: EditHereTaskUserState?
        var summary: String?
        var message: String?
        var updatedAt: Date?
        var markOutcomes: [EditHereMarkOutcome]?
        var verification: EditHereVerificationFacts?
    }

    private static func decodeEnvelope(_ data: Data) throws -> Envelope {
        do {
            return try EditHereJSONCoding.decoder.decode(Envelope.self, from: data)
        } catch {
            throw EditHereDestinationError.underlying("Invalid host response envelope.")
        }
    }

    private static func decodeTaskPayload(
        _ data: PayloadData?,
        fallbackDestinationID: String,
        expectedProjectID: String
    ) throws -> EditHereTaskStatus {
        guard let data,
              let remoteTaskID = data.remoteTaskID,
              let state = data.state
        else {
            throw EditHereDestinationError.underlying("Host response missing task fields.")
        }
        if let returnedProjectID = data.projectID, returnedProjectID != expectedProjectID {
            throw EditHereDestinationError.conflict(
                "Recovered task belongs to project \(returnedProjectID), not \(expectedProjectID)."
            )
        }
        let resolvedDestinationID = data.destinationID ?? fallbackDestinationID
        if resolvedDestinationID != fallbackDestinationID {
            throw EditHereDestinationError.conflict(
                "Recovered task destination \(resolvedDestinationID) does not match \(fallbackDestinationID)."
            )
        }
        return EditHereTaskStatus(
            destinationID: resolvedDestinationID,
            remoteTaskID: remoteTaskID,
            state: state,
            summary: data.summary ?? data.message,
            updatedAt: data.updatedAt ?? Date(),
            submissionID: data.submissionID,
            markOutcomes: data.markOutcomes ?? [],
            verification: data.verification
        )
    }

    private static func throwIfHTTPError(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw EditHereDestinationError.underlying("Unexpected non-HTTP response.")
        }
        if (200..<300).contains(http.statusCode) {
            if let envelope = try? EditHereJSONCoding.decoder.decode(Envelope.self, from: data),
               envelope.ok == false {
                let message = envelope.error?.message ?? "Host returned ok=false"
                if envelope.error?.code == "conflict" {
                    throw EditHereDestinationError.conflict(message)
                }
                throw EditHereDestinationError.underlying(message)
            }
            return
        }
        let envelope = try? EditHereJSONCoding.decoder.decode(Envelope.self, from: data)
        let message = envelope?.error?.message
            ?? String(data: data, encoding: .utf8)
            ?? "HTTP \(http.statusCode)"
        switch http.statusCode {
        case 401, 403:
            throw EditHereDestinationError.underlying("Authentication failed: \(message)")
        case 404:
            throw EditHereDestinationError.notFound
        case 409:
            throw EditHereDestinationError.conflict(message)
        default:
            throw EditHereDestinationError.underlying(message)
        }
    }
}
