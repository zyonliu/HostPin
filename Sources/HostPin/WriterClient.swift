import Foundation
import HostPinCore
import ServiceManagement

enum WriterClient {
    private static var team: String? { Bundle.main.object(forInfoDictionaryKey: "HostPinTeamID") as? String }
    private static let service = SMAppService.daemon(plistName: HelperConfiguration.plistName)
    private static var signedRequirement: String? {
        team.flatMap { HelperConfiguration.requirement(identifier: HelperConfiguration.label, team: $0) }
    }
    private static var localRequirement: String? {
        guard let hashes = Bundle.main.object(forInfoDictionaryKey: "HostPinLocalWriterHashes") as? [String] else {
            return nil
        }
        return HelperConfiguration.localRequirement(identifier: HelperConfiguration.localLabel, hashes: hashes)
    }

    static func isEnabled() async -> Bool {
        if signedRequirement != nil { return service.status == .enabled }
        guard localRequirement != nil else { return false }
        do {
            try await request { writer, reply in writer.checkReady(reply: reply) }
            return true
        } catch { return false }
    }

    static func enable() async throws {
        if localRequirement != nil {
            guard await isEnabled() else {
                throw HostPinError.message("写入助手未运行。请退出 HostPin 后重新运行本地安装包。")
            }
            return
        }
        guard signedRequirement != nil else {
            throw HostPinError.message("当前是本地预览构建。用 Apple 签名身份打包后才能启用系统 Hosts 写入。")
        }
        if service.status == .notRegistered {
            do { try service.register() }
            catch {
                guard service.status == .requiresApproval else { throw error }
            }
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        else if service.status != .enabled {
            throw HostPinError.message("写入助手不可用。请将签名版本安装到“应用程序”后重试。")
        }
    }

    static func replace(_ proposed: String, expected: String, backupEnabled: Bool, backupRetention: Int) async throws {
        try await request { writer, reply in
            writer.replaceHosts(proposed, expected: expected, backupEnabled: backupEnabled, backupRetention: backupRetention, reply: reply)
        }
    }

    static func prepareBackupDirectory() async throws {
        try await request { writer, reply in writer.prepareBackupDirectory(reply: reply) }
    }

    private static func request(_ perform: (HostsWriting, @escaping (String?) -> Void) -> Void) async throws {
        let label: String
        let requirement: String
        if let signedRequirement, service.status == .enabled {
            label = HelperConfiguration.label
            requirement = signedRequirement
        } else if let localRequirement {
            label = HelperConfiguration.localLabel
            requirement = localRequirement
        } else {
            throw HostPinError.message("请先启用 Hosts 写入。")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let connection = NSXPCConnection(machServiceName: label, options: .privileged)
            let reply = WriteReply(connection, continuation)
            connection.setCodeSigningRequirement(requirement)
            connection.remoteObjectInterface = NSXPCInterface(with: HostsWriting.self)
            connection.invalidationHandler = { reply.finish("无法连接 Hosts 写入助手。") }
            connection.interruptionHandler = { reply.finish("Hosts 写入助手中断。请刷新文件，确认是否已写入。") }
            connection.resume()
            let proxy = connection.remoteObjectProxyWithErrorHandler { reply.finish($0.localizedDescription) }
            guard let writer = proxy as? HostsWriting else { reply.finish("无法建立写入连接。"); return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 12) {
                reply.finish("助手未及时回复。请先刷新文件，确认是否已写入。")
            }
            perform(writer) { reply.finish($0) }
        }
    }
}

private final class WriteReply: @unchecked Sendable {
    let connection: NSXPCConnection
    let lock = NSLock()
    var continuation: CheckedContinuation<Void, Error>?

    init(_ connection: NSXPCConnection, _ continuation: CheckedContinuation<Void, Error>) {
        self.connection = connection
        self.continuation = continuation
    }

    func finish(_ error: String?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return }
        if let error { pending.resume(throwing: HostPinError.message(error)) }
        else { pending.resume() }
        connection.invalidationHandler = nil
        connection.interruptionHandler = nil
        connection.invalidate()
    }
}
