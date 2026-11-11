import Foundation

@main struct AgentCLITests {
    static func main() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("revault-test-" + UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func fake(_ name: String, _ body: String) throws -> String {
            let p = dir.appendingPathComponent(name)
            try ("#!/bin/sh\n" + body).write(to: p, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: p.path)
            return p.path
        }
        let claude = try fake("claude", """
        [ -z "$ANTHROPIC_API_KEY$OPENAI_API_KEY$CODEX_API_KEY" ] || exit 8
        case "$*" in *sensitive*) exit 9;; esac
        input=$(cat)
        [ "$input" = "sensitive task" ] || exit 10
        printf '%s' '{"result":"draft ready","is_error":false}'
        """)
        let answer = try await LocalAgentCLI.reply(backend: .claude, path: claude, prompt: "sensitive task")
        precondition(answer == "draft ready")
        let codex = try fake("codex", """
        dest=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "--output-last-message" ]; then shift; dest="$1"; fi
          shift
        done
        cat >/dev/null
        # More than a pipe buffer: must not deadlock.
        dd if=/dev/zero bs=1024 count=128 2>/dev/null
        dd if=/dev/zero bs=1024 count=128 1>&2 2>/dev/null
        printf 'codex draft' > "$dest"
        """)
        let second = try await LocalAgentCLI.reply(backend: .codex, path: codex, prompt: "test")
        precondition(second == "codex draft")
        let failure = try fake("failed", "exit 42")
        do {
            _ = try await LocalAgentCLI.reply(backend: .claude, path: failure, prompt: "x")
            fatalError("Nonzero exit accepted")
        } catch { precondition(error.localizedDescription.contains("42")) }
        let refusal = try fake("refusal", "printf '%s' '{\"is_error\":true,\"result\":\"Login required\"}'")
        do {
            _ = try await LocalAgentCLI.reply(backend: .claude, path: refusal, prompt: "x")
            fatalError("Error response accepted")
        } catch { precondition(error.localizedDescription.contains("Login required")) }
        let empty = try fake("empty", "printf '%s' '{\"result\":\"\"}'")
        do {
            _ = try await LocalAgentCLI.reply(backend: .claude, path: empty, prompt: "x")
            fatalError("Empty response accepted")
        } catch { precondition(error.localizedDescription.contains("empty")) }
        let slow = try fake("slow", "exec /bin/sleep 30")
        let start = Date()
        do {
            _ = try await LocalAgentCLI.reply(backend: .claude, path: slow, prompt: "x", timeout: 0.15)
            fatalError("Timeout did not fire")
        } catch { precondition(error.localizedDescription.contains("timed out")) }
        precondition(Date().timeIntervalSince(start) < 5)
        let task = Task { try await LocalAgentCLI.reply(backend: .claude, path: slow, prompt: "x") }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; fatalError("Cancellation ignored") }
        catch { precondition(error is CancellationError) }
        print("PASS: Claude and Codex adapters, stdin privacy, large output, failures, empty results, timeout, cancellation")
    }
}
