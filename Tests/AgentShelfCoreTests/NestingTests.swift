import Testing
@testable import AgentShelfCore

private func s(_ id: String, parent: String? = nil) -> Session {
    Session(id: id, source: .claudeCode, cwd: "/repo", status: .running, parentId: parent)
}

@Test func subagentsNestUnderTheirParent() {
    // Insertion order interleaves two sessions and a child; nesting pulls the child up under A.
    let ordered = Session.nested([s("A"), s("B"), s("a1", parent: "A")])
    #expect(ordered.map(\.id) == ["A", "a1", "B"])
    #expect(ordered[1].isSubagent)
}

@Test func orphanSubagentStaysTopLevel() {
    // Parent pruned away: the child must still be shown, not dropped.
    let ordered = Session.nested([s("B"), s("x1", parent: "gone")])
    #expect(ordered.map(\.id) == ["B", "x1"])
}
