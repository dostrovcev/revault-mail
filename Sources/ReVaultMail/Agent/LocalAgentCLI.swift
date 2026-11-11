import Foundation

/// Uses the user's CLI login. Prompts never appear in process arguments.
enum LocalAgentCLI {
    enum Backend: String, CaseIterable, Identifiable {
        case claude, codex
        var id: String { rawValue }
        var title: String { self == .claude ? "Claude Code (your Claude account)" : "Codex (your ChatGPT account)" }
    }
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    static func find(_ backend: Backend, configured: String = "") -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dirs = [home + "/.local/bin", home + "/.npm-global/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return ([configured] + dirs.map { $0 + "/" + backend.rawValue })
            .first { !$0.isEmpty && FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func arguments(_ backend: Backend, model: String, output: String) -> [String] {
        var args: [String]
        switch backend {
        case .claude:
            args = ["-p", "--output-format", "json", "--tools", "", "--strict-mcp-config",
                    "--setting-sources", "", "--no-session-persistence"]
        case .codex:
            args = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--ephemeral",
                    "--ignore-user-config", "-c", "approval_policy=\"never\"",
                    "--output-last-message", output]
        }
        if !model.isEmpty { args += ["--model", model] }
        return args + (backend == .codex ? ["-"] : [])
    }
    static func decode(_ backend: Backend, stdout: Data, final: Data, status: Int32) throws -> String {
        guard status == 0 else { throw Failure(message: "\(backend.rawValue) exited with code \(status). Check its login in Terminal.") }
        var text = ""
        if backend == .claude {
            let obj = try JSONSerialization.jsonObject(with: stdout) as? [String: Any]
            if obj?["is_error"] as? Bool == true { throw Failure(message: obj?["result"] as? String ?? "Claude could not complete the request.") }
            text = obj?["result"] as? String ?? ""
        } else { text = String(decoding: final, as: UTF8.self) }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw Failure(message: "The agent returned an empty answer.") }
        return text
    }
    static func reply(backend: Backend, path: String = "", model: String = "", prompt: String,
                      timeout: TimeInterval = 300) async throws -> String {
        guard let bin = find(backend, configured: path) else {
            throw Failure(message: "Install \(backend.rawValue), sign in in Terminal, then select its path in Settings.")
        }
        let state = RunState()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { cont.resume(returning: try run(bin: bin, backend: backend, model: model, prompt: prompt, timeout: timeout, state: state)) }
                    catch { cont.resume(throwing: error) }
                }
            }
        }, onCancel: { state.cancel() })
    }
    private final class RunState: @unchecked Sendable {
        let lock = NSLock()
        var process: Process?
        var cancelled = false
        func start(_ p: Process) throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw CancellationError() }
            process = p
            try p.run()
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true
            if let p = process, p.isRunning { p.terminate() }
        }
        func check() throws {
            lock.lock(); defer { lock.unlock() }
            if cancelled { throw CancellationError() }
        }
    }
    private static func run(bin: String, backend: Backend, model: String, prompt: String,
                            timeout: TimeInterval, state: RunState) throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("revault-agent-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: dir) }
        func file(_ name: String, _ data: Data = Data()) throws -> URL {
            let u = dir.appendingPathComponent(name)
            guard fm.createFile(atPath: u.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                throw Failure(message: "Cannot create a private temporary file.")
            }
            return u
        }
        let inputURL = try file("input", Data(prompt.utf8)), outURL = try file("stdout"), errURL = try file("stderr")
        let finalURL = try file("answer")
        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: outURL), errors = try FileHandle(forWritingTo: errURL)
        defer { try? input.close(); try? output.close(); try? errors.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = arguments(backend, model: model, output: finalURL.path)
        // No project folder, inherited MCP configuration or repository instructions.
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        for k in ["ANTHROPIC_API_KEY", "OPENAI_API_KEY", "CODEX_API_KEY"] { env.removeValue(forKey: k) }
        env["PATH"] = (bin as NSString).deletingLastPathComponent + ":" + (env["PATH"] ?? "/usr/bin:/bin")
        p.environment = env
        p.standardInput = input; p.standardOutput = output; p.standardError = errors
        try state.start(p)
        let deadline = Date().addingTimeInterval(timeout)
        var stopped: Date?
        var timedOut = false
        while p.isRunning {
            if Date() >= deadline { timedOut = true; state.cancel() }
            do { try state.check() } catch {
                if stopped == nil { stopped = Date() }
                if Date().timeIntervalSince(stopped!) > 2 { kill(p.processIdentifier, SIGKILL) }
            }
            Foundation.Thread.sleep(forTimeInterval: 0.05)
        }
        p.waitUntilExit()
        if timedOut { throw Failure(message: "The agent timed out. Try again or check the CLI in Terminal.") }
        try state.check()
        return try decode(backend, stdout: Data(contentsOf: outURL), final: Data(contentsOf: finalURL), status: p.terminationStatus)
    }
}
