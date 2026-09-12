import Foundation

public enum Tokens {
    /// Anthropic's rule of thumb, (w * h) / 750, after the long-edge downscale to 1568 px.
    public static func image(width: Int, height: Int) -> Int {
        guard width > 0, height > 0 else { return 0 }
        var fw = Double(width), fh = Double(height)
        let maxEdge = 1568.0
        if max(fw, fh) > maxEdge { let s = maxEdge / max(fw, fh); fw *= s; fh *= s }
        return Int((fw * fh / 750.0).rounded())
    }

    /// About four characters per token, never zero.
    public static func text(_ s: String) -> Int { max(1, Int((Double(s.count) / 4.0).rounded())) }
}
