import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

struct CameraFrameView: View {
    @ObservedObject var frames: CameraPreviewFrames
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black
                if let frame = frames.frame {
                    Image(decorative: frame, scale: 1).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                } else { ProgressView().controlSize(.small) }
            }
        }
    }
}

struct CameraBackdropControl: View {
    @ObservedObject var rec: RecordController
    var compact = false
    @State private var choosing = false

    var body: some View {
        HStack {
            if !compact { Text(verbatim: L("카메라 배경")); Spacer() }
            Button {
                choosing = true
            } label: {
                if compact {
                    Image(systemName: "person.crop.rectangle")
                } else {
                    HStack(spacing: 4) {
                        Text(verbatim: L(rec.backdropChoice.title))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
            }
            .help(L("카메라 배경"))
            .accessibilityLabel(Text(verbatim: L("카메라 배경")))
            .accessibilityValue(Text(verbatim: L(rec.backdropChoice.title)))
            .popover(isPresented: $choosing) { CameraBackdropGallery(rec: rec, duringRecording: compact) }
        }
    }
}

private struct CameraBackdropGallery: View {
    @ObservedObject var rec: RecordController
    let duringRecording: Bool
    @State private var preview: SetupBackdropPreview?
    @State private var previewError: String?
    @State private var previewing = false
    @State private var pickImage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(verbatim: L("카메라 배경")).font(.headline)
                Spacer()
                if !duringRecording {
                    Button {
                        previewing.toggle()
                        previewError = nil
                    } label: {
                        Label(L(previewing ? "미리보기 닫기" : "카메라 미리보기"), systemImage: previewing ? "eye.slash" : "eye")
                    }.controlSize(.small)
                }
            }
            if previewing {
                Group {
                    if let preview, let frames = preview.feed.preview { CameraFrameView(frames: frames) }
                    else if let previewError { Text(verbatim: previewError).font(.caption) }
                    else { ProgressView().controlSize(.small) }
                }
                .frame(maxWidth: .infinity).frame(height: 122)
                .background(.black).foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                option(.off, symbol: "video")
                option(.blur, symbol: "drop.halffull")
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(CameraBackdropChoice.presets) { choice in
                    Button { rec.selectBackdrop(choice) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            if let thumbnail = PresetThumbnails.images[choice] {
                                Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(16/9, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                            HStack {
                                Text(verbatim: L(choice.title)).font(.caption)
                                Spacer()
                                if rec.backdropChoice == choice { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                            }
                        }
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(rec.backdropChoice == choice ? Color.accentColor : Color.secondary.opacity(0.25)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: L(choice.title)))
                    .accessibilityAddTraits(rec.backdropChoice == choice ? .isSelected : [])
                }
            }
            HStack {
                if rec.customBackdrop != nil {
                    option(.custom, symbol: "photo")
                }
                Button { pickImage = true } label: {
                    Label(L("이미지 선택…"), systemImage: "folder")
                }
            }
            if rec.backdropChoice == .custom, let name = rec.customBackdropName {
                Text(verbatim: name).font(.caption).lineLimit(1).truncationMode(.middle)
            }
            if let message = rec.backdropError { Text(verbatim: message).font(.caption).foregroundStyle(.red) }
        }
        .padding(12).frame(width: 284)
        .fileImporter(isPresented: $pickImage, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result { rec.selectBackdrop(.custom, imageURL: url) }
        }
        .task(id: previewing) {
            guard previewing else { stopPreview(); return }
            guard let device = rec.cameras.first(where: { $0.uniqueID == rec.cameraID }),
                  await CaptureDevices.requestAccess(.video) else {
                previewError = L("카메라 연결과 접근 권한을 확인하세요.")
                return
            }
            guard !Task.isCancelled else { return }
            let capture = SetupBackdropPreview(backdrop: rec.backdrop)
            preview = capture
            capture.start(device: device) { [weak capture] error in
                guard let capture, preview === capture else { return }
                previewError = error.localizedDescription
                stopPreview()
            }
        }
        .onReceive(rec.$backdrop) { preview?.feed.setBackdrop($0) }
        .onDisappear { stopPreview() }
    }

    private func option(_ choice: CameraBackdropChoice, symbol: String) -> some View {
        Button { rec.selectBackdrop(choice) } label: {
            Label(L(choice.title), systemImage: rec.backdropChoice == choice ? "checkmark" : symbol)
        }
        .accessibilityAddTraits(rec.backdropChoice == choice ? .isSelected : [])
    }

    private func stopPreview() {
        preview?.stop()
        preview = nil
    }

    private enum PresetThumbnails {
        static let images: [CameraBackdropChoice: CGImage] = Dictionary(uniqueKeysWithValues: CameraBackdropChoice.presets.compactMap { choice in
            guard let url = choice.presetURL, let image = try? CameraBackdropChoice.loadImage(at: url, maxSize: 280) else { return nil }
            return (choice, image)
        })
    }
}

private final class SetupBackdropPreview {
    let feed: CameraFeed
    private let session = AVCaptureSession()
    private let devices = DispatchQueue(label: "easycut.camera.preview")
    init(backdrop: CameraBackdrop) { feed = CameraFeed(backdrop: backdrop, preview: true) }

    func start(device: AVCaptureDevice, onError: @escaping (Error) -> Void) {
        let report: (Error) -> Void = { error in DispatchQueue.main.async { onError(error) } }
        feed.onError = report
        devices.async {
            self.session.beginConfiguration()
            do { try self.feed.addCamera(device, to: self.session) }
            catch {
                self.session.commitConfiguration()
                report(error)
                return
            }
            self.session.commitConfiguration()
            self.session.startRunning()
        }
    }
    func stop() { devices.async { if self.session.isRunning { self.session.stopRunning() } } }
}
