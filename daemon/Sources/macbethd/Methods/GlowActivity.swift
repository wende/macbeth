import Foundation

/// Register explicit activity scopes for MCP-side operations that can control
/// the computer without otherwise passing through an instrumented daemon RPC.
func registerGlowActivity(dispatcher: Dispatcher, glow: GlowIndicator) {
    Task {
        await dispatcher.registerContextual(method: "begin_activity") { _, connectionID in
            let token = await glow.beginExternalActivity(owner: connectionID)
            return .object(["token": .string(token)])
        }

        await dispatcher.registerContextual(method: "end_activity") { params, connectionID in
            guard let obj = params?.objectValue,
                  let token = obj["token"]?.stringValue else {
                throw RPCError.invalidParams("Missing 'token'")
            }
            guard await glow.endExternalActivity(token: token, owner: connectionID) else {
                throw RPCError.invalidParams("Unknown or already-ended activity token")
            }
            return .object(["ended": .bool(true)])
        }

        await dispatcher.registerConnectionClosed { connectionID in
            await glow.endExternalActivities(owner: connectionID)
        }
    }
}
