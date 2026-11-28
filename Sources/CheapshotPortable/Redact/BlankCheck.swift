// Swift. BlankCheck (CHE-57): is a decoded image uniform? Blank is the one outcome that writes on
// zero OCR evidence, so it means "every pixel is the same colour, give or take sensor noise", not
// "few pixels differ". A ratio would call a 4K capture with one short secret line blank (plan
// section 7 item 1). Foundation only: this file must compile on Windows.
import Foundation

public enum BlankCheck {
    /// How far any channel may differ from the first pixel and still count as the same colour.
    public static let tolerance: UInt8 = 2

    /// True only when every pixel is within `tolerance` of the first pixel on all four channels.
    /// False for empty input, zero sizes, or when `rgba.count != width * height * 4`
    /// (computed with multipliedReportingOverflow). Returns at the first pixel that differs.
    public static func isBlank(rgba: [UInt8], width: Int, height: Int,
                               tolerance: UInt8 = BlankCheck.tolerance) -> Bool {
        guard width > 0, height > 0 else { return false }
        // width * height * 4 without trapping: a size that overflows cannot describe a real buffer.
        let (pixels, overflow1) = width.multipliedReportingOverflow(by: height)
        guard !overflow1 else { return false }
        let (bytes, overflow2) = pixels.multipliedReportingOverflow(by: 4)
        guard !overflow2, bytes == rgba.count else { return false }

        // Compare in Int so the subtraction cannot wrap around the way UInt8 math would.
        let limit = Int(tolerance)
        return rgba.withUnsafeBufferPointer { buf -> Bool in
            let r = Int(buf[0]), g = Int(buf[1]), b = Int(buf[2]), a = Int(buf[3])
            var i = 4
            while i < bytes {
                if abs(Int(buf[i]) - r) > limit || abs(Int(buf[i + 1]) - g) > limit
                    || abs(Int(buf[i + 2]) - b) > limit || abs(Int(buf[i + 3]) - a) > limit {
                    return false
                }
                i += 4
            }
            return true
        }
    }
}
