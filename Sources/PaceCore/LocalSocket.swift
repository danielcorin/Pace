import Darwin
import Foundation

public final class LocalSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (IPCRequest) async -> IPCResponse

    private let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.pace.clipboard.ipc", qos: .userInitiated)
    private var descriptor: Int32 = -1
    private var running = false

    public init(path: String = PacePaths.socketURL.path, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        guard !running else { return }
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        Darwin.unlink(path)

        descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw PaceError.unavailable("Could not create Pace's local service socket.")
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            stop()
            throw PaceError.unavailable("Pace's service path is too long.")
        }
        path.withCString { source in
            _ = Darwin.strlcpy(
                &address.sun_path.0,
                source,
                MemoryLayout.size(ofValue: address.sun_path)
            )
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(descriptor, 16) == 0 else {
            stop()
            throw PaceError.unavailable("Could not start Pace's local service.")
        }
        Darwin.chmod(path, S_IRUSR | S_IWUSR)
        running = true
        queue.async { [weak self] in self?.acceptLoop() }
    }

    public func stop() {
        running = false
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        Darwin.unlink(path)
    }

    deinit { stop() }

    private func acceptLoop() {
        while running {
            let client = Darwin.accept(descriptor, nil, nil)
            guard client >= 0 else {
                if running { continue }
                return
            }
            Task { [handler] in
                defer { Darwin.close(client) }
                do {
                    let requestData = try Self.readFrame(from: client)
                    let request = try JSONDecoder.pace.decode(IPCRequest.self, from: requestData)
                    let response = await handler(request)
                    try Self.writeFrame(JSONEncoder.pace.encode(response), to: client)
                } catch {
                    let response = IPCResponse.failure(id: UUID(), error: error)
                    try? Self.writeFrame(JSONEncoder.pace.encode(response), to: client)
                }
            }
        }
    }

    fileprivate static func writeFrame(_ data: Data, to descriptor: Int32) throws {
        guard data.count <= 32 * 1_024 * 1_024 else {
            throw PaceError.invalidArgument("The local request exceeded 32 MB.")
        }
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { try writeAll($0, to: descriptor) }
        try data.withUnsafeBytes { try writeAll($0, to: descriptor) }
    }

    fileprivate static func readFrame(from descriptor: Int32) throws -> Data {
        var length = UInt32(0)
        try withUnsafeMutableBytes(of: &length) { try readAll($0, from: descriptor) }
        let count = Int(UInt32(bigEndian: length))
        guard count >= 0, count <= 32 * 1_024 * 1_024 else {
            throw PaceError.invalidArgument("The local response exceeded 32 MB.")
        }
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { try readAll($0, from: descriptor) }
        return data
    }

    private static func writeAll(_ bytes: UnsafeRawBufferPointer, to descriptor: Int32) throws {
        var written = 0
        while written < bytes.count {
            let result = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
            guard result > 0 else { throw PaceError.unavailable("Pace's local service disconnected.") }
            written += result
        }
    }

    private static func readAll(_ bytes: UnsafeMutableRawBufferPointer, from descriptor: Int32) throws {
        var readCount = 0
        while readCount < bytes.count {
            let result = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: readCount), bytes.count - readCount)
            guard result > 0 else { throw PaceError.unavailable("Pace's local service disconnected.") }
            readCount += result
        }
    }
}

public enum LocalSocketClient {
    public static func send(
        _ request: IPCRequest,
        path: String = PacePaths.socketURL.path
    ) throws -> IPCResponse {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw PaceError.unavailable("Could not connect to Pace.")
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw PaceError.unavailable("Pace's service path is too long.")
        }
        path.withCString { source in
            _ = Darwin.strlcpy(
                &address.sun_path.0,
                source,
                MemoryLayout.size(ofValue: address.sun_path)
            )
        }

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            throw PaceError.unavailable("Pace is not running. Open Pace and try again.")
        }

        try LocalSocketServer.writeFrame(JSONEncoder.pace.encode(request), to: descriptor)
        let data = try LocalSocketServer.readFrame(from: descriptor)
        return try JSONDecoder.pace.decode(IPCResponse.self, from: data)
    }
}
