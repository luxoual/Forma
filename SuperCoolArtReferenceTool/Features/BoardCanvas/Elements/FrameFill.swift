import SwiftUI

/// Background color for frames the user hasn't colored yet.
///
/// A frame should read as a slightly different surface from the canvas
/// around it, not a hard block. So the default is the canvas color itself,
/// nudged a little toward contrast: darker on a light canvas, lighter on a
/// dark one. Because unpicked frames store no color (`PlacedFrame.fillHex ==
/// nil`), they follow the canvas if the user changes it later.
enum FrameFill {
    /// How far to blend toward black on a light canvas. Light surfaces show
    /// small darkening clearly, so this stays subtle.
    static let lightCanvasShift: Float = 0.06
    /// How far to blend toward white on a dark canvas. Dark surfaces hide
    /// small changes, so this needs a bit more.
    static let darkCanvasShift: Float = 0.10

    static func defaultHex(onCanvas background: Color.Resolved) -> String {
        // Same W3C relative-luminance crossover TextColorMemory uses to
        // decide whether a canvas counts as light or dark.
        let luminance = 0.2126 * Double(background.linearRed)
            + 0.7152 * Double(background.linearGreen)
            + 0.0722 * Double(background.linearBlue)
        let isLight = luminance > 0.179
        let target: Float = isLight ? 0 : 1
        let amount = isLight ? lightCanvasShift : darkCanvasShift
        func blend(_ c: Float) -> Float { c + (target - c) * amount }
        let shifted = Color.Resolved(
            red: blend(background.red),
            green: blend(background.green),
            blue: blend(background.blue)
        )
        return canvasColorHexString(from: shifted)
    }
}
