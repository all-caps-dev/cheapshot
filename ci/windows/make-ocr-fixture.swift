// Swift script (macOS only). Draws the Windows OCR probe's fixture screenshot: dark text on
// white, two lines, one of them code. Rerun to rebuild the committed PNG:
//   swift ci/windows/make-ocr-fixture.swift ci/windows/ocr-probe/fixture.png
// The probe (Program.cs) looks for the word "cheapshot" in what Windows.Media.Ocr returns.
import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "fixture.png"
let w = 900, h = 220
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

// CoreGraphics puts y = 0 at the bottom, so the first line gets the larger y.
func draw(_ text: String, font: String, size: CGFloat, y: CGFloat) {
    let f = CTFontCreateWithName(font as CFString, size, nil)
    let attrs: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    ctx.textPosition = CGPoint(x: 40, y: y)
    CTLineDraw(line, ctx)
}
draw("cheapshot windows ocr probe", font: "Helvetica", size: 44, y: 130)
draw("let total = price * 42", font: "Menlo", size: 36, y: 50)

let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
guard CGImageDestinationFinalize(dest) else { print("could not write \(out)"); exit(1) }
print("wrote \(out) (\(w)x\(h))")
