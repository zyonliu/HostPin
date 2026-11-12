import Darwin
import Foundation

public enum LimitedFile {
    /// Bound reads before allocation and reject devices/FIFOs without blocking.
    public static func read(_ url: URL, maximumSize: Int) throws -> Data {
        guard maximumSize > 0, maximumSize < Int.max else {
            throw HostPinError.message("文件大小限制无效。")
        }
        let descriptor = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
              status.st_size >= 0, status.st_size <= maximumSize else {
            throw HostPinError.message("文件过大或不是普通文件。")
        }
        let data = try file.read(upToCount: maximumSize + 1) ?? Data()
        guard data.count <= maximumSize else { throw HostPinError.message("文件过大或不是普通文件。") }
        return data
    }
}
