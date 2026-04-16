import Foundation
import OSAKit

/// Register the run_applescript RPC method.
func registerRunAppleScript(dispatcher: Dispatcher) {
    Task {
        await dispatcher.register(method: "run_applescript") { params in
            guard let obj = params?.objectValue,
                  let source = obj["source"]?.stringValue else {
                throw RPCError.invalidParams("Missing 'source'")
            }

            let languageParam = obj["language"]?.stringValue ?? "AppleScript"

            let result: (String?, String?) = await MainActor.run {
                let lang: OSALanguage?
                switch languageParam.lowercased() {
                case "javascript", "jxa":
                    lang = OSALanguage(forName: "JavaScript")
                default:
                    lang = OSALanguage(forName: "AppleScript")
                }

                guard let lang else {
                    return (nil, "Language not available: \(languageParam)")
                }

                let script = OSAScript(source: source, language: lang)
                var errorDict: NSDictionary?
                let output = script.executeAndReturnError(&errorDict)

                if let errorDict = errorDict {
                    let message = errorDict[NSAppleScript.errorMessage] as? String
                        ?? "Script execution failed"
                    return (nil, message)
                }

                return (output?.stringValue ?? "", nil)
            }

            if let error = result.1 {
                throw RPCError.actionFailed(error)
            }

            return .object(["output": .string(result.0 ?? "")])
        }
    }
}
