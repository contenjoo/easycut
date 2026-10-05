import AVFoundation
import CoreImage
import Vision

/// 화면 속 글자(OCR)·얼굴을 읽어 개인정보가 보이는 자리와 시간을 찾는다.
enum PrivacyScanner {
    struct Options {
        /// 전화번호·주민번호·이메일·카드·계좌 같은 정해진 형태
        var patterns = true
        /// 얼굴
        var faces = false
        /// 이 글자가 들어간 곳도 가린다 (이름·주소 등, 띄어쓰기 무시)
        var keywords: [String] = []
        /// 몇 초마다 화면을 읽을지 (0 = 길이에 맞춰 자동)
        var step: Double = 0
    }

    /// 한 장면에서 찾은 것 (좌표는 화면 비율, 왼쪽 위 원점)
    struct Hit {
        var label: String
        var text: String
        var rect: CGRect
    }

    /// 화면에서 읽은 글자 한 줄
    struct TextLine {
        var text: String
        var rect: CGRect
    }

    // MARK: 글자 형태

    struct Pattern {
        let label: String
        let regex: NSRegularExpression
        /// 숫자 개수 조건 (계좌번호처럼 흔한 형태를 걸러낸다)
        var digits: ClosedRange<Int>? = nil
    }

    static let patterns: [Pattern] = {
        func re(_ s: String) -> NSRegularExpression { try! NSRegularExpression(pattern: s, options: [.caseInsensitive]) }
        return [
            Pattern(label: "주민등록번호", regex: re(#"(?<![0-9])[0-9]{6}\s?[-–]\s?[1-8][0-9*●•xX]{6}(?![0-9])"#)),
            Pattern(label: "주민등록번호", regex: re(#"(?<![0-9])[0-9]{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12][0-9]|3[01])[1-8][0-9]{6}(?![0-9])"#)),
            Pattern(label: "이메일", regex: re(#"[A-Z0-9._%+\-]+\s?@\s?[A-Z0-9\-]+(?:\.[A-Z0-9\-]+)*\.[A-Z]{2,}"#)),
            Pattern(label: "전화번호", regex: re(#"(?<![0-9])(?:\+?82[\s\-]?\(?0?|\(?0)(?:1[016789]|2|[3-6][1-5]|70|50[0-9]?)\)?[\s\-.]?[0-9]{3,4}[\s\-.]?[0-9]{4}(?![0-9])"#), digits: 9...13),
            Pattern(label: "카드번호", regex: re(#"(?<![0-9])[0-9]{4}[\s\-][0-9*]{4}[\s\-][0-9*]{4}[\s\-][0-9]{3,4}(?![0-9])"#)),
            Pattern(label: "계좌번호", regex: re(#"(?<![0-9])[0-9]{2,6}-[0-9]{2,6}-[0-9]{2,7}(?:-[0-9]{1,3})?(?![0-9\-])"#), digits: 10...16),
            Pattern(label: "여권번호", regex: re(#"(?<![A-Z0-9])[MSROD][0-9]{3}[A-Z0-9][0-9]{4}(?![A-Z0-9])"#)),
        ]
    }()

    /// OCR이 숫자를 글자로 잘못 읽는 경우(O→0, l→1)를 고친 같은 길이의 문자열
    static func digitFixed(_ s: String) -> String {
        var out = Array(s)
        // 숫자 옆 글자부터 고치고, 고친 글자 옆도 이어서 고친다 (Ol0 → 010)
        var changed = true
        while changed {
            changed = false
            for i in out.indices {
                let fix: Character? = switch out[i] { case "O", "o": "0"; case "l", "I", "|": "1"; default: nil }
                guard let f = fix else { continue }
                if (i > 0 && out[i - 1].isNumber) || (i + 1 < out.count && out[i + 1].isNumber) { out[i] = f; changed = true }
            }
        }
        return String(out)
    }

    /// 한 줄에서 개인정보에 해당하는 글자 범위 찾기 (Character 오프셋)
    static func matches(in line: String, options: Options) -> [(label: String, range: Range<Int>)] {
        var out: [(String, Range<Int>)] = []
        if options.patterns {
            let fixed = digitFixed(line)
            let ns = fixed as NSString
            for p in patterns {
                for m in p.regex.matches(in: fixed, range: NSRange(location: 0, length: ns.length)) {
                    guard let r = Range(m.range, in: fixed) else { continue }
                    let found = fixed[r]
                    if let d = p.digits, !d.contains(found.filter(\.isNumber).count) { continue }
                    let a = fixed.distance(from: fixed.startIndex, to: r.lowerBound)
                    let b = fixed.distance(from: fixed.startIndex, to: r.upperBound)
                    // 같은 자리를 이미 다른 형태로 찾았으면 건너뛴다 (주민번호 ⊂ 계좌번호 등)
                    if out.contains(where: { $0.1.overlaps(a..<b) }) { continue }
                    out.append((p.label, a..<b))
                }
            }
        }
        // 지정한 글자: 띄어쓰기를 무시하고 찾는다
        let chars = Array(line)
        let packed = chars.enumerated().filter { !$0.element.isWhitespace }
        let hay = String(packed.map(\.element)).lowercased()
        for k in options.keywords {
            let key = k.filter { !$0.isWhitespace }.lowercased()
            guard !key.isEmpty else { continue }
            var from = hay.startIndex
            while let r = hay.range(of: key, range: from..<hay.endIndex) {
                let a = hay.distance(from: hay.startIndex, to: r.lowerBound)
                let b = hay.distance(from: hay.startIndex, to: r.upperBound) - 1
                guard a < packed.count, b < packed.count else { break }
                out.append(("지정한 글자", packed[a].offset..<(packed[b].offset + 1)))
                from = r.upperBound
            }
        }
        return out
    }

    // MARK: 한 장면 읽기

    static func readText(_ image: CGImage) -> [(TextLine, VNRecognizedText)] {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["ko-KR", "en-US"]
        req.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([req])) != nil else { return [] }
        return (req.results ?? []).compactMap { o in
            guard let c = o.topCandidates(1).first else { return nil }
            return (TextLine(text: c.string, rect: topLeft(o.boundingBox)), c)
        }
    }

    /// 화면에 보이는 글자 줄 전부 (AI가 무엇을 가릴지 고를 때)
    static func textLines(_ image: CGImage) -> [TextLine] { readText(image).map(\.0) }

    static func scan(_ image: CGImage, options: Options) -> [Hit] {
        var hits: [Hit] = []
        if options.patterns || !options.keywords.isEmpty {
            for (line, cand) in readText(image) {
                for m in matches(in: line.text, options: options) {
                    let s = cand.string
                    let a = s.index(s.startIndex, offsetBy: m.range.lowerBound)
                    let b = s.index(s.startIndex, offsetBy: m.range.upperBound)
                    var rect = line.rect
                    if let box = try? cand.boundingBox(for: a..<b)?.boundingBox, box.width > 0, box.height > 0 {
                        rect = topLeft(box)
                    }
                    hits.append(Hit(label: m.label, text: String(s[a..<b]), rect: pad(rect, image: image)))
                }
            }
        }
        if options.faces {
            let req = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            if (try? handler.perform([req])) != nil {
                for f in req.results ?? [] {
                    let r = topLeft(f.boundingBox)
                    // 머리카락·턱까지 넉넉하게
                    hits.append(Hit(label: "얼굴", text: "", rect: r.insetBy(dx: -r.width * 0.25, dy: -r.height * 0.35).intersection(unit)))
                }
            }
        }
        return hits
    }

    static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func topLeft(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height) }

    /// 글자 상자를 조금 넓힌다 (OCR 상자는 글자에 딱 붙어 있어 가장자리가 보일 수 있음)
    static func pad(_ r: CGRect, image: CGImage) -> CGRect {
        let aspect = CGFloat(image.width) / CGFloat(max(1, image.height))
        let dy = r.height * 0.3
        let dx = dy / aspect
        return r.insetBy(dx: -dx, dy: -dy).intersection(unit)
    }

    // MARK: 영상 전체

    /// 미디어의 [from, to] 원본 구간을 훑어 가릴 영역 목록을 만든다.
    static func scan(asset: MediaAsset, from: Double, to: Double, options: Options,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> [BlurRegion] {
        if asset.kind == .image {
            guard let src = CGImageSourceCreateWithURL(asset.url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldAllowFloat: false] as CFDictionary) else {
                throw NSError(domain: "EasyCut", code: 1, userInfo: [NSLocalizedDescriptionKey: L("사진을 읽을 수 없습니다.")])
            }
            let oriented = orientedImage(img, source: src)
            progress(1)
            return scan(oriented, options: options).map {
                BlurRegion(x: $0.rect.minX, y: $0.rect.minY, w: $0.rect.width, h: $0.rect.height,
                           start: 0, end: 1e6, label: $0.label, text: $0.text.isEmpty ? nil : $0.text)
            }
        }
        guard asset.kind == .video else { return [] }
        let span = max(0, to - from)
        let step = options.step > 0 ? options.step : max(0.5, span / 1500)
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1920, height: 1920)
        gen.requestedTimeToleranceBefore = CMTime(seconds: step / 4, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: step / 4, preferredTimescale: 600)

        var times: [Double] = []
        var t = from
        while t < to { times.append(t); t += step }
        if times.isEmpty { times = [from] }

        var tracker = Tracker(step: step, from: from, to: to)
        var lastThumb: [UInt8]?
        var lastHits: [Hit] = []
        for (n, t) in times.enumerated() {
            try Task.checkCancellation()
            guard let img = try? await gen.image(at: CMTime(seconds: t, preferredTimescale: 600)).image else { continue }
            // 화면이 거의 그대로면 다시 읽지 않는다 (화면 녹화는 대부분 멈춰 있음)
            let thumb = thumbnail(img)
            let hits: [Hit]
            if let last = lastThumb, !changed(last, thumb) { hits = lastHits } else {
                hits = scan(img, options: options)
                lastThumb = thumb
                lastHits = hits
            }
            tracker.add(hits, at: t)
            progress(Double(n + 1) / Double(times.count))
        }
        return tracker.finish()
    }

    /// 연속된 장면에서 같은 자리의 같은 정보를 하나의 영역으로 잇는다
    struct Tracker {
        struct Open { var hit: Hit; var rect: CGRect; var first: Double; var last: Double }
        let step: Double, from: Double, to: Double
        var open: [Open] = []
        var done: [BlurRegion] = []

        mutating func add(_ hits: [Hit], at t: Double) {
            var next: [Open] = []
            var pool = open
            for h in hits {
                if let i = pool.firstIndex(where: { $0.hit.label == h.label && iou($0.hit.rect, h.rect) > 0.3 }) {
                    var o = pool.remove(at: i)
                    o.last = t
                    o.rect = o.rect.union(h.rect)
                    o.hit = h
                    next.append(o)
                } else {
                    next.append(Open(hit: h, rect: h.rect, first: t, last: t))
                }
            }
            for o in pool { close(o) }
            open = next
        }

        mutating func close(_ o: Open) {
            // 앞뒤로 한 간격씩 넉넉하게 (읽은 시점 사이에 나타나고 사라질 수 있다)
            let a = max(from, o.first - step), b = min(to, o.last + step)
            done.append(BlurRegion(x: o.rect.minX, y: o.rect.minY, w: o.rect.width, h: o.rect.height,
                                   start: a, end: max(b, a + 0.1), label: o.hit.label, text: o.hit.text.isEmpty ? nil : o.hit.text))
        }

        mutating func finish() -> [BlurRegion] {
            for o in open { close(o) }
            open = []
            return done.sorted { $0.start < $1.start }
        }
    }

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, i.width > 0, i.height > 0 else { return 0 }
        let ia = i.width * i.height
        return ia / (a.width * a.height + b.width * b.height - ia)
    }

    static func thumbnail(_ img: CGImage) -> [UInt8] {
        let w = 320, h = 180
        var buf = [UInt8](repeating: 0, count: w * h)
        buf.withUnsafeMutableBytes { p in
            guard let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return buf
    }

    /// 작은 글자 하나가 새로 나타나도 알아채도록 평균이 아니라 뚜렷하게 바뀐 점의 수로 판단한다
    static func changed(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return true }
        var n = 0
        for i in a.indices where abs(Int(a[i]) - Int(b[i])) > 28 {
            n += 1
            if n >= 3 { return true }
        }
        return false
    }

    static func orientedImage(_ img: CGImage, source: CGImageSource) -> CGImage {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let raw = props[kCGImagePropertyOrientation] as? UInt32, raw > 1,
              let o = CGImagePropertyOrientation(rawValue: raw) else { return img }
        let ci = CIImage(cgImage: img).oriented(o)
        return RenderCache.context.createCGImage(ci, from: ci.extent) ?? img
    }

    /// 원본 시간 한 지점의 장면 (AI가 화면 글자를 읽을 때)
    static func frame(asset: MediaAsset, at s: Double) async -> CGImage? {
        if asset.kind == .image {
            guard let src = CGImageSourceCreateWithURL(asset.url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
            return orientedImage(img, source: src)
        }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: asset.url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1920, height: 1920)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)
        return try? await gen.image(at: CMTime(seconds: s, preferredTimescale: 600)).image
    }
}
