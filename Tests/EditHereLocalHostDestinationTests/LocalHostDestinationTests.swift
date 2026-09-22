import Foundation
import Testing
import EditHereCore
import EditHereLocalHostDestination

@Suite(.serialized)
struct EditHereLocalHostDestinationTests {
    @Test func projectConfigurationDecodesSampleShape() throws {
        let json = """
        {
          "schemaVersion": "1",
          "projectID": "edithere-sample",
          "displayName": "EditHere Sample",
          "receiver": {
            "baseURL": "http://127.0.0.1:8787",
            "submitPath": "/v1/submissions",
            "tokenHeader": "X-EditHere-Token",
            "tokenEnvHint": "EDITHHERE_HOST_TOKEN"
          },
          "build": { "scheme": "EditHereSample" },
          "delivery": { "method": "ios-deliver" },
          "acceptance": { "screens": ["sample-home"] }
        }
        """.data(using: .utf8)!

        let config = try EditHereJSONCoding.decoder.decode(EditHereProjectConfiguration.self, from: json)
        #expect(config.projectID == "edithere-sample")
        #expect(config.receiver.baseURL.absoluteString == "http://127.0.0.1:8787")
        #expect(config.receiver.submitPath == "/v1/submissions")
        #expect(config.receiver.tokenHeader == "X-EditHere-Token")
        #expect(config.build?.scheme == "EditHereSample")
        #expect(config.acceptance?.screens == ["sample-home"])
    }

    @Test func initFromProjectConfigBuildsSubmitURL() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edithere-cfg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("edithere.project.json")
        try """
        {
          "schemaVersion": "1",
          "projectID": "edithere-sample",
          "displayName": "EditHere Sample",
          "receiver": {
            "baseURL": "http://127.0.0.1:8787",
            "submitPath": "/v1/submissions",
            "tokenHeader": "X-EditHere-Token",
            "tokenEnvHint": "EDITHHERE_HOST_TOKEN"
          }
        }
        """.write(to: url, atomically: true, encoding: .utf8)

        let destination = try EditHereLocalHostDestination(projectConfigURL: url, token: "test-token")
        #expect(destination.projectID == "edithere-sample")
        #expect(destination.destinationID == "local-host")
        #expect(destination.capabilities.supportsDirectExecution)
        #expect(destination.baseURL.absoluteString == "http://127.0.0.1:8787")
        #expect(destination.discoveryEnabled)
    }

    @Test func discoveryConstantsMatchHostContract() {
        // Mirror of host/edithere_host/advertise.py (sibling host/ repo)
        #expect(EditHereLocalHostDestination.discoveryServiceType == "_edithere._tcp.")
        #expect(EditHereLocalHostDestination.discoveryDomain == "local.")
    }

    @Test func contentDigestMatchesCoreHelper() throws {
        let png = Data(repeating: 7, count: 16)
        let package = makePackage(png: png)
        let assets = [
            package.captures[0].originalImage.relativePath: png,
            package.captures[0].annotatedImage.relativePath: png
        ]
        let digest = try EditHereHashing.contentDigest(for: package, assets: assets)
        #expect(digest.count == 64)
        #expect(digest == (try EditHereHashing.contentDigest(for: package, assets: assets)))
    }

    @Test func executionContentDigestIgnoresOriginalBytes() throws {
        let annotated = Data(repeating: 7, count: 16)
        let originalA = Data(repeating: 1, count: 16)
        let originalB = Data(repeating: 2, count: 16)
        let package = makePackage(png: annotated)
        let annotatedPath = package.captures[0].annotatedImage.relativePath
        let originalPath = package.captures[0].originalImage.relativePath
        let a = try EditHereHashing.executionContentDigest(
            for: package,
            assets: [annotatedPath: annotated, originalPath: originalA]
        )
        let b = try EditHereHashing.executionContentDigest(
            for: package,
            assets: [annotatedPath: annotated, originalPath: originalB]
        )
        #expect(a == b)
    }

    @Test func submitSuccessAndConflictViaURLProtocol() async throws {
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)

        let png = Data(repeating: 3, count: 24)
        let package = makePackage(png: png)
        let packageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("edithere-lh-\(UUID().uuidString)", isDirectory: true)
        let originalPath = package.captures[0].originalImage.relativePath
        let annotatedPath = package.captures[0].annotatedImage.relativePath
        _ = try EditHereEvidenceWriter().write(
            package: package,
            to: packageRoot,
            assets: [originalPath: png, annotatedPath: png]
        )
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let remoteID = UUID().uuidString
        MockURLProtocol.handler = { request in
            #expect(request.value(forHTTPHeaderField: "X-EditHere-Token") == "secret")
            #expect(request.httpMethod == "POST")
            #expect(request.url?.path == "/v1/submissions")
            let body = Self.requestBody(request)
            let bodyText = String(data: body, encoding: .utf8) ?? ""
            #expect(bodyText.contains("name=\"projectID\""))
            #expect(bodyText.contains("name=\"contentDigest\""))
            #expect(bodyText.contains("name=\"package\""))
            #expect(bodyText.contains("name=\"agent-prompt.txt\""))
            #expect(bodyText.contains("name=\"page-1.png\"") || bodyText.contains("filename=\"page-1.png\""))
            #expect(bodyText.contains("name=\"assets/") || bodyText.contains("filename="))
            #expect(!bodyText.contains("-original.png\"; filename="))
            #expect(bodyText.contains("-annotated.png\"; filename="))

            let payload = """
            {
              "ok": true,
              "data": {
                "remoteTaskID": "\(remoteID)",
                "submissionID": "\(package.id.uuidString)",
                "destinationID": "local-host",
                "projectID": "edithere-sample",
                "state": "submitted",
                "summary": "Accepted"
              },
              "error": null,
              "meta": {"executionPath": "named-executor-dump"}
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, payload)
        }

        let destination = EditHereLocalHostDestination(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            projectID: "edithere-sample",
            token: "secret",
            session: session,
            discoveryEnabled: false
        )
        let receipt = try await destination.submit(package: package, assetRootURL: packageRoot)
        #expect(receipt.remoteTaskID == remoteID)
        #expect(receipt.state == .submitted)
        #expect(receipt.submissionID == package.id)

        MockURLProtocol.handler = { request in
            let payload = """
            {
              "ok": false,
              "data": null,
              "error": {"code":"conflict","message":"Digest mismatch","hint":null},
              "meta": {}
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 409,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, payload)
        }

        do {
            _ = try await destination.submit(package: package, assetRootURL: packageRoot)
            Issue.record("Expected conflict")
        } catch let error as EditHereDestinationError {
            guard case .conflict = error else {
                Issue.record("Expected conflict, got \(error)")
                return
            }
        }
    }

    @Test func submitRejectsSuccessWithoutNamedExecutorDumpMeta() async throws {
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)

        let png = Data(repeating: 3, count: 24)
        let package = makePackage(png: png)
        let packageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("edithere-lh-\(UUID().uuidString)", isDirectory: true)
        let originalPath = package.captures[0].originalImage.relativePath
        let annotatedPath = package.captures[0].annotatedImage.relativePath
        _ = try EditHereEvidenceWriter().write(
            package: package,
            to: packageRoot,
            assets: [originalPath: png, annotatedPath: png]
        )
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        MockURLProtocol.handler = { request in
            let payload = """
            {
              "ok": true,
              "data": {
                "remoteTaskID": "\(UUID().uuidString)",
                "submissionID": "\(package.id.uuidString)",
                "destinationID": "local-host",
                "projectID": "edithere-sample",
                "state": "submitted",
                "summary": "Accepted"
              },
              "error": null,
              "meta": {}
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, payload)
        }

        let destination = EditHereLocalHostDestination(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            projectID: "edithere-sample",
            token: "secret",
            session: session,
            discoveryEnabled: false
        )
        do {
            _ = try await destination.submit(package: package, assetRootURL: packageRoot)
            Issue.record("Expected rejection of old receiver without executionPath")
        } catch let error as EditHereDestinationError {
            guard case .underlying(let message) = error else {
                Issue.record("Expected underlying dump-capability error, got \(error)")
                return
            }
            #expect(message.contains("dump-capable"))
        }
    }

    @Test func lookupBySubmissionIDAndCancel() async throws {
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let submissionID = UUID()
        let remoteID = UUID().uuidString

        MockURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                #expect(request.url?.path.contains(submissionID.uuidString) == true)
                let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                #expect(items?.contains(where: { $0.name == "projectID" && $0.value == "edithere-sample" }) == true)
                let payload = """
                {
                  "ok": true,
                  "data": {
                    "remoteTaskID": "\(remoteID)",
                    "submissionID": "\(submissionID.uuidString)",
                    "destinationID": "local-host",
                    "projectID": "edithere-sample",
                    "state": "working",
                    "summary": "In progress",
                    "markOutcomes": [
                      {"number":1,"status":"changed","summary":"Renamed","paths":["a.swift"]}
                    ],
                    "verification": {
                      "codeChanged": true,
                      "checksPassed": null,
                      "artifactReady": false,
                      "installed": false,
                      "visuallyVerified": false
                    }
                  },
                  "error": null,
                  "meta": {}
                }
                """.data(using: .utf8)!
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!
                return (response, payload)
            }

            #expect(request.httpMethod == "POST")
            #expect(request.url?.absoluteString.contains("/cancel") == true)
            let payload = """
            {"ok":true,"data":{"remoteTaskID":"\(remoteID)","state":"cancelled"},"error":null,"meta":{}}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, payload)
        }

        let destination = EditHereLocalHostDestination(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            projectID: "edithere-sample",
            token: "secret",
            session: session,
            discoveryEnabled: false
        )
        let status = try await destination.lookup(submissionID: submissionID)
        #expect(status.state == .working)
        #expect(status.markOutcomes.count == 1)
        #expect(status.markOutcomes[0].status == .changed)
        #expect(status.verification?.codeChanged == true)

        try await destination.cancel(remoteTaskID: remoteID)
    }

    @Test func lookupRejectsMismatchedProjectID() async throws {
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let submissionID = UUID()
        MockURLProtocol.handler = { request in
            let payload = """
            {
              "ok": true,
              "data": {
                "remoteTaskID": "remote-x",
                "submissionID": "\(submissionID.uuidString)",
                "destinationID": "local-host",
                "projectID": "other-project",
                "state": "working"
              },
              "error": null,
              "meta": {}
            }
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, payload)
        }
        let destination = EditHereLocalHostDestination(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            projectID: "edithere-sample",
            token: "secret",
            session: session,
            discoveryEnabled: false
        )
        do {
            _ = try await destination.lookup(submissionID: submissionID)
            Issue.record("Expected project conflict")
        } catch let error as EditHereDestinationError {
            guard case .conflict = error else {
                Issue.record("Expected conflict, got \(error)")
                return
            }
        }
    }

    @Test func unauthorizedMapsToUnderlying() async throws {
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        MockURLProtocol.handler = { request in
            let payload = """
            {"ok":false,"data":null,"error":{"code":"unauthorized","message":"bad token","hint":null},"meta":{}}
            """.data(using: .utf8)!
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 401,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            return (response, payload)
        }

        let png = Data(repeating: 1, count: 8)
        let package = makePackage(png: png)
        let packageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("edithere-auth-\(UUID().uuidString)", isDirectory: true)
        let originalPath = package.captures[0].originalImage.relativePath
        let annotatedPath = package.captures[0].annotatedImage.relativePath
        _ = try EditHereEvidenceWriter().write(
            package: package,
            to: packageRoot,
            assets: [originalPath: png, annotatedPath: png]
        )
        defer { try? FileManager.default.removeItem(at: packageRoot) }

        let destination = EditHereLocalHostDestination(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            projectID: "edithere-sample",
            token: "bad",
            session: session,
            discoveryEnabled: false
        )
        do {
            _ = try await destination.submit(package: package, assetRootURL: packageRoot)
            Issue.record("Expected auth failure")
        } catch let error as EditHereDestinationError {
            guard case .underlying(let message) = error else {
                Issue.record("Expected underlying, got \(error)")
                return
            }
            #expect(message.contains("Authentication failed"))
        }
    }

    private func makePackage(png: Data) -> EditHereEvidencePackage {
        let captureID = UUID()
        let hash = EditHereHashing.sha256Hex(of: png)
        let originalPath = "assets/\(captureID.uuidString)-original.png"
        let annotatedPath = "assets/\(captureID.uuidString)-annotated.png"
        return EditHereEvidencePackage(
            app: EditHereAppBinding(
                bundleIdentifier: "demo.edithere",
                displayName: "Demo",
                marketingVersion: "1.0",
                buildNumber: "1"
            ),
            environment: EditHereEnvironment(
                screenWidth: 100,
                screenHeight: 200,
                screenScale: 2,
                localeIdentifier: "en_US"
            ),
            captures: [
                EditHereCapture(
                    id: captureID,
                    screenID: "home",
                    orientation: "portrait",
                    originalImage: EditHereImageAsset(
                        relativePath: originalPath,
                        sha256: hash,
                        byteCount: png.count,
                        width: 100,
                        height: 200,
                        scale: 2
                    ),
                    annotatedImage: EditHereImageAsset(
                        relativePath: annotatedPath,
                        sha256: hash,
                        byteCount: png.count,
                        width: 100,
                        height: 200,
                        scale: 2
                    )
                )
            ],
            annotations: [
                EditHereAnnotation(
                    number: 1,
                    captureID: captureID,
                    selectionKind: .bounds,
                    bounds: EditHereRect(x: 1, y: 2, width: 3, height: 4),
                    action: .changeText,
                    requestText: "Rename title",
                    confidence: .high
                )
            ]
        )
    }

    private static func requestBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() {
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
