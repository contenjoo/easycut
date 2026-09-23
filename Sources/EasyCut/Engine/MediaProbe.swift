import AVFoundation
import AppKit
import UniformTypeIdentifiers
import ImageIO

enum MediaError: LocalizedError {
    case unsupported(String)
    case noTracks(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let n): return "지원하지 않는 파일 형식입니다: \(n)"
        case .noTracks(let n): return "영상/오디오 트랙을 찾을 수 없습니다: \(n)"
        case .failed(let m): return m
        }
    }
}

enum MediaProbe {
    static let importTypes: [UTType] = [.movie, .video, .audio, .image, .mpeg4Movie, .quickTimeMovie, .mp3, .wav, .aiff, .png, .jpeg, .heic, .gif, .tiff]
        + MediaConverter.convertibleExtensions.sorted().compactMap { UTType(filenameExtension: $0) }

    static func kind(of url: URL) -> MediaKind? {
        if MediaConverter.needsConversion(url) { return .video }
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return nil }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .movie) || type.conforms(to: .video) || type.conforms(to: .audiovisualContent) { return .video }
        return nil
    }

    static func probe(_ url: URL) async throws -> MediaAsset {
        let name = url.lastPathComponent
        guard let kind = kind(of: url) else { throw MediaError.unsupported(name) }
        if kind == .image {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else {
                throw MediaError.unsupported(name)
            }
            var w = (props[kCGImagePropertyPixelWidth] as? Double) ?? 1920
            var h = (props[kCGImagePropertyPixelHeight] as? Double) ?? 1080
            if let o = props[kCGImagePropertyOrientation] as? Int, o >= 5 { swap(&w, &h) }
            return MediaAsset(path: url.path, name: name, kind: .image, duration: 5, width: w, height: h, hasAudio: false)
        }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if videoTracks.isEmpty && audioTracks.isEmpty { throw MediaError.noTracks(name) }
        var w = 0.0, h = 0.0
        if let v = videoTracks.first {
            let (size, t) = try await v.load(.naturalSize, .preferredTransform)
            let r = CGRect(origin: .zero, size: size).applying(t)
            w = abs(r.width); h = abs(r.height)
        }
        let k: MediaKind = videoTracks.isEmpty ? .audio : .video
        guard duration.isFinite, duration > 0 else { throw MediaError.failed("길이를 읽을 수 없습니다: \(name)") }
        return MediaAsset(path: url.path, name: name, kind: k, duration: duration, width: w, height: h, hasAudio: !audioTracks.isEmpty)
    }

    static func orientation(_ t: CGAffineTransform) -> CGImagePropertyOrientation {
        if abs(t.a) < 0.01 && t.b > 0.99 && t.c < -0.99 && abs(t.d) < 0.01 { return .right }
        if abs(t.a) < 0.01 && t.b < -0.99 && t.c > 0.99 && abs(t.d) < 0.01 { return .left }
        if t.a < -0.99 && t.d < -0.99 { return .down }
        if t.a < -0.99 && t.d > 0.99 { return .upMirrored }
        return .up
    }
}

/// 컴포지션 길이를 유지하기 위한 1초짜리 검은 영상
enum BlankVideo {
    private static var cached: URL?

    static func url() async throws -> URL {
        if let cached, FileManager.default.fileExists(atPath: cached.path) { return cached }
        let dir = AppPaths.support
        let url = dir.appendingPathComponent("blank_v2.mov")
        if FileManager.default.fileExists(atPath: url.path) { cached = url; return url }
        let tmp = dir.appendingPathComponent("blank_tmp_\(UUID().uuidString).mov")
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mov)
        let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?
            CVPixelBufferCreate(nil, 64, 64, kCVPixelFormatType_32BGRA, nil, &pb)
            guard let pb else { throw MediaError.failed("빈 영상 생성 실패") }
            CVPixelBufferLockBaseAddress(pb, [])
            memset(CVPixelBufferGetBaseAddress(pb), 0, CVPixelBufferGetDataSize(pb))
            CVPixelBufferUnlockBaseAddress(pb, [])
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw MediaError.failed("빈 영상 생성 실패: \(writer.error?.localizedDescription ?? "")") }
        try? FileManager.default.removeItem(at: url)
        try FileManager.default.moveItem(at: tmp, to: url)
        cached = url
        return url
    }
}

enum AppPaths {
    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("EasyCut", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var models: URL {
        let dir = support.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var temp: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("EasyCut", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
