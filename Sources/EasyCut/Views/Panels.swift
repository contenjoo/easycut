import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension EditorStore {
    /// 목록과 인스펙터는 값 복사본·개별 초안 대신 같은 현재 자막을 읽는다.
    func captionTextBinding(_ id: UUID) -> Binding<String> {
        Binding(
            get: { self.project.captions.first(where: { $0.id == id })?.text ?? "" },
            set: { value in
                guard let current = self.project.captions.first(where: { $0.id == id }), current.text != value else { return }
                self.updateCaption(id, key: "text") { $0.text = value }
            }
        )
    }
}

// MARK: 미디어 목록

struct MediaBinPanel: View {
    @ObservedObject var store: EditorStore
    @ObservedObject var media: MediaCache
    @State private var dropping = false

    let columns = [GridItem(.adaptive(minimum: 130), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 9) {
                HStack {
                    Text("미디어").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("\(store.project.assets.count)개").font(.caption).foregroundStyle(.secondary)
                }
                Button { store.importPanel() } label: {
                    Label("파일 가져오기", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.regular)
                .help("영상·오디오·사진 가져오기 (⌘I)")
                HStack {
                    Button { store.showLinkSheet = true } label: { Label("링크로 가져오기", systemImage: "link") }
                        .help("유튜브 등 영상 링크로 가져오기 (⇧⌘I)")
                    Spacer(minLength: 5)
                    Button { store.recording.open() } label: { Label("녹화", systemImage: "record.circle") }
                        .help("화면·얼굴 녹화 (⌥⌘R)")
                }
                .font(.caption).buttonStyle(.borderless).controlSize(.small)
            }
            .padding(12)
            ForEach(store.converting.keys.sorted(), id: \.self) { name in
                if let job = store.converting[name] {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(name) 가져오는 중").font(.caption.weight(.semibold)).lineLimit(1)
                        ProgressView(value: job.value)
                        Text(L(job.message)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.bottom, 8)
                }
            }
            Divider()
            ScrollView {
                if store.project.assets.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down").font(.system(size: 34)).foregroundStyle(.secondary)
                        Text("파일을 여기로 끌어다 놓으세요").font(.headline)
                        Text("MP4 · MOV · M4V · MKV · WEBM · AVI\nMP3 · WAV · M4A · AAC · PNG · JPG · HEIC · GIF")
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
                Button(L(asset.words == nil ? "음성 인식 (STT)" : "음성 다시 인식")) { store.transcribe(asset.id) }
            }
            Divider()
            Button("Finder에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: asset.originalPath ?? asset.path)]) }
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
            HStack(spacing: 6) {
                Toggle(isOn: $store.captionCutsVideo) {
                    Text("자막을 지우면 영상도 함께 삭제").font(.caption)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.bottom, 6)
            .help("켜면 자막 한 줄을 지울 때 그 말이 나오는 영상 구간도 잘려 나갑니다. 목록에서 줄을 끌어 순서를 바꾸면 영상도 함께 옮겨집니다.")
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
                        // 글자를 바꿀 때 List의 데이터 항목 자체는 유지해 native 편집기를 보존한다.
                        ForEach(store.project.captions.map(\.id), id: \.self) { id in
                            CaptionRow(store: store, captionID: id).tag(id).id(id)
                        }
                        // 끌어서 순서 바꾸기 → 영상 구간도 함께 이동
                        .onMove { src, dst in store.moveCaptions(from: src, to: dst) }
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
    let captionID: UUID

    var body: some View {
        if let caption = store.project.captions.first(where: { $0.id == captionID }) {
            HStack(alignment: .top, spacing: 8) {
                Button { store.seek(caption.start); store.selectedCaption = caption.id } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(TimeFormat.clock(caption.start))
                        Text(TimeFormat.clock(caption.end)).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10, design: .monospaced))
                }
                .buttonStyle(.borderless)
                CaptionTextEditor(text: store.captionTextBinding(caption.id), label: L("자막"))
                    .frame(height: 54)
                Button { store.deleteCaptions([caption.id]) } label: {
                    Image(systemName: store.captionCutsVideo ? "scissors.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(store.captionCutsVideo ? Color.red.opacity(0.8) : .secondary)
                }
                .buttonStyle(.borderless)
                .help(L(store.captionCutsVideo ? "자막과 그 구간 영상 삭제" : "자막만 삭제"))
            }
            .padding(.vertical, 2)
        }
    }
}

struct CaptionStyleEditor: View {
    @ObservedObject var store: EditorStore
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ScrollView {
                TextStyleControls(style: Binding<TextStyle>(
                    get: { store.project.captionStyle },
                    set: { v in store.updateProject(key: "capstyle") { $0.captionStyle = v } }
                ), showPosition: true, preview: { store.previewSelectedEffect(captionsOnly: true) })
                .padding(.top, 12)
            }
            .frame(maxHeight: 440)
        } label: {
            HStack {
                Text("자막 스타일").font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(FontList.displayName(for: store.project.captionStyle.fontName))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(12)
    }
}

struct TextStyleControls: View {
    @Binding var style: TextStyle
    var showPosition: Bool
    var showEffects = true
    var preview: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FontFamilyPicker(fontName: $style.fontName)
            ValueSlider(title: "글자 크기", value: $style.fontSize, range: 16...200) { "\(Int($0))" }
            HStack(spacing: 8) {
                Toggle(isOn: $style.bold) { Label("굵게", systemImage: "bold") }
                Toggle(isOn: $style.outline) { Label("외곽선", systemImage: "character.textbox") }
            }
            .toggleStyle(.button).controlSize(.small)
            Divider()
            SectionTitle(text: "색상")
            HStack(spacing: 12) {
                ColorPicker("글자", selection: colorBinding(\.textColor))
                ColorPicker("배경", selection: colorBinding(\.backgroundColor))
            }
            if style.outline { ColorPicker("외곽선", selection: colorBinding(\.outlineColor)) }
            HStack(spacing: 6) {
                ForEach(Array(Self.swatches.enumerated()), id: \.offset) { index, color in
                    Button { style.textColor = color } label: {
                        Circle().fill(Color(nsColor: color.nsColor))
                            .frame(width: 24, height: 24)
                            .overlay { Circle().strokeBorder(Theme.inspectorBorder, lineWidth: 1) }
                            .padding(3)
                            .overlay { Circle().strokeBorder(style.textColor == color ? Theme.accentColor : .clear, lineWidth: 1.5) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L(Self.swatchNames[index]))
                }
                Spacer(minLength: 0)
            }
            SectionTitle(text: "빠른 스타일")
            HStack(spacing: 7) {
                styleCard("자막", sample: "가나다", text: .white, background: .captionBG, index: 0)
                styleCard("제목", sample: "가나다", text: .white, background: .clear, index: 1)
                styleCard("강조", sample: "가나다", text: .yellow, background: .clear, index: 2)
            }
            if showPosition {
                Divider()
                ValueSlider(title: "세로 위치", value: $style.positionY, range: 0.05...0.95) { "\(Int($0 * 100))%" }
            }
            if showEffects {
                Divider()
                TextEffectGallery(style: $style, preview: preview)
            }
        }
        .font(.callout)
    }

    private static let swatches: [RGBA] = [.white, .black, .yellow,
        RGBA(r: 0.4, g: 0.9, b: 0.7, a: 1), RGBA(r: 0.35, g: 0.7, b: 1, a: 1), RGBA(r: 1, g: 0.5, b: 0.45, a: 1)]
    private static let swatchNames = ["흰색", "검정", "노랑", "민트", "하늘색", "코랄"]

    private func styleCard(_ label: String, sample: String, text: RGBA, background: RGBA, index: Int) -> some View {
        Button {
            style.textColor = text
            style.backgroundColor = background
            style.outline = index != 0
            style.outlineColor = .black
            style.fontSize = index == 1 ? 96 : (index == 2 ? 64 : 54)
        } label: {
            VStack(spacing: 6) {
                Text(sample).font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color(nsColor: text.nsColor))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Color(nsColor: background.nsColor), in: RoundedRectangle(cornerRadius: 4))
                    .shadow(color: index == 0 ? .clear : .black.opacity(0.85), radius: 1)
                    .frame(maxWidth: .infinity, minHeight: 35)
                    .background(Color.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 6))
                Text(L(label)).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity).padding(7)
            .background(Theme.inspectorCard, in: RoundedRectangle(cornerRadius: 8))
            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.inspectorBorder, lineWidth: 0.7) }
        }.buttonStyle(.plain)
    }

    func colorBinding(_ kp: WritableKeyPath<TextStyle, RGBA>) -> Binding<Color> {
        Binding<Color>(get: { Color(nsColor: style[keyPath: kp].nsColor) },
                       set: { style[keyPath: kp] = RGBA(NSColor($0)) })
    }
}

// MARK: 속성(인스펙터)

struct InspectorPanel: View {
    @ObservedObject var store: EditorStore
    @State private var section: InspectorSection = .basic

    private var selectedClip: Clip? {
        guard store.selection.count == 1, let id = store.selection.first else { return nil }
        return store.project.clip(id)
    }
    private var selectedCaption: Caption? {
        guard store.selection.isEmpty, let id = store.selectedCaption else { return nil }
        return store.project.captions.first { $0.id == id }
    }
    private var contextID: String {
        selectedClip?.id.uuidString ?? selectedCaption?.id.uuidString ?? (store.selection.count > 1 ? "multiple" : "project")
    }
    private var contextTitle: String {
        if let clip = selectedClip { return clip.kind == .text ? L("텍스트") : (store.project.asset(clip.assetID)?.name ?? L("클립")) }
        if selectedCaption != nil { return L("자막") }
        return store.selection.count > 1 ? L("여러 클립") : L("프로젝트")
    }
    private var contextSymbol: String {
        if let clip = selectedClip {
            if clip.kind == .text { return "textformat" }
            switch store.project.asset(clip.assetID)?.kind { case .audio: return "waveform"; case .image: return "photo"; default: return "film" }
        }
        return selectedCaption != nil ? "captions.bubble" : "slider.horizontal.3"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 10) {
                    Image(systemName: contextSymbol).font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.secondary).frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(contextTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        if let clip = selectedClip {
                            Text("시작 \(TimeFormat.clock(clip.start)) · 길이 \(TimeFormat.clock(clip.duration))")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        } else if let caption = selectedCaption {
                            Text("\(TimeFormat.clock(caption.start)) – \(TimeFormat.clock(caption.end))")
                                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                        } else {
                            Text("편집 속성").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                if selectedClip != nil || selectedCaption != nil { InspectorTabBar(selection: $section) }
            }
            .padding(14)
            .accessibilityIdentifier("inspector-context-header")
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let clip = selectedClip {
                        ClipInspector(store: store, clip: clip, section: section).id(clip.id)
                    } else if store.selection.count > 1 {
                        MultiInspector(store: store)
                    } else if let caption = selectedCaption {
                        CaptionInspector(store: store, caption: caption, section: section).id(caption.id)
                    } else {
                        ProjectInspector(store: store)
                    }
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onChange(of: contextID, initial: true) { _, _ in
            if let clip = selectedClip, clip.kind != .text, store.project.asset(clip.assetID)?.kind != .audio { section = .effects }
            else { section = .basic }
        }
    }
}

struct SectionTitle: View {
    let text: String
    var body: some View { Text(L(text)).font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase) }
}

struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        HStack {
            Text(L(title)).frame(width: 58, alignment: .leading)
            EZSlider(value: $value, in: range)
            Text(format(value)).monospacedDigit().font(.caption).frame(width: 46, alignment: .trailing)
        }
    }
}

struct ClipInspector: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    var section: InspectorSection = .basic
    @State private var showingTextTransitions = false
    @State private var showingFilters = false

    var asset: MediaAsset? { store.project.asset(clip.assetID) }
    private var isText: Bool { clip.kind == .text }
    private var isAudio: Bool { !isText && asset?.kind == .audio }
    private var textStyle: Binding<TextStyle> {
        Binding<TextStyle>(get: { clip.textStyle }, set: { v in store.updateClip(clip.id, key: "tstyle") { $0.textStyle = v } })
    }

    func bind(_ kp: WritableKeyPath<Clip, Double>, key: String) -> Binding<Double> {
        Binding<Double>(get: { clip[keyPath: kp] }, set: { v in store.updateClip(clip.id, key: key) { $0[keyPath: kp] = v } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch section {
            case .basic: basicControls
            case .effects: effectControls
            case .layout: layoutControls
            }
            Divider()
            HStack(spacing: 10) {
                Button { store.splitAtPlayhead() } label: { Label("분할", systemImage: "scissors") }
                Button { store.duplicateSelection() } label: { Label("복제", systemImage: "plus.square.on.square") }
                Spacer(minLength: 0)
                Button(role: .destructive) { store.deleteSelection(ripple: true) } label: { Label("삭제", systemImage: "trash") }
            }
            .buttonStyle(.borderless).controlSize(.small).font(.caption)
        }
        .font(.callout)
    }

    @ViewBuilder private var basicControls: some View {
        if isText {
            SectionTitle(text: "내용")
            TextEditor(text: Binding<String>(get: { clip.text }, set: { v in store.updateClip(clip.id, key: "text") { $0.text = v } }))
                .font(.body).scrollContentBackground(.hidden).padding(7).frame(height: 80)
                .background(Theme.inspectorInset, in: RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.inspectorBorder, lineWidth: 0.7) }
            TextStyleControls(style: textStyle, showPosition: false, showEffects: false)
        } else {
            if asset?.kind == .video || asset?.kind == .audio {
                SectionTitle(text: "속도 (최대 20배)")
                HStack {
                    EZSlider(value: Binding<Double>(get: { log(clip.speed) }, set: { v in
                        store.setSpeed((exp(v) * 100).rounded() / 100, for: [clip.id])
                    }), in: log(0.1)...log(20))
                    Text(TimelineNSView.speedLabel(clip.speed)).monospacedDigit().frame(width: 46)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                    ForEach([0.5, 1, 1.5, 2, 3, 4, 8, 10, 16, 20], id: \.self) { s in
                        Button(TimelineNSView.speedLabel(s)) { store.setSpeed(s, for: [clip.id]) }
                            .buttonStyle(.bordered).tint(abs(clip.speed - s) < 0.001 ? .accentColor : nil)
                    }
                }.controlSize(.small)
                Divider()
                SectionTitle(text: "오디오")
                ValueSlider(title: "볼륨", value: bind(\.volume, key: "vol"), range: 0...2) { "\(Int($0 * 100))%" }
                HStack {
                    Button(L(clip.volume == 0 ? "소리 켜기" : "음소거")) { store.updateClip(clip.id, key: "mute") { $0.volume = $0.volume == 0 ? 1 : 0 } }
                    if let a = asset, a.hasAudio {
                        Button(L(a.words == nil ? "음성 인식" : "다시 인식")) { store.transcribe(a.id) }
                    }
                }.controlSize(.small)
            } else {
                SectionTitle(text: "이미지")
                Text(asset?.name ?? L("클립")).font(.callout).foregroundStyle(.secondary)
                if let asset { Text("\(Int(asset.width)) × \(Int(asset.height))").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
        }
    }

    @ViewBuilder private var effectControls: some View {
        if isAudio {
            fadeControls
        } else {
            if isText {
                Picker("효과 종류", selection: $showingTextTransitions) {
                    Text("텍스트").tag(false)
                    Text("전환").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("effect-kind-picker")
                if showingTextTransitions { transitionGallery }
                else { TextEffectGallery(style: textStyle, preview: { store.previewSelectedEffect() }) }
            } else {
                Picker("효과 종류", selection: $showingFilters) {
                    Text("전환").tag(false)
                    Text("필터").tag(true)
                }.pickerStyle(.segmented).accessibilityIdentifier("effect-kind-picker")
                if showingFilters {
                    VisualFilterGallery(filter: Binding<VisualFilter?>(
                        get: { clip.visualFilter }, set: { v in store.updateClip(clip.id, key: "filter") { $0.visualFilter = v } }
                    ), intensity: Binding<Double?>(
                        get: { clip.filterIntensity }, set: { v in store.updateClip(clip.id, key: "filter-intensity") { $0.filterIntensity = v } }
                    ), preview: { store.previewSelectedEffect() })
                } else { transitionGallery }
            }
            Divider()
            DisclosureGroup("페이드 세부 설정") { fadeControls.padding(.top, 10) }
        }
    }

    private var transitionGallery: some View {
        ClipTransitionGallery(entrance: Binding<TransitionSettings?>(
            get: { clip.transitionIn }, set: { v in store.updateClip(clip.id, key: "transition-in") { $0.transitionIn = v } }
        ), exit: Binding<TransitionSettings?>(
            get: { clip.transitionOut }, set: { v in store.updateClip(clip.id, key: "transition-out") { $0.transitionOut = v } }
        ), preview: { fromEnd in store.previewSelectedEffect(fromEnd: fromEnd) })
    }

    private var fadeControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(text: isAudio ? "소리 페이드" : "화면·소리 페이드")
            ValueSlider(title: "페이드 인", value: bind(\.fadeIn, key: "fi"), range: 0...3) { String(format: L("%.1f초"), $0) }
            ValueSlider(title: "페이드 아웃", value: bind(\.fadeOut, key: "fo"), range: 0...3) { String(format: L("%.1f초"), $0) }
        }
    }

    @ViewBuilder private var layoutControls: some View {
        if isAudio {
            Text("오디오 클립에는 화면 배치가 없습니다.").font(.callout).foregroundStyle(.secondary)
        } else {
            SectionTitle(text: "화면 배치")
            HStack(spacing: 7) {
                Button("전체") { store.updateClip(clip.id, key: "layout") { $0.scale = 1; $0.offsetX = 0; $0.offsetY = 0 } }
                Button("PIP ↘") { store.updateClip(clip.id, key: "layout") { $0.scale = 0.3; $0.offsetX = 0.33; $0.offsetY = 0.32 } }
                Button("PIP ↙") { store.updateClip(clip.id, key: "layout") { $0.scale = 0.3; $0.offsetX = -0.33; $0.offsetY = 0.32 } }
            }.controlSize(.small)
            ValueSlider(title: "크기", value: bind(\.scale, key: "scale"), range: 0.1...4) { "\(Int($0 * 100))%" }
            ValueSlider(title: "가로 위치", value: bind(\.offsetX, key: "ox"), range: -1...1) { String(format: "%.2f", $0) }
            ValueSlider(title: "세로 위치", value: bind(\.offsetY, key: "oy"), range: -1...1) { String(format: "%.2f", $0) }
            if isText {
                ValueSlider(title: "텍스트 위치", value: Binding<Double>(
                    get: { clip.textStyle.positionY }, set: { v in store.updateClip(clip.id, key: "tstyle-position") { $0.textStyle.positionY = v } }
                ), range: 0.05...0.95) { "\(Int($0 * 100))%" }
            }
            ValueSlider(title: "불투명도", value: bind(\.opacity, key: "op"), range: 0...1) { "\(Int($0 * 100))%" }
            Divider()
            HStack {
                Text("모양").font(.caption).frame(width: 58, alignment: .leading)
                Picker("모양", selection: Binding<ClipShape>(get: { clip.shape ?? ClipShape.none },
                    set: { v in store.updateClip(clip.id, key: "shape") { $0.shape = v == ClipShape.none ? nil : v } })) {
                    ForEach(ClipShape.allCases) { Text(L($0.label)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            if asset?.kind == .video || asset?.kind == .image {
                HStack {
                    Text("인물 배경").font(.caption).frame(width: 58, alignment: .leading)
                    Picker("인물 배경", selection: Binding<BackgroundEffect>(get: { clip.backgroundEffect ?? BackgroundEffect.none },
                        set: { v in store.updateClip(clip.id, key: "bgfx") { $0.backgroundEffect = v == BackgroundEffect.none ? nil : v } })) {
                        ForEach(BackgroundEffect.allCases) { Text(L($0.label)).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden()
                }
                .help("사람만 남기고 뒤 배경을 흐리게 하거나 지웁니다 (얼굴 카메라에 알맞음)")
            }
            if let marks = asset?.clicks, !marks.isEmpty {
                Toggle("마우스 클릭 강조 (\(marks.count)번)", isOn: Binding<Bool>(get: { clip.showClicks == true },
                    set: { v in store.updateClip(clip.id, key: "clicks") { $0.showClicks = v ? true : nil } })).font(.caption)
            }
            if !isText && (asset?.kind == .video || asset?.kind == .image) {
                Divider()
                DisclosureGroup("개인정보 가리기") {
                    PrivacySection(store: store, clip: clip, isImage: asset?.kind == .image).padding(.top, 10)
                }
            }
        }
    }
}

/// 개인정보 가리기: 화면 글자·얼굴을 읽어 자동으로 찾거나 직접 영역을 그린다
struct PrivacySection: View {
    @ObservedObject var store: EditorStore
    let clip: Clip
    let isImage: Bool
    @AppStorage("privacyPatterns") private var patterns = true
    @AppStorage("privacyFaces") private var faces = false
    @AppStorage("privacyKeywords") private var keywords = ""
    @AppStorage("blurStyle") private var styleRaw = BlurStyle.blur.rawValue

    var style: BlurStyle { BlurStyle(rawValue: styleRaw) ?? .blur }

    var options: PrivacyScanner.Options {
        var o = PrivacyScanner.Options()
        o.patterns = patterns
        o.faces = faces
        o.keywords = keywords.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return o
    }

    var body: some View {
        let regions = clip.blurs ?? []
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(text: "가리기 (개인정보)")
            if let job = store.privacyScanning[clip.id] {
                HStack {
                    ProgressView(value: job.value).controlSize(.small)
                    Text("\(Int(job.value * 100))%").monospacedDigit().font(.caption)
                    if store.canCancelPrivacyScan(clip.id) { Button("중지") { store.cancelPrivacyScan(clip.id) }.controlSize(.small) }
                }
                Text(L(job.message)).font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("전화·주민·카드·계좌번호, 이메일", isOn: $patterns).font(.caption)
                Toggle("얼굴", isOn: $faces).font(.caption)
                TextField("이름·주소 등 가릴 글자 (쉼표로 구분)", text: $keywords)
                    .textFieldStyle(.roundedBorder).font(.caption)
                HStack {
                    Text("방식").font(.caption).frame(width: 58, alignment: .leading)
                    Picker("", selection: $styleRaw) {
                        ForEach(BlurStyle.allCases) { Text(L($0.label)).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }
                HStack {
                    Button { store.scanPrivacy(clip.id, options: options, style: style) } label: {
                        Label("자동으로 찾아 가리기", systemImage: "eye.slash")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!patterns && !faces && options.keywords.isEmpty)
                    .help("화면 글자를 읽어(OCR) 개인정보가 보이는 자리와 시간을 찾습니다. 다시 찾으면 자동으로 찾은 영역은 새로 바뀌고, 직접 그린 영역은 남습니다.")
                    Button {
                        if store.time < clip.start || store.time >= clip.end { store.seek(clip.start) }
                        store.player.pause()
                        store.drawingBlur.toggle()
                    } label: { Label(store.drawingBlur ? "그리기 취소" : "직접 그리기", systemImage: "rectangle.dashed") }
                    .help("미리보기 화면에서 끌어서 가릴 영역을 그립니다 (재생헤드부터 클립 끝까지)")
                }
                .controlSize(.small)
            }
            if !regions.isEmpty {
                ForEach(regions) { r in row(r) }
                HStack {
                    Text("\(regions.count)곳 가림").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Menu("방식 모두 바꾸기") {
                        ForEach(BlurStyle.allCases) { st in
                            Button(L(st.label)) { store.updateClip(clip.id, key: "blurstyle") { c in for i in c.blurs?.indices ?? 0..<0 { c.blurs?[i].style = st } } }
                        }
                    }
                    .fixedSize()
                    Button("모두 지우기", role: .destructive) { store.removeBlurs(clip.id) }
                }
                .controlSize(.small)
                Text("미리보기를 멈춘 상태에서 영역을 끌어 옮기고, 오른쪽 아래 점으로 크기를 바꿉니다. 영역을 고르고 ⌫로 지웁니다.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    func row(_ r: BlurRegion) -> some View {
        let selected = store.selectedBlur == r.id
        let a = clip.timelineTime(atSource: max(r.start, clip.sourceIn))
        let b = clip.timelineTime(atSource: min(r.end, clip.sourceOut))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: r.label == "얼굴" ? "face.smiling" : (r.label == EditorStore.manualBlurLabel ? "rectangle.dashed" : "text.viewfinder"))
                    .foregroundStyle(selected ? Theme.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(L(r.label)).font(.caption.weight(.semibold))
                    if let t = r.text { Text(t).font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if !isImage {
                    Text("\(TimeFormat.clock(a))~\(TimeFormat.clock(b))").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Button { store.removeBlurs(clip.id, [r.id]) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("이 영역 지우기")
            }
            if selected {
                Picker("", selection: Binding(get: { r.style }, set: { v in store.updateBlur(clip.id, r.id, key: "blurstyle") { $0.style = v } })) {
                    ForEach(BlurStyle.allCases) { Text(L($0.label)).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small)
                if !isImage {
                    HStack {
                        Button("시작=재생헤드") {
                            let s = clip.sourceTime(atTimeline: store.time)
                            store.updateBlur(clip.id, r.id, key: "blurtime") { $0.start = s }
                        }
                        Button("끝=재생헤드") {
                            let s = clip.sourceTime(atTimeline: store.time)
                            store.updateBlur(clip.id, r.id, key: "blurtime") { $0.end = s }
                        }
                    }
                    .controlSize(.small)
                    .disabled(store.time < clip.start || store.time > clip.end)
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.accentColor.opacity(0.12) : Color.secondary.opacity(0.06)))
        .contentShape(Rectangle())
        .onTapGesture {
            store.selectedBlur = r.id
            store.player.pause()
            if !isImage, !r.isActive(atSource: clip.sourceTime(atTimeline: store.time)) || store.time < clip.start || store.time >= clip.end {
                store.seek(min(max(a, clip.start), clip.end - 0.05) + 0.001)
            }
        }
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
    var section: InspectorSection = .basic

    private var style: Binding<TextStyle> {
        Binding<TextStyle>(get: { store.project.captionStyle }, set: { v in store.updateProject(key: "capstyle") { $0.captionStyle = v } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch section {
            case .basic:
                SectionTitle(text: "내용")
                CaptionTextEditor(text: store.captionTextBinding(caption.id))
                    .frame(height: 76).padding(4)
                    .background(Theme.inspectorInset, in: RoundedRectangle(cornerRadius: 8))
                    .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.inspectorBorder, lineWidth: 0.7) }
                SectionTitle(text: "전체 자막 스타일")
                TextStyleControls(style: style, showPosition: false, showEffects: false)
            case .effects:
                TextEffectGallery(style: style, preview: { store.previewSelectedEffect(captionsOnly: true) })
                Text("모든 자막에 같은 효과가 적용됩니다.").font(.caption2).foregroundStyle(.secondary)
            case .layout:
                SectionTitle(text: "표시 시간")
                ValueSlider(title: "시작", value: Binding<Double>(get: { caption.start }, set: { v in store.updateCaption(caption.id, key: "s") { $0.start = v } }),
                    range: 0...max(caption.end, store.project.duration)) { TimeFormat.clock($0) }
                ValueSlider(title: "끝", value: Binding<Double>(get: { caption.end }, set: { v in store.updateCaption(caption.id, key: "e") { $0.end = v } }),
                    range: 0...max(caption.end + 10, store.project.duration)) { TimeFormat.clock($0) }
                HStack {
                    Button("시작=재생헤드") { let t = store.time; store.updateCaption(caption.id, key: "s") { $0.start = t } }
                    Button("끝=재생헤드") { let t = store.time; store.updateCaption(caption.id, key: "e") { $0.end = t } }
                }.controlSize(.small)
                Divider()
                SectionTitle(text: "전체 자막 위치")
                ValueSlider(title: "세로 위치", value: Binding<Double>(
                    get: { store.project.captionStyle.positionY }, set: { v in store.updateProject(key: "capstyle-position") { $0.captionStyle.positionY = v } }
                ), range: 0.05...0.95) { "\(Int($0 * 100))%" }
            }
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
            Text("클립을 선택하면 글꼴·효과·배치를 바꿀 수 있습니다.").font(.caption).foregroundStyle(.secondary)
            SectionTitle(text: "화면 크기")
            Picker("", selection: Binding(get: { "\(Int(p.canvasWidth))x\(Int(p.canvasHeight))" }, set: { v in
                if let pr = CanvasPreset.all.first(where: { "\(Int($0.w))x\(Int($0.h))" == v }) {
                    store.updateProject(key: "canvas") { $0.canvasWidth = pr.w; $0.canvasHeight = pr.h }
                }
            })) {
                ForEach(CanvasPreset.all) { Text(L($0.id)).tag("\(Int($0.w))x\(Int($0.h))") }
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
