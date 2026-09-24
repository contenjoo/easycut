import AVFoundation
import CoreImage
import AppKit
import Vision

/// 컴포지터가 한 프레임을 그리는 데 필요한 정보
struct RenderLayer {
    enum Content {
        case video(trackID: CMPersistentTrackID, orientation: CGImagePropertyOrientation)
        case image(path: String)
        case text(String, TextStyle)
    }

    var content: Content
    var start: Double
    var end: Double
    var opacity: Double
    var scale: Double
    var offsetX: Double
    var offsetY: Double
    var fadeIn: Double
    var fadeOut: Double
    var sourceIn: Double = 0
    var speed: Double = 1
    var shape: ClipShape = .none
    var backgroundEffect: BackgroundEffect = .none
    /// 표시할 마우스 클릭 (원본 시간 기준)
    var clicks: [ClickMark] = []

    func alpha(at t: Double) -> Double {
        var a = opacity
        if fadeIn > 0 { a *= min(1, max(0, (t - start) / fadeIn)) }
        if fadeOut > 0 { a *= min(1, max(0, (end - t) / fadeOut)) }
        return a
    }
}

struct RenderScene {
    var layers: [RenderLayer]
    var captions: [Caption]
    var captionStyle: TextStyle
    var showCaptions: Bool
    var background: RGBA

    func caption(at t: Double) -> Caption? {
        var lo = 0, hi = captions.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let c = captions[mid]
            if t < c.start { hi = mid - 1 } else if t >= c.end { lo = mid + 1 } else { return c }
        }
        return nil
    }
}

final class SceneInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool = false
    let containsTweening: Bool = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID = kCMPersistentTrackID_Invalid
    let scene: RenderScene

    init(timeRange: CMTimeRange, trackIDs: [CMPersistentTrackID], scene: RenderScene) {
        self.timeRange = timeRange
        self.requiredSourceTrackIDs = trackIDs.isEmpty ? nil : trackIDs.map { NSNumber(value: $0) }
        self.scene = scene
    }
}

enum RenderCache {
    static let context: CIContext = {
        if let dev = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: dev, options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        }
        return CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
    }()

    private static let lock = NSLock()
    private static var images: [String: CIImage] = [:]
    private static var texts: [String: CIImage] = [:]

    static func image(_ path: String) -> CIImage? {
        lock.lock(); defer { lock.unlock() }
        if let img = images[path] { return img }
        guard var img = CIImage(contentsOf: URL(fileURLWithPath: path), options: [.applyOrientationProperty: true]) else { return nil }
        // 너무 큰 이미지는 미리 줄여 둔다
        let maxSide = max(img.extent.width, img.extent.height)
        if maxSide > 4096 {
            let s = 4096 / maxSide
            img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
        if let cg = context.createCGImage(img, from: img.extent) { img = CIImage(cgImage: cg) }
        images[path] = img
        return img
    }

    static func text(_ text: String, style: TextStyle, unit: CGFloat, maxWidth: CGFloat, scale: Double) -> CIImage? {
        let key = "\(text)|\(style.hashValue)|\(unit)|\(maxWidth)|\(scale)"
        lock.lock()
        if let img = texts[key] { lock.unlock(); return img }
        lock.unlock()
        guard let cg = TextRenderer.render(text: text, style: style, unit: unit * scale, maxWidth: maxWidth) else { return nil }
        let img = CIImage(cgImage: cg)
        lock.lock()
        if texts.count > 400 { texts.removeAll() }
        texts[key] = img
        lock.unlock()
        return img
    }

    static func clear() {
        lock.lock(); images.removeAll(); texts.removeAll(); lock.unlock()
    }
}

enum TextRenderer {
    static func render(text: String, style: TextStyle, unit: CGFloat, maxWidth: CGFloat) -> CGImage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let size = max(6, CGFloat(style.fontSize) * unit)
        var font: NSFont = .systemFont(ofSize: size, weight: style.bold ? .bold : .regular)
        if !style.fontName.isEmpty, let f = NSFont(name: style.fontName, size: size) { font = f }
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        para.lineSpacing = size * 0.08
        let padX = size * 0.45, padY = size * 0.2
        let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: para, .foregroundColor: style.textColor.nsColor]
        let str = NSAttributedString(string: trimmed, attributes: base)
        let textRect = str.boundingRect(with: CGSize(width: max(50, maxWidth - 2 * padX), height: .greatestFiniteMagnitude),
                                        options: [.usesLineFragmentOrigin, .usesFontLeading])
        let w = Int(ceil(textRect.width + 2 * padX)), h = Int(ceil(textRect.height + 2 * padY))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        if style.backgroundColor.a > 0.001 {
            ctx.setFillColor(style.backgroundColor.cgColor)
            ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerWidth: size * 0.25, cornerHeight: size * 0.25, transform: nil))
            ctx.fillPath()
        }
        let prev = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let drawRect = CGRect(x: padX, y: padY, width: CGFloat(w) - 2 * padX, height: textRect.height)
        if style.outline {
            var o = base
            o[.strokeColor] = style.outlineColor.nsColor
            o[.strokeWidth] = 14.0
            NSAttributedString(string: trimmed, attributes: o).draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
        str.draw(with: drawRect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.current = prev
        return ctx.makeImage()
    }
}

/// 여러 트랙의 영상·이미지·텍스트·자막을 한 프레임으로 합성하는 커스텀 컴포지터
final class EasyCompositor: NSObject, AVVideoCompositing {
    private let queue = DispatchQueue(label: "easycut.compositor", qos: .userInteractive)
    private var cancelled = false

    let sourcePixelBufferAttributes: [String: Any]? = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]
    let requiredPixelBufferAttributesForRenderContext: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
    ]

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.cancelled { request.finishCancelledRequest(); return }
            autoreleasepool {
                if let pb = Self.render(request) {
                    request.finish(withComposedVideoFrame: pb)
                } else {
                    request.finish(with: NSError(domain: "EasyCut", code: -1, userInfo: [NSLocalizedDescriptionKey: "프레임 합성 실패"]))
                }
            }
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancelled = true
        queue.async { [weak self] in self?.cancelled = false }
    }

    static func render(_ request: AVAsynchronousVideoCompositionRequest) -> CVPixelBuffer? {
        guard let out = request.renderContext.newPixelBuffer() else { return nil }
        guard let inst = request.videoCompositionInstruction as? SceneInstruction else { return out }
        let size = request.renderContext.size
        let t = request.compositionTime.seconds
        let image = compose(scene: inst.scene, time: t, size: size) { trackID in
            request.sourceFrame(byTrackID: trackID)
        }
        RenderCache.context.render(image, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return out
    }

    /// 한 시점의 프레임 합성 (미리보기 스틸 컷에도 사용)
    static func compose(scene: RenderScene, time t: Double, size: CGSize, frame: (CMPersistentTrackID) -> CVPixelBuffer?) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        var result = CIImage(color: CIColor(cgColor: scene.background.cgColor)).cropped(to: canvas)
        let unit = min(size.width, size.height) / 1080

        for layer in scene.layers where t >= layer.start - 0.0001 && t < layer.end {
            let alpha = layer.alpha(at: t)
            guard alpha > 0.001 else { continue }
            var src: CIImage
            var isText = false
            switch layer.content {
            case .video(let trackID, let orientation):
                guard let pb = frame(trackID) else { continue }
                src = CIImage(cvPixelBuffer: pb).oriented(orientation)
            case .image(let path):
                guard let img = RenderCache.image(path) else { continue }
                src = img
            case .text(let text, let style):
                guard let img = RenderCache.text(text, style: style, unit: unit, maxWidth: size.width * 0.9, scale: layer.scale) else { continue }
                src = img
                isText = true
            }
            src = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))
            if !isText {
                if layer.backgroundEffect != .none { src = Effects.personBackground(src, effect: layer.backgroundEffect) }
                if !layer.clicks.isEmpty { src = Effects.clicks(src, marks: layer.clicks, sourceTime: layer.sourceIn + (t - layer.start) * layer.speed) }
                if layer.shape != .none {
                    src = Effects.shape(src, layer.shape)
                    src = src.transformed(by: CGAffineTransform(translationX: -src.extent.minX, y: -src.extent.minY))
                }
            }
            let w = src.extent.width, h = src.extent.height
            guard w > 0, h > 0 else { continue }
            var x: CGFloat, y: CGFloat
            if isText, case .text(_, let style) = layer.content {
                x = (size.width - w) / 2 + CGFloat(layer.offsetX) * size.width
                let centerFromTop = CGFloat(style.positionY + layer.offsetY) * size.height
                y = size.height - centerFromTop - h / 2
            } else {
                let fit = min(size.width / w, size.height / h) * CGFloat(layer.scale)
                src = src.transformed(by: CGAffineTransform(scaleX: fit, y: fit))
                x = (size.width - w * fit) / 2 + CGFloat(layer.offsetX) * size.width
                y = (size.height - h * fit) / 2 - CGFloat(layer.offsetY) * size.height
            }
            src = src.transformed(by: CGAffineTransform(translationX: x, y: y))
            if alpha < 0.999 {
                src = src.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
            }
            result = src.composited(over: result)
        }

        if scene.showCaptions, let cap = scene.caption(at: t),
           let img = RenderCache.text(cap.text, style: scene.captionStyle, unit: unit, maxWidth: size.width * 0.86, scale: 1) {
            let w = img.extent.width, h = img.extent.height
            let x = (size.width - w) / 2
            var y = size.height - CGFloat(scene.captionStyle.positionY) * size.height - h / 2
            y = min(max(y, 4), size.height - h - 4)
            result = img.transformed(by: CGAffineTransform(translationX: x, y: y)).composited(over: result)
        }
        return result.cropped(to: canvas)
    }
}

/// 클립 효과: 모양 자르기, 인물 배경, 마우스 클릭 강조 (모두 원본 크기 좌표에서 처리)
enum Effects {
    /// 원: 가운데 정사각형을 원으로 (흰 테두리), 둥근 사각형: 모서리 둥글게
    static func shape(_ img: CIImage, _ shape: ClipShape) -> CIImage {
        let e = img.extent
        switch shape {
        case .none:
            return img
        case .circle:
            let s = min(e.width, e.height)
            let sq = CGRect(x: e.midX - s / 2, y: e.midY - s / 2, width: s, height: s)
            let c = CIVector(x: sq.midX, y: sq.midY)
            let rim = max(2, s * 0.018)
            let inner = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": c, "inputRadius0": s / 2 - rim - 1, "inputRadius1": s / 2 - rim,
                "inputColor0": CIColor.white, "inputColor1": CIColor.clear])!.outputImage!.cropped(to: sq)
            let ring = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": c, "inputRadius0": s / 2 - 1, "inputRadius1": s / 2,
                "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 0.95), "inputColor1": CIColor.clear])!.outputImage!.cropped(to: sq)
            let face = img.cropped(to: sq).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: inner])
            return face.composited(over: ring).cropped(to: sq)
        case .rounded:
            let r = min(e.width, e.height) * 0.08
            guard let mask = CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                "inputExtent": CIVector(cgRect: e), "inputRadius": r, "inputColor": CIColor.white])?.outputImage else { return img }
            return img.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask.cropped(to: e)]).cropped(to: e)
        }
    }

    /// 인물만 남기고 배경을 흐리게/지우기
    static func personBackground(_ img: CIImage, effect: BackgroundEffect) -> CIImage {
        let e = img.extent
        let req = VNGeneratePersonSegmentationRequest()
        req.qualityLevel = .balanced
        req.outputPixelFormat = kCVPixelFormatType_OneComponent8
        let handler = VNImageRequestHandler(ciImage: img, options: [:])
        guard (try? handler.perform([req])) != nil, let pb = req.results?.first?.pixelBuffer else { return img }
        var mask = CIImage(cvPixelBuffer: pb)
        mask = mask.transformed(by: CGAffineTransform(scaleX: e.width / mask.extent.width, y: e.height / mask.extent.height))
            .transformed(by: CGAffineTransform(translationX: e.minX, y: e.minY))
        let bg: CIImage
        switch effect {
        case .blur: bg = img.clampedToExtent().applyingGaussianBlur(sigma: Double(min(e.width, e.height)) * 0.025).cropped(to: e)
        default: bg = CIImage.empty()
        }
        return img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: bg, kCIInputMaskImageKey: mask]).cropped(to: e)
    }

    /// 클릭한 자리에 노란 원이 퍼졌다 사라지는 표시 (0.7초)
    static func clicks(_ img: CIImage, marks: [ClickMark], sourceTime s: Double) -> CIImage {
        let e = img.extent
        let dur = 0.7
        var out = img
        for m in marks where s >= m.t && s - m.t <= dur {
            let p = (s - m.t) / dur
            let r = CGFloat(0.02 + 0.03 * p) * min(e.width, e.height)
            let a = CGFloat(0.65 * (1 - p))
            let c = CIVector(x: e.minX + CGFloat(m.x) * e.width, y: e.minY + CGFloat(1 - m.y) * e.height)
            guard let disk = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": c, "inputRadius0": r * 0.55, "inputRadius1": r,
                "inputColor0": CIColor(red: 1, green: 0.84, blue: 0.1, alpha: a), "inputColor1": CIColor.clear])?.outputImage else { continue }
            out = disk.cropped(to: e).composited(over: out)
        }
        return out
    }
}
