import AppKit
import SwiftUI

extension NSScreen {
    /// Real physical camera-notch size in points, from public APIs only — mirrors
    /// DynamicNotchKit's own internal (non-importable) NSScreen.notchSize.
    /// nil on displays with no physical notch (external monitors, non-notch Macs).
    var realNotchSize: CGSize? {
        guard let left = auxiliaryTopLeftArea?.width, let right = auxiliaryTopRightArea?.width else {
            return nil
        }
        return CGSize(width: frame.width - left - right, height: safeAreaInsets.top)
    }
}

/// Shared constants for the notch panel's surfaces. Not a design system — just enough to
/// keep these values in one place instead of duplicated across views. The panel's glass is
/// now rendered by the (vendored, patched) DynamicNotchKit via `.glassEffect`, so there's no
/// app-side material/tint/vignette here anymore.
enum DesignTokens {
    static let cardCornerRadius: CGFloat = 14
    /// Card fill on the glass panel. Kept a solid dark tone (not more glass) so a card reads as
    /// a distinct layer — never stack translucency on translucency.
    static let elevatedSurface = Color(white: 0.16)
    /// Fill for surfaces nested one level deeper (e.g. a diff box inside a card).
    static let insetSurface = Color(white: 0.08)
    /// Expanded-panel corner radii — bottom noticeably rounder than top.
    static let expandedTopCornerRadius: CGFloat = 22
    static let expandedBottomCornerRadius: CGFloat = 42
    /// Panel width: a modest multiple of the real notch width (not a screen fraction),
    /// so it stays correctly proportioned across Macs with different notch sizes.
    static var panelWidth: CGFloat {
        (NSScreen.screens.first?.realNotchSize?.width).map { $0 * 1.9 } ?? 340
    }
}
