import Foundation

public enum Validators {
    /// Luhn check so CARD only fires on a real card number.
    public static func luhn(_ s: String) -> Bool {
        let digits = s.compactMap { $0.wholeNumberValue }
        guard digits.count >= 13, digits.count <= 19 else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }

    /// ABA routing numbers carry a checksum; validating it keeps ROUTING from eating every 9-digit number.
    public static func aba(_ s: String) -> Bool {
        let d = s.compactMap { $0.wholeNumberValue }
        guard d.count == 9 else { return false }
        let sum = 3 * (d[0] + d[3] + d[6]) + 7 * (d[1] + d[4] + d[7]) + (d[2] + d[5] + d[8])
        return sum % 10 == 0
    }

    /// Shannon entropy, bits per character.
    public static func entropy(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var freq: [Character: Int] = [:]
        for c in s { freq[c, default: 0] += 1 }
        let n = Double(s.count)
        return freq.values.reduce(0.0) { acc, c in
            let p = Double(c) / n
            return acc - p * log2(p)
        }
    }

    /// TOKEN is the catch-all for secrets with no recognizable prefix. Its character class
    /// contains "/" and ".", so without a gate it swallows every absolute path and screenshot
    /// filename. Measured on real input: paths and CleanShot filenames top out at 4.14 bits/char,
    /// prefix-less secrets start at 4.66. 4.4 sits in the gap.
    public static func looksLikeSecret(_ s: String) -> Bool {
        if s.contains("://") { return false }   // URL
        if s.hasPrefix("/")  { return false }   // absolute path
        return entropy(s) >= 4.4
    }
}
