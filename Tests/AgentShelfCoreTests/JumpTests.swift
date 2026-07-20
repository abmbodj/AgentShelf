import Testing
@testable import AgentShelfCore

@Test func openArgsAreCorrect() {
    #expect(EditorJump(appName: "Cursor").openArgs(cwd: "/Users/ab/repo")
            == ["-a", "Cursor", "/Users/ab/repo"])
}

@Test func preferredEditorsDefaultToCursorThenVSCode() {
    #expect(JumpService.preferred.map(\.appName) == ["Cursor", "Visual Studio Code"])
}
