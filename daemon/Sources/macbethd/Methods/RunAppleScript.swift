import Foundation
import OSAKit

/// Register the run_applescript RPC method.
func registerRunAppleScript(dispatcher: Dispatcher, glow: GlowIndicator) {
    Task {
        await dispatcher.register(method: "run_applescript") { params in
            guard let obj = params?.objectValue,
                  let source = obj["source"]?.stringValue else {
                throw RPCError.invalidParams("Missing 'source'")
            }

            let languageParam = obj["language"]?.stringValue ?? "AppleScript"
            let isInteractive = obj["interactive"]?.boolValue ?? true

            // Callers can classify inspection-only scripts so they do not show
            // an interaction indicator. Default stays interactive for backward
            // compatibility because arbitrary AppleScript/JXA can drive input.
            if isInteractive { await glow.activityStarted() }
            defer {
                if isInteractive { Task { await glow.activityEnded() } }
            }

            let result: (String?, String?, Int?) = await MainActor.run {
                let lang: OSALanguage?
                switch languageParam.lowercased() {
                case "javascript", "jxa":
                    lang = OSALanguage(forName: "JavaScript")
                default:
                    lang = OSALanguage(forName: "AppleScript")
                }

                guard let lang else {
                    return (nil, "Language not available: \(languageParam)", nil)
                }

                let script = OSAScript(source: source, language: lang)
                var errorDict: NSDictionary?
                let output = script.executeAndReturnError(&errorDict)

                if let errorDict = errorDict {
                    let message = (errorDict[NSAppleScript.errorMessage] as? String)
                        ?? (errorDict["OSAScriptErrorMessageKey"] as? String)
                        ?? "Script execution failed"
                    let errorNumber = (errorDict[NSAppleScript.errorNumber] as? Int)
                        ?? (errorDict["OSAScriptErrorNumberKey"] as? Int)
                    return (nil, message, errorNumber)
                }

                return (output?.stringValue ?? "", nil, nil)
            }

            if let error = result.1 {
                throw classifyScriptError(message: error, errorNumber: result.2)
            }

            return .object(["output": .string(result.0 ?? "")])
        }
    }
}

private func classifyScriptError(message: String, errorNumber: Int?) -> RPCError {
    switch errorNumber {
    case -1728:
        return .menuItemNotFound(message)
    case -1719:
        return .menuItemDisabled(message)
    case -600, -609:
        return .appBusy(message)
    default:
        var data: [String: JSONValue] = [:]
        if let num = errorNumber {
            data["osaErrorNumber"] = .number(Double(num))
        }
        return .scriptFailed(message, data: data.isEmpty ? nil : .object(data))
    }
}
