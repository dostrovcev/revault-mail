import Foundation
import Observation

@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    var agentProvider: String { didSet { d.set(agentProvider, forKey: "agentProvider") } }
    var codexPath: String { didSet { d.set(codexPath, forKey: "codexPath") } }
    var claudePath: String { didSet { d.set(claudePath, forKey: "claudePath") } }
    var agentWorkdir: String { didSet { d.set(agentWorkdir, forKey: "agentWorkdir") } }
    var agentModel: String { didSet { d.set(agentModel, forKey: "agentModel") } }
    var agentEffort: String { didSet { d.set(agentEffort, forKey: "agentEffort") } }
    var permissionMode: String { didSet { d.set(permissionMode, forKey: "permissionMode") } }
    var translateTarget: String { didSet { d.set(translateTarget, forKey: "translateTarget") } }
    var threadViewMode: String { didSet { d.set(threadViewMode, forKey: "threadViewMode") } }   // auto | chat | mail
    var showAgentPanel: Bool { didSet { d.set(showAgentPanel, forKey: "showAgentPanelV3") } }

    static let models: [(id: String, title: String)] = [("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
    static let efforts = ["low", "medium", "high", "xhigh", "max"]
    /// Локальный агент читает чужие письма, поэтому режимы только безопасные:
    /// «plan» только читает, «default» в режиме -p отказывает во всём, что требует разрешения.
    static let permissionModes: [(id: String, title: String)] = [
        ("plan", "Read only (recommended)"),
        ("default", "Ask: tools that need approval are refused"),
    ]

    /// Режим прав для запуска: всё, чего нет в списке безопасных (auto, acceptEdits, bypassPermissions), становится plan.
    var safePermissionMode: String {
        Self.permissionModes.contains { $0.id == permissionMode } ? permissionMode : "plan"
    }
    static let languages = ["Russian", "English", "German", "Spanish", "French", "Ukrainian"]

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.claude/local/claude"]
        let detected = candidates.first { FileManager.default.isExecutableFile(atPath: $0) } ?? candidates[0]
        let workdir = AppPaths.support.path
        agentProvider = d.string(forKey: "agentProvider") ?? "claude"
        codexPath = d.string(forKey: "codexPath") ?? (LocalAgentCLI.find(.codex) ?? "")

        claudePath = d.string(forKey: "claudePath") ?? detected
        agentWorkdir = d.string(forKey: "agentWorkdir") ?? workdir
        agentModel = d.string(forKey: "agentModel") ?? ""
        agentEffort = d.string(forKey: "agentEffort") ?? "medium"
        let storedMode = d.string(forKey: "permissionMode") ?? "plan"
        permissionMode = Self.permissionModes.contains { $0.id == storedMode } ? storedMode : "plan"
        translateTarget = d.string(forKey: "translateTarget") ?? "English"
        threadViewMode = d.string(forKey: "threadViewMode") ?? "auto"
        showAgentPanel = d.object(forKey: "showAgentPanelV3") as? Bool ?? true
    }
}
