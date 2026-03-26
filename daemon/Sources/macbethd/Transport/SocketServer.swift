import Foundation

/// A Unix domain socket server that accepts client connections and dispatches JSON-RPC messages.
final class SocketServer: Sendable {
    let socketPath: String
    private let dispatcher: Dispatcher
    private let verbose: Bool

    init(socketPath: String, dispatcher: Dispatcher, verbose: Bool = false) {
        self.socketPath = socketPath
        self.dispatcher = dispatcher
        self.verbose = verbose
    }

    /// Start listening for connections. Blocks until cancelled.
    func start() async throws {
        // Remove stale socket file
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ServerError.socketCreationFailed(errno: errno)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
            throw ServerError.pathTooLong(socketPath)
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                pathBytes.withUnsafeBufferPointer { src in
                    _ = memcpy(dest, src.baseAddress!, src.count)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw ServerError.bindFailed(errno: errno)
        }

        guard listen(fd, 5) == 0 else {
            close(fd)
            throw ServerError.listenFailed(errno: errno)
        }

        log("Listening on \(socketPath)")

        // Accept loop
        try await withThrowingTaskGroup(of: Void.self) { group in
            while !Task.isCancelled {
                let clientFd = await acceptConnection(serverFd: fd)
                guard clientFd >= 0 else {
                    if Task.isCancelled { break }
                    continue
                }
                log("Client connected (fd=\(clientFd))")
                group.addTask {
                    await self.handleClient(fd: clientFd)
                }
            }
            close(fd)
            unlink(self.socketPath)
        }
    }

    private func acceptConnection(serverFd: Int32) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var clientAddr = sockaddr_un()
                var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)
                let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        accept(serverFd, sockPtr, &clientLen)
                    }
                }
                continuation.resume(returning: clientFd)
            }
        }
    }

    private func handleClient(fd: Int32) async {
        let connection = ClientConnection(fd: fd)
        defer {
            connection.close()
            log("Client disconnected (fd=\(fd))")
        }

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()

        while !Task.isCancelled {
            guard let line = connection.readLine() else { break }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            log("← \(trimmed)")

            guard let data = trimmed.data(using: .utf8) else { continue }

            let response: JSONRPCResponse
            do {
                let request = try decoder.decode(JSONRPCRequest.self, from: data)
                response = await dispatcher.dispatch(request: request)
            } catch {
                response = JSONRPCResponse(
                    id: nil,
                    error: .parseError("Invalid JSON: \(error.localizedDescription)")
                )
            }

            do {
                let responseData = try encoder.encode(response)
                if let responseStr = String(data: responseData, encoding: .utf8) {
                    log("→ \(responseStr)")
                    connection.writeLine(responseStr)
                }
            } catch {
                log("Failed to encode response: \(error)")
            }
        }
    }

    private func log(_ message: String) {
        if verbose {
            fputs("[macbethd] \(message)\n", stderr)
        }
    }
}

enum ServerError: Error, CustomStringConvertible {
    case socketCreationFailed(errno: Int32)
    case pathTooLong(String)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)

    var description: String {
        switch self {
        case .socketCreationFailed(let e): "Failed to create socket: \(String(cString: strerror(e)))"
        case .pathTooLong(let p): "Socket path too long: \(p)"
        case .bindFailed(let e): "Failed to bind socket: \(String(cString: strerror(e)))"
        case .listenFailed(let e): "Failed to listen: \(String(cString: strerror(e)))"
        }
    }
}
