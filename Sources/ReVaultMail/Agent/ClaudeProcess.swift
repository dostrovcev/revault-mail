import Foundation

/// Compatibility entry point for translation and composer helpers.
enum ClaudeProcess {
    @MainActor
    static func oneShot(prompt: String, model: String = "") async throws -> String {
        let s = AppSettings.shared
        let backend = LocalAgentCLI.Backend(rawValue: s.agentProvider) ?? .claude
        return try await LocalAgentCLI.reply(backend: backend,
            path: backend == .claude ? s.claudePath : s.codexPath,
            model: s.agentModel, prompt: prompt)
    }
}
