import Foundation

public extension RuleCatalog {
    static func download(from source: URL) async throws -> (data: Data, origin: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return try await download(from: source, session: session)
    }
}

extension RuleCatalog {
    static func download(from source: URL, session: URLSession) async throws -> (data: Data, origin: URL) {
        guard httpsSource(source.absoluteString) != nil else {
            throw HostPinError.message("请输入有效的 HTTPS 规则文件地址。")
        }
        let request = URLRequest(url: source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        let (bytes, response) = try await session.bytes(for: request, delegate: CatalogRedirectPolicy())
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let origin = http.url, httpsSource(origin.absoluteString) != nil else {
            throw HostPinError.message("规则服务器返回错误。")
        }
        guard response.expectedContentLength <= maxSize else {
            throw HostPinError.message("规则文件过大或不是 UTF-8 格式。")
        }
        var data = Data()
        data.reserveCapacity(Int(max(0, response.expectedContentLength)))
        for try await byte in bytes {
            guard data.count < maxSize else { throw HostPinError.message("规则文件过大或不是 UTF-8 格式。") }
            if data.count.isMultiple(of: 4096) { try Task.checkCancellation() }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, origin)
    }
}

final class CatalogRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Reject a downgrade before credentials/content could cross an HTTP hop.
        let allowed = request.url.flatMap { RuleCatalog.httpsSource($0.absoluteString) } != nil
        completionHandler(allowed ? request : nil)
    }
}
