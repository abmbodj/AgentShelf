import Foundation
import AgentShelfCore

// Registered as an agent hook: `agentshelf-hook [source]` (source defaults to claudeCode).
// Reads the agent's raw hook JSON on stdin, forwards a normalized message to the app,
// and for PermissionRequest prints the agent's decision format under an internal deadline.
//
// HARD RULES (verified): stdout is JSON-only, ALWAYS exit 0, hook timeout fails OPEN so
// approval must enforce its own deadline and print nothing on timeout (hands the prompt
// back to the agent's own UI).

func field(_ obj: [String: Any], _ key: String) -> String? { obj[key] as? String }

let args = CommandLine.arguments
let source = AgentSource(rawValue: args.count > 1 ? args[1] : "claudeCode") ?? .claudeCode

let raw = FileHandle.standardInput.readDataToEndOfFile()
let obj = ((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]) ?? [:]

let event = field(obj, "hook_event_name") ?? "Unknown"

// Off-by-default tuning aid: dump raw PermissionRequest payloads so we can confirm/extend
// the non-binary tool denylist against real data. See PermissionClassifier.
if event == "PermissionRequest", ProcessInfo.processInfo.environment["AGENTSHELF_DEBUG_PAYLOAD"] != nil {
    let line = (String(data: raw, encoding: .utf8) ?? "<non-utf8>") + "\n"
    if let fh = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/agentshelf-payloads.log")) {
        fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close()
    } else {
        try? line.data(using: .utf8)?.write(to: URL(fileURLWithPath: "/tmp/agentshelf-payloads.log"))
    }
}
// session_id is the parent's for subagents; agent_id identifies a subagent.
let sessionId = field(obj, "agent_id") ?? field(obj, "session_id") ?? "unknown"
let cwd = field(obj, "cwd") ?? FileManager.default.currentDirectoryPath
let toolName = field(obj, "tool_name")

var toolSummary: String?
if let input = obj["tool_input"] as? [String: Any] {
    if let cmd = input["command"] as? String { toolSummary = cmd }          // Bash
    else if let path = input["file_path"] as? String { toolSummary = path } // Edit/Write
    else if let data = try? JSONSerialization.data(withJSONObject: input) {
        toolSummary = String(data: data, encoding: .utf8)
    }
}

let kind = PermissionClassifier.kind(event: event, toolName: toolName)
let msg = HookMessage(event: event, source: source, sessionId: sessionId, cwd: cwd,
                      toolName: toolName, toolSummary: toolSummary, permissionKind: kind)

// Block ONLY for a binary permission. Non-binary prompts (a choice, not a grant) are sent
// fire-and-forget so Claude's own multi-option prompt drives — the notch just notifies.
let timeout = (kind == .binary) ? (Double(ProcessInfo.processInfo.environment["AGENTSHELF_APPROVAL_TIMEOUT"] ?? "") ?? 60) : 0
let decision = SocketClient.send(msg, to: AgentShelf.socketPath, awaitDecisionTimeout: timeout)

// Only a binary PermissionRequest produces stdout, and only when we got a decision.
if kind == .binary, let decision {
    let reply: [String: Any] = [
        "hookSpecificOutput": [
            "hookEventName": "PermissionRequest",
            "decision": ["behavior": decision.behavior.rawValue],
        ],
    ]
    if let out = try? JSONSerialization.data(withJSONObject: reply) {
        FileHandle.standardOutput.write(out)
    }
}
exit(0)
