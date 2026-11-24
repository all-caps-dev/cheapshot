// Swift script for scripts/check-mask.sh: numeric pixel checks on a masked copy, so nobody has to
// look at the image. Usage:
//   swift scripts/mask-sample.swift <original.png> <masked.png> black   x0 y0 x1 y1
//   swift scripts/mask-sample.swift <original.png> <masked.png> changed x0 y0 x1 y1
// "black" prints the fraction of pixels in the box (top-left pixel coords) that are opaque black
// in the masked copy; "changed" prints how many pixels in the box differ from the original.
// Both also check the two images have the same pixel size, exit 1 if not.
import Foundation
import CoreGraphics
import ImageIO

func rgba(_ path: String) -> (w: Int, h: Int, px: [UInt8]) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8)); exit(1)
    }
    var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
    let ctx = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8,
                        bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return (img.width, img.height, buf)   // rows run top to bottom, like the bboxes
}

let a = CommandLine.arguments
guard a.count == 8, let x0 = Int(a[4]), let y0 = Int(a[5]), let x1 = Int(a[6]), let y1 = Int(a[7]) else {
    FileHandle.standardError.write(Data("usage: mask-sample.swift <orig> <masked> black|changed x0 y0 x1 y1\n".utf8)); exit(2)
}
let o = rgba(a[1]), m = rgba(a[2])
guard o.w == m.w, o.h == m.h else { print("size mismatch \(o.w)x\(o.h) vs \(m.w)x\(m.h)"); exit(1) }
var black = 0, changed = 0, total = 0
for y in max(0, y0)..<min(m.h, y1) { for x in max(0, x0)..<min(m.w, x1) {
    let i = (y * m.w + x) * 4
    total += 1
    if m.px[i] == 0, m.px[i + 1] == 0, m.px[i + 2] == 0, m.px[i + 3] == 255 { black += 1 }
    if m.px[i] != o.px[i] || m.px[i + 1] != o.px[i + 1] || m.px[i + 2] != o.px[i + 2] { changed += 1 }
} }
print(a[3] == "black" ? String(format: "%.4f", total == 0 ? 0 : Double(black) / Double(total)) : "\(changed)")
