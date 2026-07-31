@preconcurrency import Foundation

/// Register the run_applescript RPC method.
///
/// Scripts run in a separate `/usr/bin/osascript` process so a deadline can stop
/// Apple Events that are blocked on System Events, a permission dialog, or a hung app.
func registerRunAppleScript(dispatcher: Dispatcher, glow: GlowIndicator) {
    Task {
        await dispatcher.register(method: "run_applescript") { params in
            guard let obj = params?.objectValue,
                  let source = obj["source"]?.stringValue else {
                throw RPCError.invalidParams("Missing 'source'")
            }

            let languageParam = obj["language"]?.stringValue ?? "AppleScript"
            let isInteractive = obj["interactive"]?.boolValue ?? true
            let timeoutMs = ScriptTimeout.clamp(obj["timeoutMs"]?.intValue)

            if isInteractive { await glow.activityStarted() }
            defer {
                if isInteractive { Task { await glow.activityEnded() } }
            }

            let started = ContinuousClock.now
            let result = try await executeOSAScript(
                source: source,
                language: languageParam,
                timeoutMs: timeoutMs
            )
            let elapsed = started.duration(to: ContinuousClock.now)
            let durationMs = Int(elapsed.components.seconds * 1_000)
                + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)

            if result.timedOut {
                throw RPCError.timeout(
                    "OSA script execution timed out after \(timeoutMs)ms and was stopped "
                    + "(phase: execution, language: \(languageParam)). Only this call failed; "
                    + "pass a larger timeoutMs (max \(ScriptTimeout.maxMs)ms) for longer work."
                )
            }
            if result.status != 0 {
                throw classifyScriptError(
                    message: result.error.isEmpty ? "Script execution failed" : result.error,
                    errorNumber: osaErrorNumber(in: result.error),
                    language: languageParam,
                    durationMs: durationMs
                )
            }

            return .object(["output": .string(result.output)])
        }
    }
}

private struct ScriptExecutionResult: Sendable {
    let output: String
    let error: String
    let status: Int32
    let timedOut: Bool
}

private final class ScriptProcessBox: @unchecked Sendable {
    let process = Process()
}

private func executeOSAScript(
    source: String,
    language: String,
    timeoutMs: Int
) async throws -> ScriptExecutionResult {
    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
        .appendingPathComponent("macbeth-osa-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    defer { try? fileManager.removeItem(at: directory) }

    let scriptURL = directory.appendingPathComponent("script.txt")
    let outputURL = directory.appendingPathComponent("stdout.txt")
    let errorURL = directory.appendingPathComponent("stderr.txt")
    try Data(source.utf8).write(to: scriptURL, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: scriptURL.path)
    fileManager.createFile(atPath: outputURL.path, contents: nil)
    fileManager.createFile(atPath: errorURL.path, contents: nil)

    let outputHandle = try FileHandle(forWritingTo: outputURL)
    let errorHandle = try FileHandle(forWritingTo: errorURL)
    defer {
        try? outputHandle.close()
        try? errorHandle.close()
    }

    let box = ScriptProcessBox()
    let exitSignal = ScriptExitSignal()
    box.process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    let languageArg = language.lowercased() == "javascript" || language.lowercased() == "jxa"
        ? "JavaScript"
        : "AppleScript"
    box.process.arguments = ["-l", languageArg, scriptURL.path]
    box.process.standardOutput = outputHandle
    box.process.standardError = errorHandle
    // Install before run() so a fast-exit child cannot miss the handler.
    box.process.terminationHandler = { _ in
        exitSignal.signal()
    }

    do {
        try box.process.run()
    } catch {
        throw RPCError.scriptFailed(
            "Could not launch /usr/bin/osascript: \(error.localizedDescription)",
            data: .object([
                "phase": .string("launch"),
                "language": .string(languageArg),
            ])
        )
    }

    // Cover the race where the process exits between run() and handler delivery.
    if !box.process.isRunning {
        exitSignal.signal()
    }

    let deadline = ContinuousClock.now + .milliseconds(timeoutMs)
    let exitedInTime = await waitForScriptProcess(exitSignal: exitSignal, until: deadline)

    var timedOut = false
    if !exitedInTime, box.process.isRunning {
        timedOut = true
        // Escalate on bounded waits rather than blocking on waitUntilExit(): a
        // script wedged in an Apple Event must not hold this request — or a
        // thread — open past its deadline.
        box.process.terminate()
        let stopped = await waitForScriptProcess(
            exitSignal: exitSignal,
            until: ContinuousClock.now + .milliseconds(ScriptTimeout.terminateGraceMs)
        )
        if !stopped, box.process.isRunning {
            kill(box.process.processIdentifier, SIGKILL)
            await waitForScriptProcess(
                exitSignal: exitSignal,
                until: ContinuousClock.now + .milliseconds(ScriptTimeout.reapGraceMs)
            )
        }
    }

    try? outputHandle.synchronize()
    try? errorHandle.synchronize()
    let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
    let error = (try? String(contentsOf: errorURL, encoding: .utf8)) ?? ""
    // terminationStatus is only defined once the child has actually exited.
    let reaped = !box.process.isRunning
    return ScriptExecutionResult(
        output: output.trimmingCharacters(in: .newlines),
        error: error.trimmingCharacters(in: .whitespacesAndNewlines),
        status: reaped ? box.process.terminationStatus : -1,
        timedOut: timedOut
    )
}

private func osaErrorNumber(in message: String) -> Int? {
    guard let regex = try? NSRegularExpression(pattern: #"\((-?\d+)\)\s*$"#) else {
        return nil
    }
    let range = NSRange(message.startIndex..<message.endIndex, in: message)
    guard let match = regex.firstMatch(in: message, range: range),
          let numberRange = Range(match.range(at: 1), in: message) else {
        return nil
    }
    return Int(message[numberRange])
}

private func classifyScriptError(
    message: String,
    errorNumber: Int?,
    language: String,
    durationMs: Int
) -> RPCError {
    let data: JSONValue = .object([
        "phase": .string("execution"),
        "language": .string(language),
        "durationMs": .number(Double(durationMs)),
        "osaErrorNumber": errorNumber.map { .number(Double($0)) } ?? .null,
    ])
    switch errorNumber {
    case -1743, -10004:
        return .permissionDenied(
            "Apple Events automation was denied. Grant the host application access "
            + "in System Settings → Privacy & Security → Automation. \(message)"
        )
    case -1728:
        return .menuItemNotFound(message)
    case -1719:
        return .menuItemDisabled(message)
    case -1712:
        return .timeout(
            "Apple Event timed out (OSA error -1712, phase: execution, "
            + "language: \(language), duration: \(durationMs)ms): \(message)"
        )
    case -600, -609:
        return .appBusy(message)
    default:
        return .scriptFailed(message, data: data)
    }
}
