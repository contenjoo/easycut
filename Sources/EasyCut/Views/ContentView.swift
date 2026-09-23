import SwiftUI

struct ContentView: View {
    @ObservedObject var store: EditorStore
    @State private var keyMonitor: KeyMonitor?

    var body: some View {
        VSplitView {
            HSplitView {
                LeftPanel(store: store)
                    .frame(minWidth: 280, idealWidth: 330, maxWidth: 520)
                PreviewPane(store: store, player: store.player)
                    .frame(minWidth: 420, maxWidth: .infinity)
                InspectorPanel(store: store)
                    .frame(minWidth: 240, idealWidth: 280, maxWidth: 380)
            }
            .frame(minHeight: 320, idealHeight: 520)
            VStack(spacing: 0) {
                TimelineToolbar(store: store)
                TimelineContainer(store: store)
            }
            .frame(minHeight: 170, idealHeight: 270)
        }
        .frame(minWidth: 1100, minHeight: 640)
        .toolbar { MainToolbar(store: store) }
        .navigationTitle(store.windowTitle)
        .overlay(alignment: .top) {
            if let t = store.toast {
                Text(t)
                    .font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThickMaterial, in: Capsule())
                    .shadow(radius: 6)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeOut(duration: 0.18), value: store.toast)
        .sheet(isPresented: $store.showExport) { ExportSheet(store: store) }
        .sheet(isPresented: $store.showShortcuts) { ShortcutsSheet() }
        .sheet(isPresented: $store.showSTTSettings) { STTSettingsSheet(store: store, downloader: store.downloader) }
        .sheet(isPresented: $store.showSilenceSheet) { SilenceSheet(store: store) }
        .alert("알림", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("확인") { store.alert = nil }
        } message: {
            Text(store.alert ?? "")
        }
        .onAppear {
            if keyMonitor == nil { keyMonitor = KeyMonitor(store: store) }
            store.control.start()
        }
    }
}

struct LeftPanel: View {
    @ObservedObject var store: EditorStore

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $store.leftTab) {
                ForEach(LeftTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(8)
            Divider()
            switch store.leftTab {
            case .media: MediaBinPanel(store: store, media: store.media)
            case .transcript: TranscriptPanel(store: store)
            case .captions: CaptionsPanel(store: store)
            case .ai: AIPanel(store: store, ai: store.ai)
            }
        }
    }
}

struct MainToolbar: ToolbarContent {
    @ObservedObject var store: EditorStore

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { store.importPanel() } label: { Label("가져오기", systemImage: "square.and.arrow.down") }
                .help("미디어 가져오기 (⌘I)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.undo() } label: { Label("실행 취소", systemImage: "arrow.uturn.backward") }
                .help("실행 취소 (⌘Z)").disabled(!store.canUndo)
            Button { store.redo() } label: { Label("다시 실행", systemImage: "arrow.uturn.forward") }
                .help("다시 실행 (⇧⌘Z)").disabled(!store.canRedo)
            Button { store.splitAtPlayhead() } label: { Label("분할", systemImage: "scissors") }
                .help("재생헤드에서 분할 (S, ⌘T)")
            Button { store.deleteSelection(ripple: true) } label: { Label("삭제", systemImage: "trash") }
                .help("선택 삭제 후 빈틈 메우기 (⌘⌫)")
            Button { store.addTextClip() } label: { Label("텍스트", systemImage: "textformat") }
                .help("텍스트(제목) 추가 (T)")
            Button { store.showSilenceSheet = true } label: { Label("무음 컷", systemImage: "scissors.badge.ellipsis") }
                .help("말 없는 부분 원클릭 삭제 (⇧⌘X)")
            Button { store.transcribeTimeline() } label: { Label("음성 인식", systemImage: "waveform.badge.mic") }
                .help("음성 → 텍스트 (⇧⌘R)")
            Button { store.generateCaptions() } label: { Label("자막 생성", systemImage: "captions.bubble") }
                .help("대본으로 자막 만들기 (⇧⌘C)")
            Button { store.leftTab = .ai } label: { Label("AI 편집", systemImage: "sparkles") }
                .help("말로 편집하기 (⌘4)")
            Button { store.showShortcuts = true } label: { Label("단축키", systemImage: "keyboard") }
                .help("단축키 보기 (⌘/)")
            Button { store.showExport = true } label: { Label("내보내기", systemImage: "square.and.arrow.up") }
                .help("영상 내보내기 (⌘E)")
                .buttonStyle(.borderedProminent)
        }
    }
}

struct TimelineToolbar: View {
    @ObservedObject var store: EditorStore

    var body: some View {
        HStack(spacing: 10) {
            Button { store.splitAtPlayhead() } label: { Image(systemName: "scissors") }.help("분할 (S)")
            Button { store.setMarkIn() } label: { Text("I").bold() }.help("구간 시작 (I)")
            Button { store.setMarkOut() } label: { Text("O").bold() }.help("구간 끝 (O)")
            if let r = store.markRange {
                Text("\(TimeFormat.clock(r.lowerBound)) – \(TimeFormat.clock(r.upperBound))")
                    .font(.caption.monospacedDigit())
                Button("구간 잘라내기") { store.deleteSelection(ripple: true) }.help("In~Out 구간 삭제 (⌫)")
                Button { store.clearMarks() } label: { Image(systemName: "xmark") }.help("구간 해제 (X)")
            }
            Divider().frame(height: 16)
            Toggle(isOn: $store.snapping) { Image(systemName: "magnet") }.toggleStyle(.button).help("스냅 (N)")
            Toggle(isOn: $store.followPlayhead) { Image(systemName: "arrow.right.to.line") }.toggleStyle(.button).help("재생 시 타임라인 따라가기")
            Button { store.addTrack() } label: { Image(systemName: "plus.rectangle.on.rectangle") }.help("트랙 추가")
            Spacer()
            Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
            Slider(value: Binding(get: { log(store.zoom) }, set: { store.zoom = exp($0) }), in: log(0.5)...log(800))
                .frame(width: 140)
            Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            Button("전체") { store.zoomToFit() }.help("전체 보기 (⇧Z)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color(nsColor: Theme.header))
    }
}
