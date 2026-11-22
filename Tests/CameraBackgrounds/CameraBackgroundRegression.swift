import AVFoundation
import CoreImage

// Run from the checkout root:
// swiftc -O Sources/EasyCut/Engine/{CameraBackground,CompositionBuilder,Compositor,StudioProgram,StudioBroadcast,StudioAudioMix,AudioPolish,MediaProbe,MediaConverter,MotionEffects}.swift Sources/EasyCut/Model/{Model,ClipEffects,TimelineOps,CaptionWords,TranscriptOps,StudioRecordingTimeline}.swift Tests/CameraBackgrounds/CameraBackgroundRegression.swift -o /tmp/easycut-camera-check && /tmp/easycut-camera-check
func L(_ string: String) -> String { string }
enum Tools { static func find(_ name: String) -> String? { nil } }

@main
struct CameraBackgroundRegression {
    static let context = CIContext()
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static let width = 768, height = 432
    static let frame = CGRect(x: 0, y: 0, width: width, height: height)

    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let presenter = try CameraBackdropChoice.loadImage(at: root.appendingPathComponent("Tests/CameraBackgrounds/presenter.jpg"))
        let camera = makePixel(CIImage(cgImage: presenter))
        let original = pixels(CIImage(cvPixelBuffer: camera))
        let presets = try CameraBackdropChoice.presets.map {
            try CameraBackdropChoice.loadImage(at: root.appendingPathComponent("windows/app/ui/camera-backgrounds/presets/" + $0.rawValue + ".jpg"))
        }
        let purple = CIImage(color: CIColor(red: 0.37, green: 0.05, blue: 0.63)).cropped(to: CGRect(x: 0, y: 0, width: 90, height: 170))
        let custom = context.createCGImage(purple, from: purple.extent)!
        let modes = [CameraBackdrop.off, .blur] + presets.map { .image($0) } + [.image(custom), .off]
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("easycut-camera-" + UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: output) }
        let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
        let track = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 6_000_000, AVVideoMaxKeyFrameIntervalKey: 4]
        ])
        writer.add(track)
        precondition(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let processor = CameraBackdropProcessor()
        var references: [[UInt8]] = []
        var liveFrames: [[UInt8]] = []
        let screenImage = CIImage(color: CIColor(red: 0.02, green: 0.1, blue: 0.42)).cropped(to: frame)
        let screen = makePixel(screenImage)
        let scenes: [StudioScene] = [.camera, .camera, .screen, .pictureInPicture, .camera, .camera, .camera, .camera]
        for (index, mode) in modes.enumerated() {
            processor.backdrop = mode
            for n in 0..<4 {
                let input = sample(pixel: camera, tick: index * 4 + n)
                let out = try processor.process(input)
                precondition(input.presentationTimeStamp == out.presentationTimeStamp && input.duration == out.duration)
                if n == 0 {
                    let result = pixels(CIImage(cvPixelBuffer: out.imageBuffer!))
                    references.append(result)
                    let monitor = try await preview(scene: scenes[index], screen: sample(pixel: screen, tick: 0), camera: out)
                    liveFrames.append(pixels(CIImage(cgImage: monitor).transformed(by:
                        CGAffineTransform(scaleX: Double(width) / Double(monitor.width), y: Double(height) / Double(monitor.height)))))
                    let face = difference(original, result, box: (334, 135, 425, 210))
                    let edge = difference(original, result, box: (12, 34, 125, 160))
                    switch mode {
                    case .off: precondition(input === out && face == 0 && edge == 0)
                    case .blur:
                        precondition(face < 10 && edge > 25)
                        precondition(contrast(result) < contrast(original) * 0.35)
                    case .image:
                        precondition(face < 10 && edge > 30)
                    }
                    print("mode \(index) mean RGB delta subject=\(Int(face)) background=\(Int(edge))")
                }
                while !track.isReadyForMoreMediaData {
                    guard writer.status == .writing else { throw writer.error ?? CameraBackdropError.frame }
                    try await Task.sleep(nanoseconds: 2_000_000)
                }
                guard track.append(out) else { throw writer.error ?? CameraBackdropError.frame }
            }
        }
        track.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: Int64(modes.count * 4), timescale: 4))
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CameraBackdropError.frame }
        let decoder = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        decoder.requestedTimeToleranceBefore = .zero
        decoder.requestedTimeToleranceAfter = .zero
        for index in modes.indices {
            let decoded = try await decoder.image(at: CMTime(value: Int64(index * 4 + 1), timescale: 4)).image
            let image = pixels(CIImage(cgImage: decoded))
            let error = difference(references[index], image, box: (0, 0, width, height))
            precondition(error < 12, "Encoded camera image mismatch at \(index): \(error)")
        }
        // Compare frames from the actual live program to the editor's saved-and-reopened composition.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: scratch) }
        setenv("EASYCUT_SUPPORT_DIR", scratch.path, 1)
        let still = scratch.appendingPathComponent("screen.png")
        try context.writePNGRepresentation(of: screenImage, to: still, format: .RGBA8, colorSpace: space)
        let cameraAsset = try await MediaProbe.probe(output)
        var screenAsset = try await MediaProbe.probe(still)
        screenAsset.duration = cameraAsset.duration
        var project = Project()
        project.assets = [screenAsset, cameraAsset]
        project.insertStudioRecording(screen: screenAsset, camera: cameraAsset, audio: nil,
            changes: scenes.enumerated().map { StudioSceneChange(time: Double($0.offset), scene: $0.element) },
            showClicks: false)
        let saved = scratch.appendingPathComponent("test.easycut")
        try JSONEncoder().encode(project).write(to: saved)
        let reopened = try JSONDecoder().decode(Project.self, from: Data(contentsOf: saved))
        let built = try await CompositionBuilder.build(project: reopened, renderSize: frame.size)
        precondition(built.missing.isEmpty && reopened.duration == cameraAsset.duration)
        let editor = AVAssetImageGenerator(asset: built.composition)
        editor.videoComposition = built.videoComposition
        editor.requestedTimeToleranceBefore = .zero
        editor.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 30)
        for index in scenes.indices {
            let decoded = try await editor.image(at: CMTime(value: Int64(index * 4 + 1), timescale: 4)).image
            let error = difference(liveFrames[index], pixels(CIImage(cgImage: decoded)), box: (0, 0, width, height))
            precondition(error < 12, "Program/editor mismatch at \(index): \(error)")
        }
        print("PASS native Vision, four presets, custom image, eight H.264 segments, program monitor and reopened editor composition")
    }

    static func preview(scene: StudioScene, screen: CMSampleBuffer, camera: CMSampleBuffer) async throws -> CGImage {
        let pipe = AsyncStream<CGImage>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let program = try StudioProgram(initialScene: scene, liveURL: nil, onPreview: {
            pipe.continuation.yield($0)
        }, onLiveStatus: { _ in })
        program.screen(screen)
        program.camera(camera)
        try program.start()
        let timeout = Task {
            try await Task.sleep(nanoseconds: 4_000_000_000)
            pipe.continuation.finish()
        }
        defer { timeout.cancel(); program.stop(); pipe.continuation.finish() }
        for await image in pipe.stream { return image }
        throw CameraBackdropError.frame
    }

    static func makePixel(_ image: CIImage) -> CVPixelBuffer {
        var pixel: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]] as CFDictionary, &pixel) == kCVReturnSuccess)
        CVBufferSetAttachment(pixel!, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        context.render(image, to: pixel!, bounds: frame, colorSpace: space)
        return pixel!
    }

    static func sample(pixel: CVPixelBuffer, tick: Int) -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 4), presentationTimeStamp: CMTime(value: Int64(tick), timescale: 4), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format!,
                                                 sampleTiming: &timing, sampleBufferOut: &result)
        return result!
    }

    static func pixels(_ image: CIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: frame, format: .RGBA8, colorSpace: space)
        return bytes
    }

    static func difference(_ a: [UInt8], _ b: [UInt8], box: (Int, Int, Int, Int)) -> Double {
        let (x0, y0, x1, y1) = box
        var total = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let offset = (y * width + x) * 4
                for c in 0..<3 { total += abs(Int(a[offset + c]) - Int(b[offset + c])) }
            }
        }
        return Double(total) / Double((x1 - x0) * (y1 - y0) * 3)
    }

    static func contrast(_ bytes: [UInt8]) -> Double {
        var total = 0
        for y in 20..<180 {
            for x in 20..<105 {
                total += abs(Int(bytes[(y * width + x) * 4]) - Int(bytes[(y * width + x + 16) * 4]))
            }
        }
        return Double(total) / Double(160 * 85)
    }
}
