import Foundation
import GlowProtocol

/// Reads newline-delimited `GlowMessage` JSON from stdin on a background queue.
///
/// When stdin reaches EOF (the daemon closed the pipe or exited), `onEOF` fires
/// so the helper can terminate — guaranteeing no orphaned overlay process.
final class StdinLineReader: @unchecked Sendable {
    private let handle = FileHandle.standardInput
    private var buffer = Data()
    private let onMessage: @Sendable (GlowMessage) -> Void
    private let onEOF: @Sendable () -> Void

    init(
        onMessage: @escaping @Sendable (GlowMessage) -> Void,
        onEOF: @escaping @Sendable () -> Void
    ) {
        self.onMessage = onMessage
        self.onEOF = onEOF
    }

    deinit {
        // `FileHandle.standardInput` is a process-wide singleton; clear our
        // handler so it isn't left monitoring stdin after we're gone.
        handle.readabilityHandler = nil
    }

    func start() {
        handle.readabilityHandler = { [weak self] fh in
            guard let self else { return }
            let chunk = fh.availableData
            if chunk.isEmpty {
                fh.readabilityHandler = nil
                self.onEOF()
                return
            }
            self.buffer.append(chunk)
            self.drain()
        }
    }

    private func drain() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            let trimmed = Data(lineData.filter { $0 != 0x0D })
            guard !trimmed.isEmpty else { continue }
            if let message = try? GlowMessage.decode(line: trimmed) {
                onMessage(message)
            }
        }
    }
}
