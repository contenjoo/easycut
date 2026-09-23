import AppKit
import SwiftUI

enum Theme {
    static func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> NSColor {
        NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }

    static let timelineBG = c(30, 31, 36)
    static let rowA = c(38, 40, 46)
    static let rowB = c(34, 36, 42)
    static let captionRow = c(44, 38, 52)
    static let header = c(26, 27, 31)
    static let gridLine = c(20, 21, 25)
    static let ruler = c(22, 23, 27)
    static let rulerText = c(170, 172, 180)
    static let rulerTick = c(90, 92, 100)
    static let playhead = c(255, 69, 58)
    static let accent = c(64, 156, 255)
    static let handle = c(255, 214, 10)
    static let markRange = c(64, 156, 255, 0.16)

    static let videoClip = c(47, 111, 194)
    static let audioClip = c(38, 145, 96)
    static let imageClip = c(137, 84, 196)
    static let textClip = c(214, 124, 36)
    static let captionClip = c(160, 92, 190)
    static let captionClipSel = c(196, 120, 230)

    static let accentColor = Color(nsColor: accent)
    static let panelBG = Color(nsColor: c(28, 29, 33))
}
