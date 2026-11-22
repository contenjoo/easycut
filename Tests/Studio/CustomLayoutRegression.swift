import AVFoundation
import AppKit

// Run from the repository root with zsh or bash:
// xcrun swiftc Sources/EasyCut/Engine/{StudioProgram,StudioBroadcast,StudioAudioMix}.swift Sources/EasyCut/Model/{Model,ClipEffects,TimelineOps,StudioRecordingTimeline}.swift Tests/Studio/CustomLayoutRegression.swift -o /tmp/easycut-custom-layout-test && /tmp/easycut-custom-layout-test
enum MediaError: Error { case failed(String) }
enum Tools { static func find(_ name: String) -> String? { nil } }

@main
struct CustomLayoutRegression {
    static let first = StudioCustomLayout(screen: CGRect(x: 0.12, y: 0.08, width: 0.64, height: 0.64),
                                         camera: CGRect(x: 0.35, y: 0.20, width: 0.28, height: 0.28))
    static let screenFirst = StudioCustomLayout(screen: first.screen, camera: first.camera, screenOnTop: true)
    static let second = StudioCustomLayout(screen: CGRect(x: 0.25, y: 0.40, width: 0.60, height: 0.50),
                                          camera: CGRect(x: 0.04, y: 0.03, width: 0.30, height: 0.40), screenOnTop: true)

    static func main() throws {
        try checkTimeline()
        try checkPreview()
        print("PASS custom composition, overlay order, two live layouts, screen-only, editable clips, legacy and saved projects")
    }

    static func checkTimeline() throws {
        let screen = MediaAsset(path: "screen", name: "Screen", kind: .video, duration: 6, width: 160, height: 90, hasAudio: true)
        let camera = MediaAsset(path: "camera", name: "Camera", kind: .video, duration: 6, width: 120, height: 90, hasAudio: false)
        let changes = [StudioSceneChange(time: 0, scene: .custom, customLayout: first),
                       StudioSceneChange(time: 1, scene: .custom, customLayout: screenFirst),
                       StudioSceneChange(time: 2, scene: .custom, customLayout: second),
                       StudioSceneChange(time: 3, scene: .custom, customLayout: second),
                       StudioSceneChange(time: 4, scene: .screen, customLayout: screenFirst)]
        var project = Project()
        let systemAudio = MediaAsset(path: "system", name: "System audio", kind: .audio, duration: 6, width: 0, height: 0, hasAudio: true)
        project.assets = [screen, camera, systemAudio]
        project.insertStudioRecording(screen: screen, camera: camera, audio: systemAudio, changes: changes, showClicks: true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".easycut")
        defer { try? FileManager.default.removeItem(at: file) }
        try JSONEncoder().encode(project).write(to: file)
        let reopened = try JSONDecoder().decode(Project.self, from: Data(contentsOf: file))
        precondition(reopened == project)
        let base = reopened.tracks[0].clips
        let overlay = reopened.tracks[1].clips
        precondition(base.map(\.start) == [0, 1, 2, 4] && overlay.map(\.start) == [0, 1, 2, 4])
        let screens = [base[0], overlay[1], overlay[2], base[3]]
        let cameras = [overlay[0], base[1], base[2], overlay[3]]
        precondition(screens.allSatisfy { $0.assetID == screen.id && $0.volume == 1 && $0.showClicks == true })
        precondition(cameras.allSatisfy { $0.assetID == camera.id && $0.volume == 0 })
        precondition(screens.map(\.sourceIn) == [0, 1, 2, 4] && screens.map(\.sourceOut) == [1, 2, 4, 6])
        precondition(reopened.tracks[2].clips.first?.assetID == systemAudio.id)
        checkGeometry(screens[0], scale: 0.64, x: -0.06, y: -0.10)
        checkGeometry(screens[1], scale: 0.64, x: -0.06, y: -0.10)
        checkGeometry(screens[2], scale: 0.50, x: 0.05, y: 0.15)
        checkGeometry(cameras[0], scale: 0.28, x: -0.01, y: -0.16)
        checkGeometry(cameras[2], scale: 0.40, x: -0.31, y: -0.27)
        precondition(screens[3].scale == 1 && cameras[3].opacity == 0)

        var screenOnly = Project()
        screenOnly.insertStudioRecording(screen: screen, camera: nil, audio: nil, changes: changes, showClicks: false)
        checkGeometry(screenOnly.tracks[0].clips[0], scale: 0.64, x: -0.06, y: -0.10)
        checkGeometry(screenOnly.tracks[0].clips[2], scale: 0.50, x: 0.05, y: 0.15)
        precondition(screenOnly.tracks[1].clips.isEmpty)

        let decoder = JSONDecoder()
        for name in ["screen", "camera", "pictureInPicture", "sideBySide", "pictureInPictureTopLeft", "pictureInPictureTopRight", "pictureInPictureBottomLeft"] {
            let change = try decoder.decode(StudioSceneChange.self, from: Data(#"{"scene":"\#(name)","time":0}"#.utf8))
            precondition(change.scene.rawValue == name && change.customLayout == .standard)
        }
        let oldFile = URL(fileURLWithPath: "windows/crates/easycut-core/tests/fixtures/mac-sample.easycut")
        let legacy = try decoder.decode(Project.self, from: Data(contentsOf: oldFile))
        precondition(legacy.duration > 0 && !legacy.assets.isEmpty)
        let bad = StudioCustomLayout(screen: CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1),
                                     camera: CGRect(x: 5, y: -5, width: 2, height: -1))
        precondition(bad.screen == StudioCustomLayout.standard.screen)
        precondition(bad.camera == CGRect(x: 0, y: 0, width: 1, height: 0.05))
        let oldLayout = try JSONSerialization.data(withJSONObject: ["screen": [[0.12, 0.08], [0.64, 0.64]],
                                                                     "camera": [[0.35, 0.20], [0.28, 0.28]]])
        let savedBeforeLayerOrdering = try decoder.decode(StudioCustomLayout.self, from: oldLayout)
        precondition(savedBeforeLayerOrdering == first && !StudioCustomLayout.standard.screenOnTop)
        let encoded = try JSONEncoder().encode(screenFirst)
        let decoded = try decoder.decode(StudioCustomLayout.self, from: encoded)
        precondition(decoded == screenFirst)
    }

    static func checkGeometry(_ clip: Clip, scale: Double, x: Double, y: Double) {
        precondition(abs(clip.scale - scale) < 0.00001 && abs(clip.offsetX - x) < 0.00001 && abs(clip.offsetY - y) < 0.00001)
    }

    enum Color { case black, red, blue }

    static func checkPreview() throws {
        var latest: CGImage?
        let program = try StudioProgram(initialScene: .custom, customLayout: first, liveURL: nil,
                                        onPreview: { latest = $0 }, onLiveStatus: { _ in })
        program.screen(sample(width: 160, color: 0xFFFF0000))
        try program.start()
        defer { program.stop() }

        // The camera can join later. Screen framing must stay put while the camera is absent.
        func expect(_ samples: [(Double, Double, Color)]) {
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if let image = latest, samples.allSatisfy({ color(image, x: $0.0, y: $0.1) == $0.2 }) { return }
                RunLoop.main.run(until: Date().addingTimeInterval(0.025))
            }
            let observed = latest.map { image in samples.map { String(describing: color(image, x: $0.0, y: $0.1)) } }
            preconditionFailure("Synthetic frame expected \(samples.map { $0.2 }), got \(String(describing: observed))")
        }
        expect([(0.50, 0.31, .red), (0.01, 0.01, .black)])
        program.camera(sample(width: 120, color: 0xFF0000FF))
        expect([(0.15, 0.14, .red), (0.50, 0.31, .blue), (0.36, 0.32, .red), (0.90, 0.85, .black)])
        program.setScene(.custom, customLayout: screenFirst)
        expect([(0.50, 0.31, .red), (0.90, 0.85, .black)])
        program.setScene(.custom, customLayout: first)
        expect([(0.50, 0.31, .blue)])
        program.setScene(.custom, customLayout: second)
        expect([(0.12, 0.15, .blue), (0.50, 0.65, .red), (0.27, 0.70, .black), (0.96, 0.95, .black)])
    }

    static func sample(width: Int, color: UInt32) -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, width, 90, kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess)
        let pixel = buffer!
        CVPixelBufferLockBaseAddress(pixel, [])
        let stride = CVPixelBufferGetBytesPerRow(pixel) / MemoryLayout<UInt32>.stride
        let data = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt32.self)
        for y in 0..<90 {
            for x in 0..<width { data[y * stride + x] = color }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        var description: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &description) == noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: description!,
                                                             sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return sample!
    }

    static func color(_ image: CGImage, x: Double, y: Double) -> Color? {
        let spot = CGRect(x: floor(x * Double(image.width)), y: floor(y * Double(image.height)), width: 1, height: 1)
        guard let cropped = image.cropping(to: spot) else { return nil }
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let rgb = ctx.data!.assumingMemoryBound(to: UInt8.self)
        if rgb[0] > 160 && rgb[2] < 50 { return .red }
        if rgb[2] > 160 && rgb[0] < 50 { return .blue }
        if rgb[0] < 30 && rgb[1] < 30 && rgb[2] < 30 { return .black }
        return nil
    }
}
