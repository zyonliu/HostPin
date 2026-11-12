import Darwin
import Foundation
@testable import HostPinCore
import XCTest

final class InputSecurityTests: XCTestCase {
    func testRejectsNULAddressesAndCatalogs() {
        XCTAssertFalse(isIPAddress("127.0.0.1\0example"))
        XCTAssertFalse(isIPAddress("::1\0"))
        XCTAssertTrue(isIPAddress("::1"))
        XCTAssertFalse(isHostname("example.test\n127.0.0.1"))
        XCTAssertThrowsError(try RuleCatalog.parse(Data("[a]\nGroup_ID=1\n1.domain=a.test\n1.ip=127.0.0.1\0evil".utf8)))
        XCTAssertNil(HelperConfiguration.localRequirement(identifier: "com.hostpin.app", hashes: ["bad", "bad"]))
        XCTAssertNil(HelperConfiguration.requirement(identifier: "com.other.app", team: "ABCDEFGHIJ"))
    }

    func testFileReaderRejectsOversizeAndFIFOWithoutBlocking() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sparse")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data("ok".utf8)))
        XCTAssertEqual(try LimitedFile.read(file, maximumSize: 2), Data("ok".utf8))
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: UInt64(RuleCatalog.maxSize + 1))
        try handle.close()
        XCTAssertThrowsError(try LimitedFile.read(file, maximumSize: RuleCatalog.maxSize))
        let fifo = directory.appendingPathComponent("pipe")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        XCTAssertThrowsError(try LimitedFile.read(fifo, maximumSize: 1024))
    }

    func testWriterRejectsHardlinksAndUntrustedPermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hosts")
        let backup = directory.appendingPathComponent("backups")
        let original = "127.0.0.1 localhost\n"
        try Data(original.utf8).write(to: file)
        let alias = directory.appendingPathComponent("hardlink")
        XCTAssertEqual(link(file.path, alias.path), 0)
        XCTAssertThrowsError(try HostsWriter.replace(original + "# edit\n", expected: original,
                                                     at: file, backupDirectory: backup, owner: getuid()))
        try FileManager.default.removeItem(at: alias)
        XCTAssertEqual(chmod(file.path, 0o666), 0)
        XCTAssertThrowsError(try HostsWriter.replace(original + "# edit\n", expected: original,
                                                     at: file, backupDirectory: backup, owner: getuid()))
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: directory)
        XCTAssertThrowsError(try HostsWriter.replace(original + "# edit\n", expected: original,
                                                     at: file, backupDirectory: backup, owner: getuid()))
        XCTAssertEqual(try HostsDocument.read(file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted(), ["backups", "hosts"])
    }

    func testCatalogExpansionBudget() {
        let source = "[Public]\nPool=" + String(repeating: "127.0.0.1,", count: 100_000) +
            "\n[a]\nGroup_ID=1\n" + (1...40).map { "\($0).domain=a.test\n\($0).ip={Pool}" }.joined(separator: "\n")
        XCTAssertLessThan(source.utf8.count, RuleCatalog.maxSize)
        XCTAssertThrowsError(try RuleCatalog.parse(Data(source.utf8)))
    }

    func testRedirectPolicyRejectsHTTPAndEmbeddedCredentials() {
        let delegate = CatalogRedirectPolicy()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let source = URL(string: "https://rules.example.test/old")!
        let task = session.dataTask(with: source)
        let response = HTTPURLResponse(url: source, statusCode: 302, httpVersion: nil, headerFields: nil)!
        for target in ["http://rules.example.test/new", "https://user:password@rules.example.test/new"] {
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                newRequest: URLRequest(url: URL(string: target)!)) { XCTAssertNil($0) }
        }
        let target = URLRequest(url: URL(string: "https://new.example.test/rules")!)
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response,
                            newRequest: target) { XCTAssertEqual($0?.url, target.url) }
    }

    func testStreamingDownloadRejectsOversizeWithAndWithoutLength() async throws {
        for path in ["valid", "declared-large", "stream-large", "http-error"] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [CatalogFixture.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do {
                let result = try await RuleCatalog.download(from: URL(string: "https://rules.example.test/\(path)")!, session: session)
                XCTAssertEqual(path, "valid")
                XCTAssertEqual(result.data, Data("fixture".utf8))
            } catch {
                XCTAssertNotEqual(path, "valid", error.localizedDescription)
            }
        }
    }
}

private final class CatalogFixture: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url!.lastPathComponent
        let headers = path == "declared-large" ? ["Content-Length": String(RuleCatalog.maxSize + 1)] : [:]
        let response = HTTPURLResponse(url: request.url!, statusCode: path == "http-error" ? 503 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "stream-large" {
            client?.urlProtocol(self, didLoad: Data(repeating: 65, count: RuleCatalog.maxSize + 1))
        } else {
            client?.urlProtocol(self, didLoad: Data("fixture".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
