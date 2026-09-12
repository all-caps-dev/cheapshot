// cheapshot - on-device screenshot OCR for AI agents.
// Turns screenshots into redacted text so agents read words, not pixels.
// Apple Vision. No network. No API cost.

import Foundation
import AppKit
import Vision

// MARK: - OCR

public func ocr(path: String, minConfidence: Float) -> String? {
    guard let img = NSImage(contentsOfFile: path),
          let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    do { try handler.perform([request]) } catch { return nil }

    guard let obs = request.results else { return "" }

    // Sort top-to-bottom, then left-to-right. Vision's origin is bottom-left.
    let sorted = obs.sorted { a, b in
        let ay = a.boundingBox.origin.y, by = b.boundingBox.origin.y
        if abs(ay - by) > 0.01 { return ay > by }
        return a.boundingBox.origin.x < b.boundingBox.origin.x
    }

    var lines: [String] = []
    for o in sorted {
        guard let top = o.topCandidates(1).first, top.confidence >= minConfidence else { continue }
        lines.append(top.string)
    }
    return lines.joined(separator: "\n")
}


// MARK: - Video

public func findFFmpeg() -> String? {
    // Honour the user's PATH first; their chosen ffmpeg is the one that should run.
    if let path = ProcessInfo.processInfo.environment["PATH"] {
        for dir in path.split(separator: ":") {
            let c = String(dir) + "/ffmpeg"
            if FileManager.default.isExecutableFile(atPath: c) { return c }
        }
    }
    let candidates = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg",
                      NSHomeDirectory() + "/.local/bin/ffmpeg", "/usr/bin/ffmpeg"]
    for c in candidates where FileManager.default.isExecutableFile(atPath: c) { return c }
    return nil
}

/// Pull only the frames where the screen actually changed, with their timestamps.
public func sceneFrames(video: String, threshold: Double, maxFrames: Int) -> (dir: String, frames: [(Double, String)])? {
    guard let ff = findFFmpeg() else {
        FileHandle.standardError.write("cheapshot: ffmpeg not found in /opt/homebrew/bin, /usr/local/bin, ~/.local/bin, /usr/bin\n".data(using: .utf8)!)
        return nil
    }
    let dir = NSTemporaryDirectory() + "cheapshot-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: ff)
    p.arguments = ["-hide_banner", "-nostdin", "-i", video,
                   "-vf", "select=eq(n\\,0)+gt(scene\\,\(threshold)),metadata=print:file=-",
                   "-frames:v", "\(maxFrames)",
                   "\(dir)/f_%05d.png"]
    let out = Pipe(); let err = Pipe()
    p.standardOutput = out; p.standardError = err
    do { try p.run() } catch {
        FileHandle.standardError.write("cheapshot: could not launch \(ff): \(error)\n".data(using: .utf8)!)
        return nil
    }
    var outData = Data(), errData = Data()
    let g = DispatchGroup()
    g.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    g.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); g.leave() }
    p.waitUntilExit(); g.wait()
    let data = outData
    if p.terminationStatus != 0 {
        let tail = (String(data: errData, encoding: .utf8) ?? "").split(separator: "\n").suffix(6).joined(separator: "\n")
        FileHandle.standardError.write("cheapshot: ffmpeg exited \(p.terminationStatus)\n\(tail)\n".data(using: .utf8)!)
    }

    // metadata=print emits "frame:N  pts:... pts_time:SECONDS"
    var times: [Double] = []
    for line in (String(data: data, encoding: .utf8) ?? "").split(separator: "\n") {
        guard let r = line.range(of: "pts_time:") else { continue }
        if let t = Double(line[r.upperBound...].prefix(while: { $0 != " " })) { times.append(t) }
    }

    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
        .filter { $0.hasSuffix(".png") }.sorted()
    var frames: [(Double, String)] = []
    for (i, f) in files.enumerated() {
        frames.append((i < times.count ? times[i] : Double(i), dir + "/" + f))
    }
    return (dir, frames)
}

/// Cheap token-set overlap. Screen recordings repeat; near-identical frames are dropped.
public func similarity(_ a: String, _ b: String) -> Double {
    let sa = Set(a.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    let sb = Set(b.split(whereSeparator: { $0.isWhitespace }).map(String.init))
    if sa.isEmpty && sb.isEmpty { return 1 }
    if sa.isEmpty || sb.isEmpty { return 0 }
    return Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
}

public func stamp(_ s: Double) -> String {
    let t = Int(s.rounded())
    return String(format: "%02d:%02d", t / 60, t % 60)
}

// MARK: - Token accounting

public func imageTokens(path: String) -> Int {
    guard let img = NSImage(contentsOfFile: path),
          let rep = img.representations.first else { return 0 }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    // Anthropic's rule of thumb, with the long-edge downscale to 1568px applied.
    var fw = Double(w), fh = Double(h)
    let maxEdge = 1568.0
    if max(fw, fh) > maxEdge { let s = maxEdge / max(fw, fh); fw *= s; fh *= s }
    return Int((fw * fh / 750.0).rounded())
}

public func textTokens(_ s: String) -> Int { max(1, Int((Double(s.count) / 4.0).rounded())) }

