import Foundation

/// A Unix domain socket server that accepts client connections and dispatches JSON-RPC messages.
final class SocketServer: Sendable {
    let socketPath: String
    private let dispatcher: Dispatcher
    private let verbose: Bool
    private let requestLogger: RequestLogger?

    init(socketPath: String, dispatcher: Dispatcher, verbose: Bool = false, requestLogger: RequestLogger? = nil) {
        self.socketPath = socketPath
        self.dispatcher = dispatcher
        self.verbose = verbose
        self.requestLogger = requestLogger
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
        await withTaskGroup(of: Void.self) { group in
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
        let connectionID = UUID().uuidString

        // Each request runs in its own task so a slow handler doesn't stall
        // subsequent requests on the same connection. Writes are serialized
        // by ClientConnection's internal lock.
        await withTaskGroup(of: Void.self) { group in
            while !Task.isCancelled {
                guard let line = connection.readLine() else { break }
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { continue }

                log("← \(trimmed)")
                guard let data = trimmed.data(using: .utf8) else { continue }

                let dispatcher = self.dispatcher
                let verbose = self.verbose
                let logger = self.requestLogger
                let started = Date()
                let paramsBytes = data.count
                group.addTask { [connection] in
                    let decoder = JSONDecoder()
                    let encoder = JSONEncoder()

                    let response: JSONRPCResponse
                    var method: String?
                    var parsedParams: JSONValue?
                    do {
                        let request = try decoder.decode(JSONRPCRequest.self, from: data)
                        method = request.method
                        parsedParams = request.params
                        response = await dispatcher.dispatch(
                            request: request,
                            connectionID: connectionID
                        )
                    } catch {
                        response = JSONRPCResponse(
                            id: nil,
                            error: .parseError("Invalid JSON: \(error.localizedDescription)")
                        )
                    }

                    do {
                        let responseData = try encoder.encode(response)
                        if let responseStr = String(data: responseData, encoding: .utf8) {
                            if verbose {
                                fputs("[macbethd] → \(responseStr)\n", stderr)
                            }
                            connection.writeLine(responseStr)
                            if let logger {
                                Self.emitLog(
                                    logger: logger,
                                    connectionID: connectionID,
                                    method: method,
                                    responseID: response.id,
                                    responseError: response.error,
                                    params: parsedParams,
                                    paramsBytes: paramsBytes,
                                    result: response.result,
                                    resultBytes: responseData.count,
                                    started: started
                                )
                            }
                        }
                    } catch {
                        if verbose {
                            fputs("[macbethd] Failed to encode response: \(error)\n", stderr)
                        }
                        if let logger {
                            // Encode-failure records must look like failures:
                            // the client never got a response, but `emitLog`
                            // derives `ok` from `responseError == nil`, so
                            // pass a synthetic internal error so the row
                            // surfaces under `jq 'select(.ok == false)'` and
                            // downstream alert queries.
                            Self.emitLog(
                                logger: logger,
                                connectionID: connectionID,
                                method: method,
                                responseID: response.id,
                                responseError: .internalError("encode failed: \(error)"),
                                params: parsedParams,
                                paramsBytes: paramsBytes,
                                result: nil,
                                resultBytes: 0,
                                started: started
                            )
                        }
                    }
                }
            }

            // Release connection-owned presentation scopes as soon as EOF is
            // observed. In-flight daemon operations keep their own activity
            // scopes until they actually finish.
            await self.dispatcher.connectionClosed(connectionID)

            // Wait for in-flight requests to finish responding before closing.
            await group.waitForAll()

            // A begin request could have raced EOF and registered its token
            // after the first cleanup. Repeating cleanup is idempotent and
            // closes that narrow race without delaying the normal path.
            await self.dispatcher.connectionClosed(connectionID)
        }

        connection.close()
        log("Client disconnected (fd=\(fd))")
    }

    private func log(_ message: String) {
        if verbose {
            fputs("[macbethd] \(message)\n", stderr)
        }
    }

    // Fire-and-forget — callers wrap this in `Task { … }` and never await;
    // the RequestLogger actor serializes appends without locks.
    private static func emitLog(
        logger: RequestLogger,
        connectionID: String,
        method: String?,
        responseID: JSONRPCId?,
        responseError: JSONRPCErrorData?,
        params: JSONValue?,
        paramsBytes: Int,
        result: JSONValue?,
        resultBytes: Int,
        started: Date
    ) {
        let elapsedMs = Int(Date().timeIntervalSince(started) * 1000)
        let record = RPCLogRecord(
            ts: Self.timestampString(),
            connectionID: connectionID,
            requestID: responseID?.requestIDString,
            method: method,
            paramsBytes: paramsBytes,
            resultBytes: resultBytes,
            durationMs: elapsedMs,
            ok: responseError == nil,
            errorCode: responseError?.code,
            paramsPreview: RPCPreviewBuilder.preview(of: params),
            resultPreview: RPCPreviewBuilder.preview(of: result)
        )
        Task { await logger.log(record) }
    }

    private static func timestampString() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: Date())
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
