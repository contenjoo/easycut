import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: 미디어 목록

struct MediaBinPanel: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var media: MediaCache
    @State private var dropping = false

    let columns = [GridItem(.adaptive(minimum: 130), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { store.importPanel() } label: { Label("가져오기", systemImage: "plus") }
                    .buttonStyle(.borderedProminent)
                    .help("영상·오디오·사진 가져오기 (⌘I)")
                Spacer()
                Text("\(store.project.assets.count)개").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            ScrollView {
                if store.project.assets.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("파일을 여기로 끌어다 놓으세요").font(.headline)
                        Text("MP4 · MOV · M4V · MP3 · WAV · M4A · AAC\nPNG · JPG · HEIC · GIF · TIFF")
                            .font(.caption).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(store.project.assets) { a in
                            AssetTile(store: store, media: media, asset: a)
                        }
                    }
                    .padding(10)
                }
            }
            .background(dropping ? Theme.accentColor.opacity(0.12) : .clear)
            .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
                loadURLs(providers) { store.importFiles($0) }
                return true
            }
            Divider()
            Text("타일을 타임라인으로 끌어다 놓거나 더블클릭하세요")
                .font(.caption2).foregroundStyle(.secondary).padding(6)
        }
    }
}

struct AssetTile: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var media: MediaCache
    let asset: MediaAsset

    var icon: String {
        switch asset.kind { case .video: return "film"; case .audio: return "waveform"; case .image: return "photo" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.5))
                if let cg = media.thumbnail(asset.id) {
                    Image(decorative: cg, scale: 1).resizable().aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                } else {
                    Image(systemName: icon).font(.system(size: 26)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                HStack(spacing: 3) {
                    if asset.words != nil { Image(systemName: "text.bubble.fill").foregroundStyle(.green) }
                    if store.transcribing[asset.id] != nil { ProgressView().controlSize(.mini) }
                    if asset.kind != .image { Text(TimeFormat.short(asset.duration)) }
                }
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                .foregroundStyle(.white)
                .padding(4)
                if asset.isMissing {
                    Text("파일 없음").font(.caption.bold()).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 4) {
                Image(systemName: icon).font(.caption2).foregroundStyle(.secondary)
                Text(asset.name).font(.caption).lineLimit(1).truncationMode(.middle)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.addToTimeline(asset.id) }
        .onDrag { NSItemProvider(object: asset.id.uuidString as NSString) }
        .onAppear { media.prepare(asset) }
        .contextMenu {
            Button("타임라인에 추가") { store.addToTimeline(asset.id) }
            Button("재생헤드 위치에 추가") { store.addToTimeline(asset.id, at: store.time) }
            if asset.hasAudio {
                Button(asset.words == nil ? "음성 인식 (STT)" : "음성 다시 인식") { store.transcribe(asset.id) }
            }
            Divider()
            Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([asset.url]) }
            Button("프로젝트에서 제거", role: .destructive) { store.removeAsset(asset.id) }
        }
        .help(asset.path)
    }
}

// MARK: 자막 목록

struct CaptionsPanel: View {
    @ObservedObject var store: EditorStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { store.generateCaptions() } label: { Label("대본→자막", systemImage: "wand.and.stars") }
                    .buttonStyle(.borderedProminent)
                    .help("음성 인식 결과로 자막 자동 생성 (⇧⌘C)")
                Button { store.addCaption() } label: { Image(systemName: "plus") }
                    .help("재생헤드 위치에 자막 추가")
                Menu {
                    Button("SRT 가져오기…") { store.importSRT() }
                    Button("SRT 내보내기…") { store.exportSRT() }
                    Divider()
                    Button("자막 모두 삭제", role: .destructive) { store.apply { $0.captions = [] } }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Text("\(store.project.captions.count)개").font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
            Divider()
            if store.project.captions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "captions.bubble").font(.system(size: 34)).foregroundStyle(.secondary)
                    Text("자막이 없습니다").font(.headline)
                    Text("음성 인식 후 [대본→자막]을 누르거나\n+ 로 직접 추가하세요.").font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Spacer()
                }.frame(maxWidth: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List(selection: Binding(get: { store.selectedCaption }, set: { store.selectedCaption = $0 })) {
                        ForEach(store.project.captions) { c in
                            CaptionRow(store: store, caption: c).tag(c.id).id(c.id)
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: store.selectedCaption) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            }
            Divider()
            CaptionStyleEditor(store: store)
        }
    }
}

struct CaptionRow: View {
    @ObservedObject var store: EditorStore
    let caption: Caption
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { store.seek(caption.start); store.selectedCaption = caption.id } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(TimeFormat.clock(caption.start))
                    Text(TimeFormat.clock(caption.end)).foregroundStyle(.secondary)
                }
                .font(.system(size: 10, design: .monospaced))
            }
            .buttonStyle(.borderless)
            TextField("자막", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, f in if !f { commit() } }
            Button { store.apply { $0.captions.removeAll { $0.id == caption.id } } } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
        .onAppear { text = caption.text }
        .onChange(of: caption.text) { _, t in if !focused { text = t } }
    }

    func commit() {
        guard text != caption.text else { return }
        let t = text
        store.updateCaption(caption.id, key: "text") { $0.text = t }
    }
}

struct CaptionStyleEditor: View {
    @ObservedObject var store: EditorStore
    @State private var expanded = true

    var body: some View {
        DisclosureGroup("자막 스타일", isExpanded: $expanded) {
            TextStyleControls(style: Binding(
                get: { store.project.captionStyle },
                set: { v in store.updateProject(key: "capstyle") { $0.captionStyle = v } }
            ), showPosition: true)
        }
        .padding(10)
    }
}

struct TextStyleControls: View {
    @Binding var style: TextStyle
    var showPosition: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("크기").frame(width: 44, alignment: .leading)
                Slider(value: $style.fontSize, in: 16...200)
                Text("\(Int(style.fontSize))").monospacedDigit().frame(width: 32)
            }
            HStack {
                Text("글꼴").frame(width: 44, alignment: .leading)
                Picker("", selection: $style.fontName) {
                    Text("시스템 (애플 SD 산돌고딕)").tag("")
                    ForEach(FontList.korean, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
            }
            HStack(spacing: 12) {
                Toggle("굵게", isOn: $style.bold)
                Toggle("외곽선", isOn: $style.outline)
            }
            HStack(spacing: 12) {
                ColorPicker("글자", selection: colorBinding(\.textColor))
                ColorPicker("배경", selection: colorBinding(\.backgroundColor))
                if style.outline { ColorPicker("외곽선", selection: colorBinding(\.outlineColor)) }
            }
            if showPosition {
                HStack {
                    Text("위치").frame(width: 44, alignment: .leading)
                    Slider(value: $style.positionY, in: 0.05...0.95)
                    Text(style.positionY > 0.66 ? "아래" : (style.positionY < 0.33 ? "위" : "가운데")).frame(width: 44)
                }
            }
            HStack(spacing: 6) {
                Text("빠른 스타일").font(.caption).foregroundStyle(.secondary)
                Button("기본") { style.textColor = .white; style.backgroundColor = .captionBG; style.outline = false }
                Button("노랑") { style.textColor = .yellow; style.backgroundColor = .clear; style.outline = true; style.outlineColor = .black }
                Button("흰+외곽") { style.textColor = .white; style.backgroundColor = .clear; style.outline = true; style.outlineColor = .black }
            }
            .controlSize(.small)
        }
        .font(.callout)
    }

    func colorBinding(_ kp: WritableKeyPath<TextStyle, RGBA>) -> Binding<Color> {
        Binding(get: { Color(nsColor: style[keyPath: kp].nsColor) },
                set: { style[keyPath: kp] = RGBA(NSColor($0)) })
    }
}

enum FontList {
    static let korean: [String] = {
        let wanted = ["AppleSDGothicNeo-Bold", "AppleSDGothicNeo-Regular", "AppleMyungjo", "NanumGothic", "NanumGothicBold",
                      "NanumMyeongjo", "NanumBarunGothic", "NanumSquareRoundB", "BMJUAOTF", "BMHANNAProOTF",
                      "Pretendard-Bold", "Pretendard-Regular", "SpoqaHanSansNeo-Bold", "GmarketSansBold",
                      "Helvetica-Bold", "Avenir-Heavy", "Futura-Bold", "Menlo-Regular"]
        let available = Set(NSFontManager.shared.availableFonts)
        return wanted.filter { available.contains($0) }
    }()
}

// MARK: 속성(인스펙터)

struct InspectorPanel: View {
    @ObservedObject var store: EditorStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let id = store.selection.first, store.selection.count == 1, let clip = store.project.clip(id) {
                    ClipInspector(store: store, clip: clip)
                } else if store.selection.count > 1 {
                    MultiInspector(store: store)
                } else if let cid = store.selectedCaption, let cap = store.project.captions.first(where: { $0.id == cid }) {
                    CaptionInspector(store: store, caption: cap)
                } else {
                    ProjectInspector(store: store)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View { Text(text).font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase) }
}

struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        HStack {
            Text(title).frame(width: 58, alignment: .leading)
            Slider(value: $value, in: range)
            Text(format(value)).monospacedDigit().font(.caption).frame(width: 46, alignment: .trailing)
        }
    }
}

struct ClipInspector: View {
    @ObservedObject var store: EditorStore
    let clip: Clip

    var asset: MediaAsset? { store.project.asset(clip.assetID) }

    func bind(_ kp: WritableKeyPath<Clip, Double>, key: String) -> Binding<Double> {
        Binding(get: { clip[keyPath: kp] }, set: { v in store.updateClip(clip.id, key: key) { $0[keyPath: kp] = v } })
    }

    var body: some View {
        let isText = clip.kind == .text
        let kind = asset?.kind
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: isText ? "textformat" : (kind == .video ? "film" : kind == .audio ? "waveform" : "photo"))
                Text(isText ? "텍스트" : (asset?.name ?? "클립")).font(.headline).lineLimit(2)
            }
            Text("시작 \(TimeFormat.clock(clip.start)) · 길이 \(TimeFormat.clock(clip.duration))")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

            if isText {
                SectionTitle(text: "내용")
                TextEditor(text: Binding(get: { clip.text }, set: { v in store.updateClip(clip.id, key: "text") { $0.text = v } }))
                    .font(.body)
                    .frame(height: 70)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
                TextStyleControls(style: Binding(get: { clip.textStyle }, set: { v in store.updateClip(clip.id, key: "tstyle") { $0.textStyle = v } }),
                                  showPosition: true)
            }

            if kind == .video || kind == .audio {
                SectionTitle(text: "속도 (최대 20배)")
                HStack {
                    Slider(value: Binding(get: { log(clip.speed) }, set: { v in
                        let s = (exp(v) * 100).rounded() / 100
                        store.setSpeed(s, for: [clip.id])
                    }), in: log(0.1)...log(20))
                    Text(TimelineNSView.speedLabel(clip.speed)).monospacedDigit().frame(width: 46)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                    ForEach([0.5, 1, 1.5, 2, 3, 4, 8, 10, 16, 20], id: \.self) { s in
                        Button(TimelineNSView.speedLabel(s)) { store.setSpeed(s, for: [clip.id]) }
                            .buttonStyle(.bordered)
                            .tint(abs(clip.speed - s) < 0.001 ? .accentColor : nil)
                    }
                }
                .controlSize(.small)
            }

            if kind == .video || kind == .audio {
                SectionTitle(text: "오디오")
                ValueSlider(title: "볼륨", value: bind(\.volume, key: "vol"), range: 0...2) { "\(Int($0 * 100))%" }
                HStack {
                    Button(clip.volume == 0 ? "소리 켜기" : "음소거") { store.updateClip(clip.id, key: "mute") { $0.volume = $0.volume == 0 ? 1 : 0 } }
                    if let a = asset, a.hasAudio {
                        Button(a.words == nil ? "음성 인식" : "다시 인식") { store.transcribe(a.id) }
                    }
                }
                .controlSize(.small)
            }

            if kind != .audio {
                SectionTitle(text: "화면")
                ValueSlider(title: "크기", value: bind(\.scale, key: "scale"), range: 0.1...4) { "\(Int($0 * 100))%" }
                ValueSlider(title: "가로 위치", value: bind(\.offsetX, key: "ox"), range: -1...1) { String(format: "%.2f", $0) }
                ValueSlider(title: "세로 위치", value: bind(\.offsetY, key: "oy"), range: -1...1) { String(format: "%.2f", $0) }
                ValueSlider(title: "불투명도", value: bind(\.opacity, key: "op"), range: 0...1) { "\(Int($0 * 100))%" }
                HStack {
                    Text("화면 배치").font(.caption).foregroundStyle(.secondary)
                    Button("전체") { store.updateClip(clip.id, key: "layout") { $0.scale = 1; $0.offsetX = 0; $0.offsetY = 0 } }
                    Button("PIP ↘") { store.updateClip(clip.id, key: "layout") { $0.scale = 0.3; $0.offsetX = 0.33; $0.offsetY = 0.32 } }
                    Button("PIP ↙") { store.updateClip(clip.id, key: "layout") { $0.scale = 0.3; $0.offsetX = -0.33; $0.offsetY = 0.32 } }
                }
                .controlSize(.small)
            }

            SectionTitle(text: "전환 (페이드)")
            ValueSlider(title: "페이드 인", value: bind(\.fadeIn, key: "fi"), range: 0...3) { String(format: "%.1f초", $0) }
            ValueSlider(title: "페이드 아웃", value: bind(\.fadeOut, key: "fo"), range: 0...3) { String(format: "%.1f초", $0) }

            Divider()
            HStack {
                Button { store.splitAtPlayhead() } label: { Label("분할", systemImage: "scissors") }
                Button { store.duplicateSelection() } label: { Label("복제", systemImage: "plus.square.on.square") }
                Button(role: .destructive) { store.deleteSelection(ripple: true) } label: { Label("삭제", systemImage: "trash") }
            }
            .controlSize(.small)
        }
        .font(.callout)
    }
}

struct MultiInspector: View {
    @ObservedObject var store: EditorStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(store.selection.count)개 클립 선택됨").font(.headline)
            SectionTitle(text: "한꺼번에 속도 바꾸기")
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                ForEach([0.5, 1, 1.5, 2, 3, 4, 8, 10, 16, 20], id: \.self) { s in
                    Button(TimelineNSView.speedLabel(s)) { store.setSpeed(s) }.buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
            HStack {
                Button(role: .destructive) { store.deleteSelection(ripple: false) } label: { Label("삭제", systemImage: "trash") }
                Button(role: .destructive) { store.deleteSelection(ripple: true) } label: { Label("삭제 후 당기기", systemImage: "arrow.left.to.line") }
            }
            .controlSize(.small)
        }
    }
}

struct CaptionInspector: View {
    @ObservedObject var store: EditorStore
    let caption: Caption

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("자막", systemImage: "captions.bubble").font(.headline)
            TextEditor(text: Binding(get: { caption.text }, set: { v in store.updateCaption(caption.id, key: "text") { $0.text = v } }))
                .frame(height: 70)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.separator))
            ValueSlider(title: "시작", value: Binding(get: { caption.start }, set: { v in store.updateCaption(caption.id, key: "s") { $0.start = v } }),
                        range: 0...max(caption.end, store.project.duration)) { TimeFormat.clock($0) }
            ValueSlider(title: "끝", value: Binding(get: { caption.end }, set: { v in store.updateCaption(caption.id, key: "e") { $0.end = v } }),
                        range: 0...max(caption.end + 10, store.project.duration)) { TimeFormat.clock($0) }
            HStack {
                Button("시작=재생헤드") { let t = store.time; store.updateCaption(caption.id, key: "s") { $0.start = t } }
                Button("끝=재생헤드") { let t = store.time; store.updateCaption(caption.id, key: "e") { $0.end = t } }
            }
            .controlSize(.small)
            Divider()
            SectionTitle(text: "전체 자막 스타일")
            TextStyleControls(style: Binding(get: { store.project.captionStyle },
                                             set: { v in store.updateProject(key: "capstyle") { $0.captionStyle = v } }), showPosition: true)
        }
        .font(.callout)
    }
}

struct CanvasPreset: Identifiable, Hashable {
    let id: String
    let w: Double
    let h: Double
    static let all: [CanvasPreset] = [
        .init(id: "1920×1080 (가로 FHD)", w: 1920, h: 1080),
        .init(id: "3840×2160 (가로 4K)", w: 3840, h: 2160),
        .init(id: "1280×720 (가로 HD)", w: 1280, h: 720),
        .init(id: "1080×1920 (세로 쇼츠/릴스)", w: 1080, h: 1920),
        .init(id: "1080×1080 (정사각형)", w: 1080, h: 1080),
        .init(id: "1080×1350 (4:5 피드)", w: 1080, h: 1350),
    ]
}

struct ProjectInspector: View {
    @ObservedObject var store: EditorStore

    var body: some View {
        let p = store.project
        VStack(alignment: .leading, spacing: 12) {
            Label("프로젝트", systemImage: "rectangle.on.rectangle").font(.headline)
            Text("클립을 선택하면 속도·볼륨·크기를 조절할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
            SectionTitle(text: "화면 크기")
            Picker("", selection: Binding(get: { "\(Int(p.canvasWidth))x\(Int(p.canvasHeight))" }, set: { v in
                if let pr = CanvasPreset.all.first(where: { "\(Int($0.w))x\(Int($0.h))" == v }) {
                    store.updateProject(key: "canvas") { $0.canvasWidth = pr.w; $0.canvasHeight = pr.h }
                }
            })) {
                ForEach(CanvasPreset.all) { Text($0.id).tag("\(Int($0.w))x\(Int($0.h))") }
                if !CanvasPreset.all.contains(where: { $0.w == p.canvasWidth && $0.h == p.canvasHeight }) {
                    Text("\(Int(p.canvasWidth))×\(Int(p.canvasHeight)) (원본)").tag("\(Int(p.canvasWidth))x\(Int(p.canvasHeight))")
                }
            }
            .labelsHidden()
            SectionTitle(text: "프레임 레이트")
            Picker("", selection: Binding(get: { p.fps }, set: { v in store.updateProject(key: "fps") { $0.fps = v } })) {
                ForEach([24.0, 25, 30, 50, 60], id: \.self) { Text("\(Int($0)) fps").tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            ColorPicker("배경색", selection: Binding(get: { Color(nsColor: p.background.nsColor) },
                                                  set: { c in store.updateProject(key: "bg") { $0.background = RGBA(NSColor(c)) } }))
            Divider()
            SectionTitle(text: "요약")
            VStack(alignment: .leading, spacing: 4) {
                Text("전체 길이: \(TimeFormat.clock(p.duration))")
                Text("클립: \(p.tracks.flatMap(\.clips).count)개 · 자막: \(p.captions.count)개")
                Text("대본 단어: \(p.timelineWords().count)개")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            Divider()
            SectionTitle(text: "빠른 작업")
            VStack(alignment: .leading, spacing: 6) {
                Button { store.addTextClip() } label: { Label("텍스트(제목) 추가", systemImage: "textformat") }
                Button { store.addCaption() } label: { Label("자막 추가", systemImage: "captions.bubble") }
                Button { store.snapshot() } label: { Label("현재 장면 PNG 저장", systemImage: "camera") }
                Button { store.showShortcuts = true } label: { Label("단축키 보기", systemImage: "keyboard") }
            }
            .buttonStyle(.borderless)
        }
        .font(.callout)
    }
}
