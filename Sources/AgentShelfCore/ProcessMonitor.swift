import Foundation

/// A detected running agent process. `cwd` is the process's working directory (its folder row).
public struct MonitorHit: Sendable, Equatable {
    public let source: AgentSource
    public let pid: Int
    public let cwd: String
    public init(source: AgentSource, pid: Int, cwd: String) {
        self.source = source; self.pid = pid; self.cwd = cwd
    }
    /// Synthetic session id for a process-detected row, distinct from any hook session id.
    public var sessionId: String { "proc:\(source.rawValue):\(pid)" }
}

/// Detects the ~24 monitor-tier agents that have no hook: one `ps` sweep matches every
/// registry `processMatch` token, then `lsof` resolves each match's cwd. Hook-tier agents
/// (Claude Code) also match here, but the reconcile in SessionStore lets their richer
/// hook-fed row win, so a process row never double-counts them.
public enum ProcessMonitor {
    /// Full scan: list processes, match against the registry, resolve each match's cwd.
    /// Nonisolated + spawns subprocesses, so callers run it off the main actor.
    public static func scan() -> [MonitorHit] {
        guard let ps = runCapture("/bin/ps", ["-axww", "-o", "pid=,command="]) else { return [] }
        var seen = Set<Int>()
        var hits: [MonitorHit] = []
        for (source, pid) in parse(psOutput: ps) where seen.insert(pid).inserted {
            guard let cwd = cwd(pid: pid) else { continue }   // no cwd -> nothing useful to show
            hits.append(MonitorHit(source: source, pid: pid, cwd: cwd))
        }
        return hits
    }

    /// Pure: map `ps -o pid=,command=` output to (source, pid) pairs. First matching agent wins
    /// per pid. Split out so matching is unit-testable without spawning anything.
    static func parse(psOutput: String) -> [(source: AgentSource, pid: Int)] {
        var out: [(AgentSource, Int)] = []
        for line in psOutput.split(separator: "\n") {
            let trimmed = line.drop { $0 == " " }
            guard let sp = trimmed.firstIndex(of: " "),
                  let pid = Int(trimmed[..<sp]) else { continue }
            let command = String(trimmed[trimmed.index(after: sp)...])
            for agent in AgentRegistry.all
            where agent.processMatch.contains(where: { matches(command: command, token: $0) }) {
                out.append((agent.source, pid))
                break   // one source per pid
            }
        }
        return out
    }

    /// True if `token` appears in `command` on a path/word boundary — so "/usr/bin/amp" and
    /// "node /x/amp/cli.js" match "amp", but "example" and "claude-code" don't match "claude".
    static func matches(command: String, token: String) -> Bool {
        guard !token.isEmpty else { return false }
        let chars = Array(command)
        let tok = Array(token)
        let boundary: (Character) -> Bool = { $0 == "/" || $0 == " " || $0 == "\t" || $0 == "\n" }
        var i = 0
        while i + tok.count <= chars.count {
            if Array(chars[i..<i + tok.count]) == tok {
                let leftOK = i == 0 || boundary(chars[i - 1])
                let rightIdx = i + tok.count
                let rightOK = rightIdx == chars.count || boundary(chars[rightIdx])
                if leftOK && rightOK { return true }
            }
            i += 1
        }
        return false
    }

    /// Working directory of a pid via lsof (kernel-canonical form, matching TerminalInjector).
    static func cwd(pid: Int) -> String? {
        guard let out = runCapture("/usr/sbin/lsof", ["-a", "-p", "\(pid)", "-d", "cwd", "-Fn"]) else { return nil }
        return out.split(separator: "\n").first { $0.hasPrefix("n") }.map { String($0.dropFirst()) }
    }

    /// True if ANY registry agent process is running — the reaper's blind-reap guard.
    public static func anyAgentRunning() -> Bool {
        guard let ps = runCapture("/bin/ps", ["-axww", "-o", "pid=,command="]) else { return true }
        return !parse(psOutput: ps).isEmpty
    }

    private static func runCapture(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
