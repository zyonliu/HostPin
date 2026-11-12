import Foundation
import Network

public enum LatencyMode: String, CaseIterable, Sendable {
    case tcp = "TCP"
    case icmp = "ICMP"
}

public struct Candidate: Identifiable, Hashable, Sendable {
    public let address: String
    public var latency: Double?
    public var tested = false
    public var speed: Double?
    public var tlsVerified = false

    public var id: String { address }
    public var downloadMbps: Double? { speed.map { ($0 * 8 / 1_048_576).rounded(.toNearestOrEven) } }

    public init(address: String) { self.address = address }
}

public enum NetworkProbe {
    public static func latencies(
        _ candidates: [Candidate], port: UInt16, parallelism: Int = 24, mode: LatencyMode = .tcp,
        onResult: @escaping @Sendable (Candidate) async -> Void = { _ in }
    ) async -> [Candidate] {
        await parallel(candidates, limit: parallelism) { candidate in
            var result = candidate
            switch mode {
            case .tcp: result.latency = await tcp(candidate.address, port: port)
            case .icmp: result.latency = await icmp(candidate.address)
            }
            result.tested = true
            await onResult(result)
            return result
        }
    }

    public static func optimize(
        _ rule: Rule, candidates: [Candidate], parallelism: Int = 24,
        downloadParallelism: Int = 10, mode: LatencyMode = .tcp,
        onLatency: @escaping @Sendable (Candidate) async -> Void = { _ in },
        onPhase: @escaping @Sendable (String) async -> Void = { _ in }
    ) async -> (best: Candidate?, candidates: [Candidate]) {
        let screened = await screen(rule, candidates: candidates, parallelism: parallelism, mode: mode,
                                    onLatency: onLatency, onPhase: onPhase)
        guard !Task.isCancelled, !screened.eligible.isEmpty else { return (nil, screened.candidates) }
        guard rule.downloadURL != nil else { return (screened.eligible.first, screened.candidates) }

        await onPhase("测试下载速度")
        let shortlist = Array(screened.eligible.prefix(10))
        let tested = await rankDownloads(shortlist, for: rule, parallelism: downloadParallelism)
        return (Task.isCancelled ? nil : tested.best, merge(screened.candidates, tested.candidates))
    }

    public static func optimizeBatch(
        _ rules: [Rule], screeningLimit: Int, downloadLimit: Int, mode: LatencyMode = .tcp,
        onPhase: @escaping @Sendable (Rule, String) async -> Void,
        onResult: @escaping @Sendable (Rule, Candidate?) async -> Void
    ) async {
        let screeningSlots = min(10, max(1, screeningLimit))
        let downloadSlots = min(10, max(1, downloadLimit))
        let screeningFanout = min(24, 48 / screeningSlots)
        let downloadFanout = min(10, 40 / downloadSlots)

        await withTaskGroup(of: BatchEvent.self) { group in
            var remaining = rules[...]
            var awaitingDownload: ArraySlice<(Rule, [Candidate])> = []
            var downloading = 0

            func startScreening(_ rule: Rule) {
                group.addTask {
                    let result = await screen(rule, candidates: rule.addresses.map(Candidate.init),
                                              parallelism: screeningFanout, mode: mode) { phase in
                        await onPhase(rule, phase)
                    }
                    return .screened(rule, result.eligible)
                }
            }

            for _ in 0..<min(screeningSlots, rules.count) {
                if let rule = remaining.popFirst() { startScreening(rule) }
            }
            while let event = await group.next(), !Task.isCancelled {
                switch event {
                case let .screened(rule, eligible):
                    if let next = remaining.popFirst() { startScreening(next) }
                    if rule.downloadURL != nil, !eligible.isEmpty {
                        awaitingDownload.append((rule, Array(eligible.prefix(10))))
                    } else {
                        await onResult(rule, eligible.first)
                    }
                case let .downloaded(rule, best):
                    downloading -= 1
                    await onResult(rule, best)
                }
                while downloading < downloadSlots, !Task.isCancelled,
                      let (rule, candidates) = awaitingDownload.popFirst() {
                    downloading += 1
                    group.addTask {
                        await onPhase(rule, "测试下载速度")
                        let result = await rankDownloads(candidates, for: rule, parallelism: downloadFanout)
                        return .downloaded(rule, result.best)
                    }
                }
            }
            if Task.isCancelled { group.cancelAll() }
        }
    }

    private enum BatchEvent: Sendable {
        case screened(Rule, [Candidate])
        case downloaded(Rule, Candidate?)
    }

    private static func screen(
        _ rule: Rule, candidates: [Candidate], parallelism: Int, mode: LatencyMode,
        onLatency: @escaping @Sendable (Candidate) async -> Void = { _ in },
        onPhase: @escaping @Sendable (String) async -> Void
    ) async -> (eligible: [Candidate], candidates: [Candidate]) {
        await onPhase("检测延迟")
        let measured = await latencies(candidates, port: rule.port, parallelism: parallelism, mode: mode, onResult: onLatency)
        let fastest = measured.filter { $0.latency != nil }.sorted { ($0.latency ?? .infinity) < ($1.latency ?? .infinity) }
        guard !Task.isCancelled, !fastest.isEmpty else { return ([], measured) }

        guard !rule.certificateNames.isEmpty else { return (Array(fastest.prefix(10)), measured) }
        await onPhase("验证 TLS")
        let verified = await verifyTLS(Array(fastest.prefix(20)), for: rule, parallelism: parallelism)
        return (verified.filter(\.tlsVerified), merge(measured, verified))
    }

    private static func verifyTLS(_ candidates: [Candidate], for rule: Rule, parallelism: Int) async -> [Candidate] {
        await parallel(candidates, limit: min(parallelism, 20)) { candidate in
            var result = candidate
            result.tlsVerified = await verify(candidate.address, for: rule)
            return result
        }
    }

    private static func rankDownloads(
        _ candidates: [Candidate], for rule: Rule, parallelism: Int
    ) async -> (best: Candidate?, candidates: [Candidate]) {
        let tested = await parallel(candidates, limit: parallelism) { candidate in
            var result = candidate
            result.speed = await speed(candidate.address, for: rule)
            return result
        }
        let best = tested.max { ($0.downloadMbps ?? 0) < ($1.downloadMbps ?? 0) }
        return (best, tested)
    }

    public static func speed(_ address: String, for rule: Rule) async -> Double? {
        guard let url = rule.downloadURL else { return nil }
        let ip = address.contains(":") ? "[\(address)]" : address
        let result = await run("/usr/bin/curl", [
            "-q", "--silent", "--fail", "--noproxy", "*", "--proto", "=http,https", "--connect-timeout", "3",
            "--max-time", "5", "--location", "--max-redirs", "5", "--proto-redir", "=http,https",
            "--connect-to", "::\(ip):\(rule.port)", "--output", "/dev/null", "--write-out",
            "%{size_download} %{speed_download}", url.absoluteString
        ])
        let fields = result?.output.split(separator: " ").compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? []
        guard fields.count == 2, fields[0] > 0, fields[1] * 8 > 524_288 else { return nil }
        guard let result, [0, 28].contains(result.status) else { return nil }
        return fields[1]
    }

    public static func dns(_ rule: Rule, server: String) async -> [String] {
        guard isIPAddress(server), let domain = rule.domains.first else { return [] }
        return unique(await parallel(["A", "AAAA"], limit: 2) { type in
            let response = await run("/usr/bin/dig", ["@" + server, "+short", "+time=2", "+tries=1", domain + ".", type])
            guard let response, response.status == 0 else { return [String]() }
            return response.output.split(whereSeparator: \.isNewline).map(String.init).filter(isIPAddress)
        }.flatMap { $0 })
    }

    public static func verify(_ address: String, for rule: Rule) async -> Bool {
        let names = rule.certificateNames.compactMap { name -> String? in
            if isHostname(name) { return name }
            guard name.hasPrefix("*.") else { return nil }
            let suffix = name.dropFirst()
            return rule.domains.first { $0.hasSuffix(suffix) && !$0.dropLast(suffix.count).contains(".") }
        }
        let https = rule.downloadURL.flatMap { $0.scheme == "https" ? $0 : nil }
        guard let host = names.first ?? https?.host ?? rule.domains.first else { return false }
        let port = https?.host == host ? (https?.port ?? 443) : Int(rule.port == 80 ? 443 : rule.port)
        let ip = address.contains(":") ? "[\(address)]" : address
        let url = "https://\(host):\(port)/"
        let result = await run("/usr/bin/curl", [
            "-q", "--silent", "--head", "--noproxy", "*", "--proto", "=https", "--connect-timeout", "3",
            "--max-time", "4", "--resolve", "\(host):\(port):\(ip)", "--output", "/dev/null", url
        ])
        return result?.status == 0
    }

    private static func merge(_ original: [Candidate], _ updates: [Candidate]) -> [Candidate] {
        let updated = Dictionary(uniqueKeysWithValues: updates.map { ($0.id, $0) })
        return original.map { updated[$0.id] ?? $0 }
    }

    private static func tcp(_ ip: String, port: UInt16) async -> Double? {
        guard !Task.isCancelled, let port = NWEndpoint.Port(rawValue: port) else { return nil }
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "com.hostpin.tcp")
            let connection = NWConnection(host: NWEndpoint.Host(ip), port: port, using: .tcp)
            let start = DispatchTime.now().uptimeNanoseconds
            let reply = TCPReply(connection, continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: reply.finish(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                case .failed, .cancelled: reply.finish(nil)
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 2) { reply.finish(nil) }
        }
    }

    private static func icmp(_ ip: String) async -> Double? {
        guard isIPAddress(ip) else { return nil }
        let ipv6 = ip.contains(":")
        guard let response = await run(ipv6 ? "/sbin/ping6" : "/sbin/ping", ["-n", "-c", "1", ip], timeout: 2),
              response.status == 0, let time = response.output.range(of: "time=") else { return nil }
        return Double(response.output[time.upperBound...].prefix { $0.isNumber || $0 == "." })
    }

    private static func run(_ executable: String, _ arguments: [String], timeout: Double? = nil) async -> (status: Int32, output: String)? {
        guard !Task.isCancelled else { return nil }
        let command = ProbeCommand(executable, arguments)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if command.start(continuation), let timeout {
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { command.cancel() }
                }
            }
        } onCancel: {
            command.cancel()
        }
    }

    private static func parallel<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], limit: Int, operation: @escaping @Sendable (Input) async -> Output
    ) async -> [Output] {
        await withTaskGroup(of: (Int, Output).self) { group in
            var next = 0
            for _ in 0..<min(max(1, limit), inputs.count) {
                let index = next
                group.addTask { (index, await operation(inputs[index])) }
                next += 1
            }
            var results: [(Int, Output)] = []
            for await result in group {
                results.append(result)
                if next < inputs.count && !Task.isCancelled {
                    let index = next
                    group.addTask { (index, await operation(inputs[index])) }
                    next += 1
                }
            }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}

private final class ProbeCommand: @unchecked Sendable {
    private let process = Process()
    private let output = Pipe()
    private let lock = NSLock()
    private var cancelled = false

    init(_ executable: String, _ arguments: [String]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
    }

    func start(_ continuation: CheckedContinuation<(status: Int32, output: String)?, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else {
            continuation.resume(returning: nil)
            return false
        }
        process.terminationHandler = { [output] finished in
            let bytes = output.fileHandleForReading.readDataToEndOfFile()
            continuation.resume(returning: (finished.terminationStatus, String(decoding: bytes, as: UTF8.self)))
        }
        do {
            try process.run()
            return true
        } catch {
            continuation.resume(returning: nil)
            return false
        }
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        if process.isRunning { process.terminate() }
    }
}

private final class TCPReply: @unchecked Sendable {
    private let connection: NWConnection
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Double?, Never>?

    init(_ connection: NWConnection, _ continuation: CheckedContinuation<Double?, Never>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ value: Double?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        connection.stateUpdateHandler = nil
        connection.cancel()
        pending.resume(returning: value)
    }
}
