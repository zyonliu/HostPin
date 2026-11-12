import Darwin
import Foundation
@testable import HostPinCore
import Network
import XCTest

final class HostPinCoreTests: XCTestCase {
    private let catalog = """
    [usbeam]
    Group=Sample
    [Public]
    Pool=192.0.2.1,2001:db8::1,invalid
    Speed=https://cdn.example.test/file
    [Sample]
    ZH=样例组
    Group_ID=900
    901.name=Sample CDN
    901.name_zh=样例下载
    901.ip={Pool},192.0.2.1
    901.domain=cdn.example.test,static.example.test
    901.port=8443
    901.cert=cdn.example.test,*.example.test
    901.dltest={Speed}
    902.name=Second CDN
    902.ip=192.0.2.2
    902.domain=cdn.example.test
    """

    func testHostsSearchProducesNonoverlappingUTF16Ranges() {
        let text = "🍎 LOCALhost\r\nlocalhost localhost"
        let matches = HostsDocument.findRanges(of: "localhost", in: text)
        XCTAssertEqual(matches.map(\.location), [3, 14, 24])
        XCTAssertEqual(matches.map { (text as NSString).substring(with: $0) }, ["LOCALhost", "localhost", "localhost"])
        XCTAssertEqual(HostsDocument.findRanges(of: "aa", in: "aaa"), [NSRange(location: 0, length: 2)])
        XCTAssertTrue(HostsDocument.findRanges(of: "", in: text).isEmpty)
    }

    func testCatalogExpansionAndBilingualSearch() throws {
        let rules = try RuleCatalog.parse(Data(catalog.utf8))
        XCTAssertEqual(rules.count, 2)
        let rule = try XCTUnwrap(rules.first)
        XCTAssertEqual(rule.addresses, ["192.0.2.1", "2001:db8::1"])
        XCTAssertEqual(rule.downloadURL?.absoluteString, "https://cdn.example.test/file")
        XCTAssertEqual(rule.port, 8443)
        XCTAssertTrue(rule.matches("样例 cdn.example.test"))
        XCTAssertTrue(rule.matches("sample cdn"))
        XCTAssertFalse(rule.matches("unrelated"))
        XCTAssertThrowsError(try RuleCatalog.parse(Data("<html>unavailable</html>".utf8)))
    }

    func testAppliesAndClearsLegacyMappingsWhilePreservingOtherContent() throws {
        let rule = try XCTUnwrap(RuleCatalog.parse(Data(catalog.utf8)).first)
        let original = "# comment\r\n127.0.0.1 localhost\r\n192.0.2.9 cdn.example.test #UHE_901\r\n192.0.2.9 static.example.test #UHE_\r\n"
        let updated = try HostsDocument.applying([(rule, "192.0.2.1")], to: original)
        XCTAssertEqual(updated, "# comment\r\n127.0.0.1 localhost\r\n192.0.2.1\tcdn.example.test # HostPin:901\r\n192.0.2.1\tstatic.example.test # HostPin:901\r\n")
        XCTAssertEqual(try HostsDocument.applying([(rule, nil)], to: updated), "# comment\r\n127.0.0.1 localhost\r\n")
    }

    func testRejectsConflictsAndLeavesManualEntriesIntact() throws {
        let rules = try RuleCatalog.parse(Data(catalog.utf8))
        let original = "192.0.2.8 cdn.example.test # manual"
        XCTAssertThrowsError(try HostsDocument.applying([(rules[0], "192.0.2.1")], to: original))
        XCTAssertThrowsError(try HostsDocument.applying([(rules[0], "192.0.2.1"), (rules[1], "192.0.2.2")], to: original))
        XCTAssertEqual(try HostsDocument.applying([(rules[0], nil)], to: original), original)
    }

    func testAtomicWriteBackupAndStalePreviewGuard() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hosts")
        let backups = directory.appendingPathComponent("backups")
        let original = "127.0.0.1 localhost\n"
        let updated = original + "192.0.2.1 example.test\n"
        try Data(original.utf8).write(to: file)
        try HostsWriter.replace(updated, expected: original, at: file, backupDirectory: backups, owner: getuid())
        XCTAssertEqual(try HostsDocument.read(file), updated)
        let copies = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try copies.first.map { try HostsDocument.read($0) }, original)
        XCTAssertThrowsError(try HostsWriter.replace(original, expected: original, at: file, backupDirectory: backups, owner: getuid()))
        XCTAssertEqual(try HostsDocument.read(file), updated)
        let alias = directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        XCTAssertThrowsError(try HostsWriter.replace(original, expected: updated, at: alias, backupDirectory: backups, owner: getuid()))
    }

    func testTCPLatencyOnLoopback() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }
        let ready = expectation(description: "TCP listener ready")
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.cancel()
        }
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port)
        let results = await NetworkProbe.latencies([Candidate(address: "127.0.0.1")], port: port.rawValue)
        XCTAssertTrue(results.first?.tested == true)
        XCTAssertNotNil(results.first?.latency)
    }

    func testICMPLatencyOnLoopback() async {
        let results = await NetworkProbe.latencies(
            [Candidate(address: "127.0.0.1"), Candidate(address: "::1")],
            port: 0, mode: .icmp
        )
        XCTAssertEqual(results.count, 2)
        for result in results {
            XCTAssertTrue(result.tested)
            XCTAssertNotNil(result.latency, result.address)
        }
    }

    func testBackupSwitchAndRetention() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("hosts")
        let backups = directory.appendingPathComponent("backups")
        let original = "127.0.0.1 localhost\n"
        let first = original + "192.0.2.1 first.test\n"
        let second = original + "192.0.2.2 second.test\n"
        let third = original + "192.0.2.3 third.test\n"
        try Data(original.utf8).write(to: file)
        try HostsWriter.replace(first, expected: original, at: file, backupDirectory: backups,
                                owner: getuid(), backupEnabled: false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backups.path))
        try HostsWriter.replace(second, expected: first, at: file, backupDirectory: backups,
                                owner: getuid(), backupRetention: 1)
        try HostsWriter.replace(third, expected: second, at: file, backupDirectory: backups,
                                owner: getuid(), backupRetention: 1)
        let copies = try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
        XCTAssertEqual(copies.count, 1)
        XCTAssertEqual(try HostsDocument.read(XCTUnwrap(copies.first)), second)
        XCTAssertEqual(try HostsDocument.read(file), third)
    }

    func testSingleAndBatchOptimizationUseSelectedIPForHTTPDownload() async throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        defer { listener.cancel() }
        let ready = expectation(description: "Local HTTP server ready")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { request, _, _, _ in
                guard let request,
                      String(decoding: request, as: UTF8.self).contains("sample.example.test") else {
                    connection.cancel()
                    return
                }
                var response = Data("HTTP/1.1 206 Partial Content\r\nContent-Length: 4096\r\nConnection: close\r\n\r\n".utf8)
                response.append(Data(repeating: 65, count: 4096))
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: .global())
        await fulfillment(of: [ready], timeout: 3)
        let port = try XCTUnwrap(listener.port).rawValue
        let source = """
        [Sample]
        Group_ID=900
        901.name=Download
        901.domain=sample.example.test
        901.ip=127.0.0.1
        901.port=\(port)
        901.dltest=http://sample.example.test:\(port)/sample
        902.name=No download sample
        902.domain=sample.example.test
        902.ip=127.0.0.1
        902.port=\(port)
        903.name=Second download
        903.domain=sample.example.test
        903.ip=127.0.0.1
        903.port=\(port)
        903.dltest=http://sample.example.test:\(port)/sample
        """
        let rules = try RuleCatalog.parse(Data(source.utf8))
        let rule = try XCTUnwrap(rules.first)
        let result = await NetworkProbe.optimize(rule, candidates: rule.addresses.map(Candidate.init))
        XCTAssertEqual(result.best?.address, "127.0.0.1")
        XCTAssertGreaterThan(result.best?.speed ?? 0, 0)
        XCTAssertFalse(result.best?.tlsVerified ?? true)

        let batch = BatchProbeResults()
        await NetworkProbe.optimizeBatch(rules, screeningLimit: 3, downloadLimit: 1) { _, _ in
        } onResult: { rule, candidate in
            await batch.record(rule.id, candidate: candidate)
        }
        let completed = await batch.candidates
        XCTAssertEqual(Set(completed.keys), Set(rules.map(\.id)))
        XCTAssertEqual(completed["902"]?.address, "127.0.0.1")
        XCTAssertNil(completed["902"]?.speed)
        XCTAssertGreaterThan(completed["901"]?.speed ?? 0, 0)
        XCTAssertGreaterThan(completed["903"]?.speed ?? 0, 0)
    }

    func testLiveCatalogWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["HOSTPIN_TEST_RULES"] else {
            throw XCTSkip("Set HOSTPIN_TEST_RULES to an upstream catalog snapshot to check compatibility.")
        }
        let rules = try RuleCatalog.parse(Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertGreaterThan(rules.count, 500)
        XCTAssertGreaterThan(rules.filter { !$0.addresses.isEmpty }.count, 500)
        XCTAssertTrue(rules.contains { $0.matches("steam") })
        XCTAssertTrue(rules.contains { $0.matches("Steam 直播") })
        print("Parsed \(rules.count) live rules; \(rules.filter { $0.downloadURL != nil }.count) have a compatible HTTP(S) sample.")
    }
}

private actor BatchProbeResults {
    private(set) var candidates: [Rule.ID: Candidate] = [:]

    func record(_ id: Rule.ID, candidate: Candidate?) {
        candidates[id] = candidate
    }
}
