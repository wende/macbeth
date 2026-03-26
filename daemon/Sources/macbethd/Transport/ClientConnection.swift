import Foundation

/// Wraps a connected file descriptor with buffered line-delimited I/O.
final class ClientConnection: @unchecked Sendable {
    private let fd: Int32
    private var buffer = Data()
    private let bufferSize = 4096

    init(fd: Int32) {
        self.fd = fd
    }

    /// Read the next newline-delimited line. Returns nil on disconnect.
    func readLine() -> String? {
        while true {
            // Check for a complete line in the buffer
            if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer[buffer.startIndex..<newlineIndex]
                buffer = Data(buffer[(newlineIndex + 1)...])
                return String(data: lineData, encoding: .utf8)
            }

            // Read more data
            var readBuffer = [UInt8](repeating: 0, count: bufferSize)
            let bytesRead = read(fd, &readBuffer, bufferSize)

            if bytesRead <= 0 {
                // Connection closed or error
                if !buffer.isEmpty {
                    let remaining = String(data: buffer, encoding: .utf8)
                    buffer = Data()
                    return remaining
                }
                return nil
            }

            buffer.append(contentsOf: readBuffer[0..<bytesRead])
        }
    }

    /// Write a line (appends newline).
    func writeLine(_ line: String) {
        guard let data = (line + "\n").data(using: .utf8) else { return }
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            var written = 0
            while written < data.count {
                let result = write(fd, base + written, data.count - written)
                if result <= 0 { break }
                written += result
            }
        }
    }

    func close() {
        Foundation.close(fd)
    }
}
