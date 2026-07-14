import AppKit
import Foundation

/// Register the connect_app RPC method.
func registerConnectApp(dispatcher: Dispatcher, appManager: AppConnectionManager) {
    Task {
        await dispatcher.register(method: "connect_app") { params in
            guard let obj = params?.objectValue else {
                throw RPCError.invalidParams("Expected object params")
            }

            let name = obj["name"]?.stringValue
            let pid = obj["pid"]?.intValue
            let readyTimeoutMs = obj["readyTimeoutMs"]?.intValue

            let connection = try await appManager.connect(
                name: name, pid: pid, readyTimeoutMs: readyTimeoutMs
            )

            return .object([
                "appHandle": .string(connection.handleId),
                "name": .string(connection.appName ?? "unknown"),
                "pid": .number(Double(connection.pid)),
                "bundleId": connection.bundleId.map { .string($0) } ?? .null,
                "runtime": .string(connection.runtime.rawValue),
            ])
        }
    }
}
