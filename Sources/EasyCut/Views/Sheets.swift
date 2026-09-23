import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: 내보내기

struct ExportSheet: View {
    @ObservedObject var store: EditorStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportFormat") private var formatRaw = ExportFormat.mp4H264.rawValue
    @AppStorage("exportRes") private var resolution = 1080
    @AppStorage("exportBurn") private var burnCaptions = true
    @AppStorage("exportSRT") private var alsoSRT = false
    @State private var progress: Double?
    @State private var done: URL?
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var box = Exporter.Box()
    @State private var started = Date()

    var format: ExportFormat { ExportFormat(rawValue: formatRaw) ?? .mp4H264 }

    var outSize: CGSize {
        let p = store.project
        if resolution == 0 { return p.canvasSize }
        let short = Double(resolution)
        let s = short / min(p.canvasWidth, p.canvasHeight)
        return CGSize(width: (p.canvasWidth * s / 2).rounded() * 2, height: (p.canvasHeight * s / 2).rounded() * 2)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("내보내기").font(.title2.bold())
            if let done {
                VStack(alignment: .leading, spacing: 10) {
                    Label("내보내기 완료!", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
                    Text(done.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([done]) }
                        Button("재생") { NSWorkspace.shared.open(done) }
                        Spacer()
                        Button("닫기") { dismiss() }.keyboardShortcut(.defaultAction)
                    }
                }
            } else if let progress {
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView(value: progress)
                    HStack {
                        Text("\(Int(progress * 100))%").monospacedDigit()
                        if progress > 0.03 {
                            let el = Date().timeIntervalSince(started)
                            Text("· 남은 시간 약 \(TimeFormat.short(el / progress - el))").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("취소") {
                            box.session?.cancelExport()
                            task?.cancel()
                        }
                    }
                }
            } else {
                Form {
                    Picker("형식", selection: $formatRaw) {
                        ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0.rawValue) }
                    }
                    if format != .m4a {
                        Picker("해상도", selection: $resolution) {
                            Text("프로젝트 크기 (\(Int(store.project.canvasWidth))×\(Int(store.project.canvasHeight)))").tag(0)
                            Text("2160p (4K)").tag(2160)
                            Text("1080p (FHD)").tag(1080)
                            Text("720p (HD)").tag(720)
                            Text("480p").tag(480)
                        }
                        Toggle("자막을 영상에 입히기", isOn: $burnCaptions)
                    }
                    Toggle("SRT 자막 파일도 함께 저장", isOn: $alsoSRT)
                        .disabled(store.project.captions.isEmpty)
                }
                .formStyle(.grouped)
                Text(format == .m4a ? "길이 \(TimeFormat.clock(store.project.duration))"
                     : "출력 \(Int(outSize.width))×\(Int(outSize.height)) · 길이 \(TimeFormat.clock(store.project.duration))")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                HStack {
                    Spacer()
                    Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("내보내기…") { start() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(store.project.duration <= 0)
                }
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    func start() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: format.ext) ?? .movie]
        panel.nameFieldStringValue = store.baseName + " 편집본." + format.ext
        // 시트 위에 붙여 띄워야 내보내기 창이 닫히지 않는다
        if let host = NSApp.windows.first(where: { $0.isSheet && $0.isVisible }) ?? NSApp.keyWindow {
            panel.beginSheetModal(for: host) { resp in
                if resp == .OK, let url = panel.url { run(to: url) }
            }
        } else if panel.runModal() == .OK, let url = panel.url {
            run(to: url)
        }
    }

    func run(to url: URL) {
        let p = store.project, f = format, size = outSize, burn = burnCaptions, srt = alsoSRT
        error = nil
        progress = 0
        started = Date()
        store.player.pause()
        task = Task {
            do {
                try await Exporter.export(project: p, format: f, size: size, burnCaptions: burn, to: url, cancel: box) { v in
                    Task { @MainActor in if progress != nil { progress = v } }
                }
                if srt, !p.captions.isEmpty {
                    try Exporter.exportSRT(p.captions, to: url.deletingPathExtension().appendingPathExtension("srt"))
                }
                done = url
                progress = nil
            } catch is CancellationError {
                progress = nil
            } catch {
                self.error = error.localizedDescription
                progress = nil
            }
        }
    }
}

// MARK: 음성 인식 설정

struct STTSettingsSheet: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var downloader: ModelDownloader
    @Environment(\.dismiss) private var dismiss
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("음성 인식(STT) 설정").font(.title2.bold())
            Form {
                Picker("언어", selection: $store.sttLanguageID) {
                    ForEach(STTLanguage.all) { Text($0.name).tag($0.id) }
                }
                Picker("엔진", selection: Binding(get: { store.sttEngine }, set: { store.sttEngine = $0 })) {
                    ForEach(STTEngine.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }
            .formStyle(.grouped)

            if store.sttEngine == .apple {
                Text("macOS에 내장된 온디바이스 인식을 사용합니다. 인터넷 없이 동작하며, 처음 실행 시 음성 인식 권한을 허용해 주세요.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: Transcriber.whisperBinary != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(Transcriber.whisperBinary != nil ? .green : .orange)
                        if let b = Transcriber.whisperBinary {
                            Text(b.contains(".app/") ? "Whisper 엔진 내장됨" : "Whisper 엔진: \(b)").font(.callout)
                        } else {
                            VStack(alignment: .leading) {
                                Text("whisper-cli가 필요합니다. 터미널에서 실행:").font(.callout)
                                Text("brew install whisper-cpp").font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                    }
                    Text("모델").font(.headline)
                    ForEach(WhisperModel.all) { m in
                        HStack {
                            Button {
                                store.whisperModelID = m.id
                            } label: {
                                Image(systemName: store.whisperModelID == m.id ? "largecircle.fill.circle" : "circle")
                            }
                            .buttonStyle(.borderless)
                            VStack(alignment: .leading) {
                                Text(m.title)
                                Text("\(m.sizeMB)MB · Hugging Face (ggerganov/whisper.cpp)").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if m.isInstalled {
                                Label("설치됨", systemImage: "checkmark").foregroundStyle(.green).font(.caption)
                            } else if downloader.downloading == m {
                                ProgressView(value: downloader.progress).frame(width: 80)
                                Button("취소") { downloader.cancel() }.controlSize(.small)
                            } else {
                                Button("내려받기") {
                                    Task { await downloader.download(m); refresh += 1 }
                                }
                                .controlSize(.small)
                                .disabled(downloader.downloading != nil)
                            }
                        }
                    }
                    if let e = downloader.error { Text(e).foregroundStyle(.red).font(.caption) }
                    Button("모델 폴더 열기") { NSWorkspace.shared.open(AppPaths.models) }.controlSize(.small)
                }
                .id(refresh)
            }
            HStack {
                Spacer()
                Button("완료") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 520)
    }
}

// MARK: 단축키 도움말

struct Shortcut: Identifiable {
    let id = UUID()
    let keys: String
    let desc: String
}

enum Shortcuts {
    static let groups: [(String, [Shortcut])] = [
        ("재생", [
            .init(keys: "Space", desc: "재생 / 일시정지"),
            .init(keys: "L", desc: "빠르게 (누를수록 2·4·8·16·20배속)"),
            .init(keys: "J", desc: "느리게"),
            .init(keys: "K", desc: "정지"),
            .init(keys: "]  /  [", desc: "재생 속도 올리기 / 내리기"),
            .init(keys: "\\", desc: "1배속으로"),
            .init(keys: "⌥1 … ⌥9, ⌥0", desc: "1·2·3·4·5·8·10·12·16·20배속 바로 선택"),
            .init(keys: ",  /  .", desc: "이전 / 다음 프레임"),
            .init(keys: "←  /  →", desc: "1초 뒤로 / 앞으로"),
            .init(keys: "⇧←  /  ⇧→", desc: "5초 뒤로 / 앞으로"),
            .init(keys: "↑  /  ↓", desc: "이전 / 다음 편집점"),
            .init(keys: "Home  /  End", desc: "처음 / 끝"),
        ]),
        ("컷 편집", [
            .init(keys: "S  또는  ⌘T", desc: "재생헤드에서 분할 (선택 클립, 없으면 전체)"),
            .init(keys: "⇧⌘T", desc: "모든 트랙 분할"),
            .init(keys: "I  /  O", desc: "구간 시작 / 끝 지정"),
            .init(keys: "⌫", desc: "선택 클립 삭제 (구간이 있으면 구간 잘라내기)"),
            .init(keys: "⌘⌫", desc: "삭제 후 빈틈 메우기 (리플 삭제)"),
            .init(keys: "X", desc: "In/Out 구간 지우기"),
            .init(keys: "⌘C / ⌘X / ⌘V", desc: "클립 복사 / 잘라내기 / 재생헤드에 붙여넣기"),
            .init(keys: "⌘D", desc: "클립 복제"),
            .init(keys: "⌘A", desc: "모든 클립 선택"),
            .init(keys: "Esc", desc: "선택 해제"),
            .init(keys: "⌘Z / ⇧⌘Z", desc: "실행 취소 / 다시 실행"),
        ]),
        ("대본 · 자막", [
            .init(keys: "⇧⌘R", desc: "음성 인식 (STT)"),
            .init(keys: "⇧⌘X", desc: "무음 컷 (원클릭, 음성 인식 불필요)"),
            .init(keys: "대본에서 ⌫", desc: "선택한 말을 영상에서 잘라내기"),
            .init(keys: "대본에서 ↩", desc: "단어 고치기"),
            .init(keys: "대본에서 ⌘F", desc: "대본 검색"),
            .init(keys: "⇧⌘C", desc: "대본으로 자막 만들기"),
            .init(keys: "C", desc: "재생헤드에 자막 추가"),
            .init(keys: "자막 탭에서 끌기", desc: "자막과 영상 구간째 순서 바꾸기"),
            .init(keys: "트랙 1 클립 끌기", desc: "끼워 넣어 순서 바꾸기 (⌥+끌기 = 자유 이동)"),
            .init(keys: "T", desc: "재생헤드에 텍스트(제목) 추가"),
        ]),
        ("타임라인 · 파일", [
            .init(keys: "⌘=  /  ⌘-", desc: "타임라인 확대 / 축소 (⌘+스크롤)"),
            .init(keys: "⇧Z", desc: "타임라인 전체 보기"),
            .init(keys: "N", desc: "스냅(자석) 켜기/끄기"),
            .init(keys: "⌘I / ⇧⌘I", desc: "미디어 가져오기 / 링크(유튜브)로 가져오기"),
            .init(keys: "⌘E", desc: "내보내기"),
            .init(keys: "⌘S / ⇧⌘S", desc: "저장 / 다른 이름으로 저장"),
            .init(keys: "⌘O / ⌘N", desc: "열기 / 새 프로젝트"),
            .init(keys: "⌘1 / ⌘2 / ⌘3 / ⌘4", desc: "미디어 / 대본 / 자막 / AI 탭"),
            .init(keys: "⌘/", desc: "이 도움말"),
        ]),
    ]
}

struct ShortcutsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("단축키").font(.title2.bold())
                Spacer()
                Button("닫기") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .top), GridItem(.flexible(), alignment: .top)], spacing: 18) {
                    ForEach(Shortcuts.groups, id: \.0) { g in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(g.0).font(.headline)
                            ForEach(g.1) { s in
                                HStack(alignment: .top) {
                                    Text(s.keys)
                                        .font(.system(.callout, design: .rounded).weight(.semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                                        .frame(width: 150, alignment: .leading)
                                    Text(s.desc).font(.callout)
                                    Spacer(minLength: 0)
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(22)
        .frame(width: 760, height: 560)
    }
}

// MARK: 링크로 가져오기

struct LinkSheet: View {
    @ObservedObject var store: EditorStore
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @AppStorage("linkQuality") private var qualityRaw = LinkImporter.Quality.p1080.rawValue
    @AppStorage("linkSubs") private var subtitles = true
    @State private var partOnly = false
    @State private var from = ""
    @State private var to = ""
    @State private var toolBusy = false
    @State private var toolMsg = ""

    var quality: LinkImporter.Quality { LinkImporter.Quality(rawValue: qualityRaw) ?? .p1080 }
    var valid: Bool { LinkImporter.isLink(link) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("링크로 가져오기", systemImage: "link").font(.title2.bold())
            Text("유튜브 등 영상 페이지 주소를 붙여 넣으세요. 받은 파일은 ‘동영상 › EasyCut 다운로드’ 폴더에 저장됩니다.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("https://www.youtube.com/watch?v=…", text: $link)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if valid { start() } }
            Form {
                Picker("화질", selection: $qualityRaw) {
                    ForEach(LinkImporter.Quality.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                Toggle("업로더가 올린 자막도 받기 (한국어·영어)", isOn: $subtitles)
                    .disabled(quality == .audio)
                Toggle("일부 구간만 받기", isOn: $partOnly)
                if partOnly {
                    HStack {
                        TextField("시작 (예: 1:30)", text: $from)
                        Text("~")
                        TextField("끝 (예: 5:00)", text: $to)
                    }
                }
            }
            .formStyle(.grouped)
            Label("본인 영상이나 저작권자에게 이용 허락을 받은 영상만 내려받아 편집하세요.", systemImage: "exclamationmark.shield")
                .font(.caption).foregroundStyle(.orange)
            HStack(spacing: 8) {
                Image(systemName: LinkImporter.ytdlp == nil ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(LinkImporter.ytdlp == nil ? .orange : .green)
                Text(LinkImporter.ytdlp == nil ? "유튜브 도구(yt-dlp)가 필요합니다" : "유튜브 도구 준비됨 \(toolMsg)").font(.caption)
                Spacer()
                if toolBusy { ProgressView().controlSize(.small) }
                Button(LinkImporter.ytdlp == nil ? "유튜브 도구 설치" : "업데이트") {
                    toolBusy = true
                    Task {
                        do { toolMsg = "(\(try await Tools.installYtdlp { _ in }))" } catch { toolMsg = "설치 실패: \(error.localizedDescription)" }
                        toolBusy = false
                    }
                }
                .controlSize(.small)
                .disabled(toolBusy)
                .help("github.com/yt-dlp 공식 배포본(약 35MB)을 받아 앱 전용 폴더에 설치합니다")
            }
            HStack {
                Button("클립보드에서 붙여넣기") {
                    if let s = NSPasteboard.general.string(forType: .string) { link = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
                Spacer()
                Button("취소") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("가져오기") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid || LinkImporter.ytdlp == nil)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            if let s = NSPasteboard.general.string(forType: .string), LinkImporter.isLink(s) { link = s.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
    }

    func start() {
        var o = LinkImporter.Options()
        o.quality = quality
        o.subtitles = subtitles
        if partOnly {
            o.start = LinkImporter.parseTime(from)
            o.end = LinkImporter.parseTime(to)
        }
        let l = link
        dismiss()
        Task { await store.importLink(l, options: o) }
    }
}
