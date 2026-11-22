import AVFoundation
import CoreImage
import ImageIO
import Vision

enum CameraBackdropChoice: String, CaseIterable, Identifiable {
    case off, blur, studio, library, loft, midnight, custom
    var id: Self { self }

    var title: String {
        switch self {
        case .off: return "원본"
        case .blur: return "배경 흐림"
        case .studio: return "스튜디오"
        case .library: return "서재"
        case .loft: return "로프트"
        case .midnight: return "미드나이트"
        case .custom: return "내 이미지"
        }
    }

    static let presets: [Self] = [.studio, .library, .loft, .midnight]

    var presetURL: URL? {
        Bundle.main.url(forResource: rawValue, withExtension: "jpg", subdirectory: "CameraBackgrounds")
    }

    static func loadImage(at url: URL, maxSize: Int = 2048) throws -> CGImage {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxSize
              ] as CFDictionary) else { throw CameraBackdropError.image }
        return image
    }
}

enum CameraBackdrop {
    case off, blur, image(CGImage)
}

enum CameraBackdropError: LocalizedError {
    case image, frame
    var errorDescription: String? {
        switch self {
        case .image: return L("배경 이미지를 열 수 없습니다. 다른 이미지를 선택하세요.")
        case .frame: return L("카메라 배경을 처리하지 못했습니다.")
        }
    }
}

/// Used on the camera's serial queue. Both outgoing video and the editable camera track
/// consume the same timestamped sample, so masks never need to be regenerated in the editor.
final class CameraBackdropProcessor {
    var backdrop: CameraBackdrop = .off
    lazy var context = CIContext(options: [.cacheIntermediates: false])
    private lazy var request: VNGeneratePersonSegmentationRequest = {
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .balanced
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return request
    }()
    private lazy var sequence = VNSequenceRequestHandler()
    private var pool: CVPixelBufferPool?
    private var format: CMVideoFormatDescription?
    private var poolSize = CGSize.zero
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!

    func process(_ sample: CMSampleBuffer) throws -> CMSampleBuffer {
        if case .off = backdrop { return sample }
        guard let pixel = sample.imageBuffer else { throw CameraBackdropError.frame }
        try sequence.perform([request], on: pixel, orientation: .up)
        guard let mask = request.results?.first?.pixelBuffer else { throw CameraBackdropError.frame }
        let source = CIImage(cvPixelBuffer: pixel)
        let composite = Self.composite(source: source, mask: CIImage(cvPixelBuffer: mask, options: [.colorSpace: NSNull()]), backdrop: backdrop)
        let size = source.extent.size
        if pool == nil || size != poolSize {
            let attributes: [CFString: Any] = [
                kCVPixelBufferWidthKey: Int(size.width), kCVPixelBufferHeightKey: Int(size.height),
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
            ]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { throw CameraBackdropError.frame }
            poolSize = size
            format = nil
        }
        var buffer: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { throw CameraBackdropError.frame }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        context.render(composite, to: buffer, bounds: source.extent, colorSpace: space)
        if format == nil {
            guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr else {
                throw CameraBackdropError.frame
            }
        }
        var timing = CMSampleTimingInfo(duration: sample.duration, presentationTimeStamp: sample.presentationTimeStamp,
                                       decodeTimeStamp: sample.decodeTimeStamp)
        var result: CMSampleBuffer?
        guard let format, CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                sampleTiming: &timing, sampleBufferOut: &result) == noErr, let result else { throw CameraBackdropError.frame }
        return result
    }

    static func composite(source: CIImage, mask: CIImage, backdrop: CameraBackdrop) -> CIImage {
        let bounds = source.extent
        let background: CIImage
        switch backdrop {
        case .off:
            return source
        case .blur:
            background = source.clampedToExtent().applyingGaussianBlur(sigma: max(8, min(bounds.width, bounds.height) * 0.032)).cropped(to: bounds)
        case .image(let image):
            let still = CIImage(cgImage: image)
            let scale = max(bounds.width / still.extent.width, bounds.height / still.extent.height)
            let scaled = still.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            background = scaled.transformed(by: CGAffineTransform(translationX: bounds.midX - scaled.extent.midX,
                                                                  y: bounds.midY - scaled.extent.midY)).cropped(to: bounds)
        }
        let matte = mask.transformed(by: CGAffineTransform(scaleX: bounds.width / mask.extent.width, y: bounds.height / mask.extent.height))
        return source.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: background, kCIInputMaskImageKey: matte]).cropped(to: bounds)
    }
}
