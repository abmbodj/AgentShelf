import Testing
@testable import AgentShelfCore

@Test func lineDiffSingleLineChange() {
    let lines = LineDiff.lines(old: "line one\nline two\nline three", new: "line one\nline TWO edited\nline three")
    #expect(lines == [
        DiffLine(kind: .context, text: "line one", lineNumber: 1),
        DiffLine(kind: .removed, text: "line two", lineNumber: 2),
        DiffLine(kind: .added, text: "line TWO edited", lineNumber: 2),
        DiffLine(kind: .context, text: "line three", lineNumber: 3),
    ])
}

@Test func lineDiffNewFileIsAllAdded() {
    let lines = LineDiff.lines(old: "", new: "a\nb")
    #expect(lines == [
        DiffLine(kind: .added, text: "a", lineNumber: 1),
        DiffLine(kind: .added, text: "b", lineNumber: 2),
    ])
}

@Test func lineDiffNoChangeIsAllContext() {
    let lines = LineDiff.lines(old: "a\nb", new: "a\nb")
    #expect(lines == [
        DiffLine(kind: .context, text: "a", lineNumber: 1),
        DiffLine(kind: .context, text: "b", lineNumber: 2),
    ])
}

@Test func windowedDiffCentersOnChangeNotFileStart() {
    // A 100-line file with a single change near the end: the window must include the change,
    // not just the first `maxLines` lines from the top of the file.
    let old = (1...100).map { "line \($0)" }.joined(separator: "\n")
    let new = old.replacingOccurrences(of: "line 90", with: "line NINETY")
    let full = LineDiff.lines(old: old, new: new)
    let (windowLines, hiddenBefore, hiddenAfter) = LineDiff.windowed(full, maxLines: 8)
    #expect(windowLines.count == 8)
    #expect(hiddenBefore > 0)
    #expect(windowLines.contains { $0.kind == .removed && $0.text == "line 90" })
    #expect(windowLines.contains { $0.kind == .added && $0.text == "line NINETY" })
    #expect(hiddenBefore + windowLines.count + hiddenAfter == full.count)
}

@Test func windowedDiffNoOpBelowMaxLines() {
    let lines = LineDiff.lines(old: "a\nb", new: "a\nc")
    let (windowLines, hiddenBefore, hiddenAfter) = LineDiff.windowed(lines, maxLines: 8)
    #expect(windowLines == lines)
    #expect(hiddenBefore == 0)
    #expect(hiddenAfter == 0)
}

@Test func lineDiffPureRemoval() {
    let lines = LineDiff.lines(old: "a\nb\nc", new: "a\nc")
    #expect(lines == [
        DiffLine(kind: .context, text: "a", lineNumber: 1),
        DiffLine(kind: .removed, text: "b", lineNumber: 2),
        DiffLine(kind: .context, text: "c", lineNumber: 2),
    ])
}
