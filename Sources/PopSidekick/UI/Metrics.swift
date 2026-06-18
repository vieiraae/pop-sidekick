import Foundation
import CoreGraphics

/// Centralized layout constants for the popup UI, replacing scattered magic
/// numbers so spacing/sizing stays consistent and is easy to tune.
enum Metrics {
    /// Outer padding around the popup card (space for the shadow + animated border).
    static let popupInset: CGFloat = 8
    /// Gap between the selection and the popup.
    static let selectionGap: CGFloat = 6
    /// Corner radius for the compact bar and the expanded editor.
    static let compactCornerRadius: CGFloat = 12
    static let editCornerRadius: CGFloat = 16
    /// Fixed width of the expanded editor.
    static let editWidth: CGFloat = 391
    /// Width of the compact "Ask Copilot" prompt bar.
    static let promptWidth: CGFloat = 320
    /// Settings window size.
    static let settingsWidth: CGFloat = 540
    static let settingsHeight: CGFloat = 460
    /// Minimum width for the processing bar so it never collapses before the
    /// action bar's natural size has been measured.
    static let processingMinWidth: CGFloat = 200
    /// Delay before re-clamping the window after an expand/collapse animation.
    static let reflowDelay: TimeInterval = 0.38
}
