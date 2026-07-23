import Foundation

/// Integration tier for an agent — how much of it we can surface.
///   .fullApproval — has a blocking hook we can install; approve/deny in the notch (Claude Code).
///   .richMonitor  — no hook, but writes a session log we can tail for folder + activity.
///   .presence     — detected only as a running process (running/idle + folder from its cwd).
public enum AgentTier: Sendable, Equatable {
    case fullApproval
    case richMonitor
    case presence
}

/// Where a .richMonitor agent writes its session log. `dir` is relative to the home directory;
/// the newest matching file is tailed for the last tool/file. Best-effort and fail-safe: a wrong
/// dir just means no activity label — process detection still shows the session (idle until the
/// log is freshly written, then running).
public struct LogSource: Sendable, Equatable {
    public let dir: String   // e.g. ".codex/sessions"
    public let ext: String   // "jsonl" | "json"
    public init(dir: String, ext: String = "jsonl") { self.dir = dir; self.ext = ext }
}

/// One agent's integration metadata. The registry is the single source of truth — adding or
/// tuning an agent is a row edit here, not scattered switch arms.
public struct AgentIntegration: Sendable {
    public let source: AgentSource
    public let displayName: String
    /// Executable/command tokens to match in a process's full command line, on a path/word
    /// boundary (see ProcessMonitor.matches). Keep specific to avoid phantom rows.
    public let processMatch: [String]
    public let tier: AgentTier
    public let logSource: LogSource?
}

public enum AgentRegistry {
    /// The 26 agents AgentShelf surfaces. Tiers are honest: only Claude Code has a real blocking
    /// hook today, so it's the only .fullApproval. A handful with a known session-log dir are
    /// .richMonitor; the rest are .presence (still detected, just running/idle + folder). Any
    /// row can be promoted later with no schema change.
    // ponytail: processMatch tokens and richMonitor log dirs for the long-tail agents are
    // best-effort and mostly unverified against real installs (several tools are obscure/regional).
    // The design fails safe — an unmatched agent simply never appears, a wrong log dir just drops
    // the activity label. Tighten a token or promote a tier when a real install is available.
    public static let all: [AgentIntegration] = [
        AgentIntegration(source: .claudeCode, displayName: "claude", processMatch: ["claude"],
                         tier: .fullApproval, logSource: nil),
        AgentIntegration(source: .codex, displayName: "codex", processMatch: ["codex"],
                         tier: .richMonitor, logSource: LogSource(dir: ".codex/sessions", ext: "jsonl")),
        AgentIntegration(source: .zcode, displayName: "zcode", processMatch: ["zcode", "z-code"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .geminiCLI, displayName: "gemini", processMatch: ["gemini"],
                         tier: .richMonitor, logSource: LogSource(dir: ".gemini/tmp", ext: "json")),
        AgentIntegration(source: .antigravityCLI, displayName: "antigravity", processMatch: ["antigravity"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .cursor, displayName: "cursor", processMatch: ["cursor-agent"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .trae, displayName: "trae", processMatch: ["trae"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .openCode, displayName: "opencode", processMatch: ["opencode"],
                         tier: .richMonitor, logSource: LogSource(dir: ".local/share/opencode/storage/session", ext: "json")),
        AgentIntegration(source: .mimoCode, displayName: "mimo", processMatch: ["mimo", "mimo-code"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .droid, displayName: "droid", processMatch: ["droid"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .qoder, displayName: "qoder", processMatch: ["qoder"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .qwen, displayName: "qwen", processMatch: ["qwen"],
                         tier: .richMonitor, logSource: LogSource(dir: ".qwen/tmp", ext: "json")),
        AgentIntegration(source: .grokBuild, displayName: "grok", processMatch: ["grok"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .kimiCode, displayName: "kimi-code", processMatch: ["kimi-code"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .deepSeek, displayName: "deepseek", processMatch: ["deepseek"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .mistralVibe, displayName: "mistral", processMatch: ["mistral-vibe"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .copilot, displayName: "copilot", processMatch: ["copilot"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .codeBuddy, displayName: "codebuddy", processMatch: ["codebuddy"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .workBuddy, displayName: "workbuddy", processMatch: ["workbuddy"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .kiro, displayName: "kiro", processMatch: ["kiro"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .hermes, displayName: "hermes", processMatch: ["hermes-cli"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .amp, displayName: "amp", processMatch: ["amp"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .piAgent, displayName: "pi", processMatch: ["pi-agent"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .ohMyPi, displayName: "oh-my-pi", processMatch: ["oh-my-pi", "ohmypi"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .gajaeCode, displayName: "gajae", processMatch: ["gajae", "gajae-code"],
                         tier: .presence, logSource: nil),
        AgentIntegration(source: .kimi, displayName: "kimi", processMatch: ["kimi-cli"],
                         tier: .presence, logSource: nil),
    ]

    private static let bySource: [AgentSource: AgentIntegration] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.source, $0) })

    public static func integration(for source: AgentSource) -> AgentIntegration {
        // Every AgentSource has a row; fall back defensively so a lookup can't crash.
        bySource[source] ?? all[0]
    }
}
