import Foundation

/// One line of a rendered diff. `lineNumber` follows the new file's numbering — a removed
/// line shows the number of whatever now sits in its place (or would, if it's the last line),
/// matching how compact diff UIs typically number a deletion.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Sendable { case context, added, removed }
    public let kind: Kind
    public let text: String
    public let lineNumber: Int
}

/// Builds a line-level diff via stdlib's CollectionDifference — no custom LCS, no dependency.
public enum LineDiff {
    /// Clamps a diff to `maxLines` centered on the changed region, not the start of the file —
    /// a full-file diff (needed for correct line numbers) can be much longer than fits in a
    /// notch card, and the change is rarely on line 1.
    public static func windowed(_ lines: [DiffLine], maxLines: Int, contextRadius: Int = 3)
        -> (lines: [DiffLine], hiddenBefore: Int, hiddenAfter: Int) {
        guard lines.count > maxLines else { return (lines, 0, 0) }
        guard let first = lines.firstIndex(where: { $0.kind != .context }) else {
            return (Array(lines.prefix(maxLines)), 0, lines.count - maxLines)
        }
        let last = lines.lastIndex(where: { $0.kind != .context }) ?? first
        var start = max(0, first - contextRadius)
        var end = min(lines.count, last + contextRadius + 1)
        if end - start > maxLines {
            end = start + maxLines   // change region itself exceeds maxLines: just clip it
        } else {
            while end - start < maxLines, start > 0 || end < lines.count {
                if start > 0 { start -= 1 }
                if end - start < maxLines, end < lines.count { end += 1 }
            }
        }
        return (Array(lines[start..<end]), start, lines.count - end)
    }

    public static func lines(old: String, new: String) -> [DiffLine] {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")
        let diff = newLines.difference(from: oldLines)

        let removedOffsets = Set(diff.removals.compactMap { change -> Int? in
            if case .remove(let offset, _, _) = change { return offset }
            return nil
        })
        var insertedByOffset: [Int: String] = [:]
        for change in diff.insertions {
            if case .insert(let offset, let element, _) = change { insertedByOffset[offset] = element }
        }

        // Removed lines are checked (and emitted) before insertions at the same position, so a
        // one-line replacement renders as "- old / + new" sharing one line number, not "+ / -".
        var result: [DiffLine] = []
        var oldIndex = 0, newIndex = 0, lineNumber = 1
        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex < oldLines.count, removedOffsets.contains(oldIndex) {
                result.append(DiffLine(kind: .removed, text: oldLines[oldIndex], lineNumber: lineNumber))
                oldIndex += 1
                continue
            }
            if let inserted = insertedByOffset[newIndex] {
                result.append(DiffLine(kind: .added, text: inserted, lineNumber: lineNumber))
                lineNumber += 1
                newIndex += 1
                continue
            }
            guard oldIndex < oldLines.count else { break }
            result.append(DiffLine(kind: .context, text: oldLines[oldIndex], lineNumber: lineNumber))
            oldIndex += 1
            newIndex += 1
            lineNumber += 1
        }
        return result
    }
}
