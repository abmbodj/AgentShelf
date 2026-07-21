//
// DynamicNotchPanel.swift
// DynamicNotchKit
//
// Created by <Huy D.> on 2024-11-01.
//

import AppKit

final class DynamicNotchPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: style,
            backing: backingStoreType,
            defer: flag
        )
        self.hasShadow = false
        self.backgroundColor = .clear
        self.level = .screenSaver
        self.collectionBehavior = [.canJoinAllSpaces, .stationary]
    }

    // AgentShelf patch: never become key. Liquid Glass renders its bright *active* variant only
    // when the window is key; a click on the default (true) panel made it key and un-dimmed the
    // glass, so it looked different clicked vs. idle. Staying non-key keeps one consistent dimmed
    // look. No input is lost — the panel has no text fields, and mouse clicks still reach Buttons
    // / onTapGesture on a non-activating, non-key panel.
    override var canBecomeKey: Bool {
        false
    }
}
