import AVFoundation
import ImageIO

enum ExportFormat: String, CaseIterable, Identifiable {
    case mp4H264 = "MP4 (H.264)"
    case mp4HEVC = "MP4 (HEVC, 용량 작음)"
    case movProRes = "MOV (ProRes, 고화질)"
    case m4a = "오디오만 (M4A)"

    var id: String { rawValue }

    var preset: String {
        switch self {
        case .mp4H264: return AVAssetExportPresetHighestQuality
        case .mp4HEVC: return AVAssetExportPresetHEVCHighestQuality
        case .movProRes: return AVAssetExportPresetAppleProRes422LPCM
        case .m4a: return AVAssetExportPresetAppleM4A
        }
    }

    var fileType: AVFileType {
        switch self {
        case .mp4H264, .mp4HEVC: return .mp4
        case .movProRes: return .mov
        case .m4a: return .m4a
        }
    }

    var ext: String {
        switch self {
        case .mp4H264, .mp4HEVC: return "mp4"
        case .movProRes: return "mov"
        case .m4a: return "m4a"
        }
    }
}

enum Exporter {
    final class Box: @unchecked Sendable {
        var session: AVAssetExportSession?
    }

    static func export(project: Project, format: ExportFormat, size: CGSize, burnCaptions: Bool,
                       to url: URL, cancel: Box, progress: @escaping (Double) -> Void) async throws {
        let built = try await CompositionBuilder.build(project: project, renderSize: size, captions: burnCaptions)
        guard built.duration > 0 else { throw MediaError.failed("타임라인이 비어 있습니다.") }
        guard let session = AVAssetExportSession(asset: built.composition, presetName: format.preset) else {
            throw MediaError.failed("내보내기 세션을 만들 수 없습니다.")
        }
        cancel.session = session
        try? FileManager.default.removeItem(at: url)
        session.outputURL = url
        session.outputFileType = format.fileType
        session.audioMix = built.audioMix
        session.audioTimePitchAlgorithm = .spectral
        session.shouldOptimizeForNetworkUse = true
        if format != .m4a { session.videoComposition = built.videoComposition }

        let poll = Task.detached {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            session.exportAsynchronously { c.resume() }
        }
        poll.cancel()
        switch session.status {
        case .completed:
            progress(1)
        case .cancelled:
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        default:
            throw MediaError.failed("내보내기 실패: \(session.error?.localizedDescription ?? "알 수 없는 오류")")
        }
    }

    static func exportSRT(_ captions: [Caption], to url: URL) throws {
        try SRT.make(captions).write(to: url, atomically: true, encoding: .utf8)
    }

    /// 한 장면을 PNG로 저장
    static func snapshot(project: Project, time: Double, to url: URL) async throws {
        let built = try await CompositionBuilder.build(project: project, renderSize: project.canvasSize)
        guard let vc = built.videoComposition else { throw MediaError.failed("타임라인이 비어 있습니다.") }
        let gen = AVAssetImageGenerator(asset: built.composition)
        gen.videoComposition = vc
        gen.requestedTimeToleranceAfter = .zero
        gen.requestedTimeToleranceBefore = .zero
        gen.maximumSize = project.canvasSize
        let (cg, _) = try await gen.image(at: CompositionBuilder.ct(min(time, max(0, built.duration - 0.05))))
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw MediaError.failed("이미지 저장 실패")
        }
        CGImageDestinationAddImage(dest, cg, nil)
        CGImageDestinationFinalize(dest)
    }
}
