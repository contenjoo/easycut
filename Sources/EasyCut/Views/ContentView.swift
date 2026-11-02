import SwiftUI

struct ContentView: View {
    @ObservedObject var store: EditorStore
    @State private var keyMonitor: KeyMonitor?

    var body: some View {
        VSplitView {
            HSplitView {
                LeftPanel(store: store)
                    .frame(minWidth: 240, idealWidth: 260, maxWidth: 320)
                PreviewPane(store: store, player: store.player)
                    .frame(minWidth: 420, idealWidth: 760, maxWidth: .infinity)
                InspectorPanel(store: store)
                    .frame(minWidth: 320, idealWidth: 350, maxWidth: 400)
            }
            .frame(minHeight: 340, idealHeight: 570)
            VStack(spacing: 0) {
                TimelineToolbar(store: store)
                TimelineContainer(store: store)
            }
            .frame(minHeight: 170, idealHeight: 240)
        }
        .frame(minWidth: 1100, minHeight: 680)
        .toolbar { MainToolbar(store: store) }
        .navigationTitle(store.windowTitle)
        .overlay(alignment: .top) {
            if let t = store.toast {
                Text(L(t))
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
        .sheet(isPresented: $store.showLinkSheet) { LinkSheet(store: store) }
        .sheet(isPresented: $store.showClaudeSheet) { ConnectSheet(ai: store.ai) }
        .sheet(isPresented: $store.showNaturalEdit) { NaturalEditSheet(store: store, ai: store.ai) }
        .sheet(isPresented: $store.showVideoGeneration) { VideoGenerationSheet(store: store, generator: store.videoGenerator) }
        .sheet(isPresented: $store.showRecordSheet) { RecordSheet(rec: store.recording) }
        .alert("알림", isPresented: Binding(get: { store.alert != nil }, set: { if !$0 { store.alert = nil } })) {
            Button("확인") { store.alert = nil }
        } message: {
            Text(L(store.alert ?? ""))
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
            HStack(spacing: 4) {
                ForEach(LeftTab.allCases) { tab in
                    Button { store.leftTab = tab } label: {
                        VStack(spacing: 5) {
                            Image(systemName: tab.symbol).font(.system(size: 15, weight: .medium))
                            Text(L(tab.rawValue)).font(.system(size: 11, weight: .medium))
                        }
                        .frame(maxWidth: .infinity).frame(height: 48)
                        .foregroundStyle(store.leftTab == tab ? Theme.accentColor : .secondary)
                        .background(store.leftTab == tab ? Theme.accentColor.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("workspace-\(tab.id)")
                    .accessibilityAddTraits(store.leftTab == tab ? .isSelected : [])
                }
            }
            .padding(10)
            Divider()
            switch store.leftTab {
            case .media: MediaBinPanel(store: store, media: store.media)
            case .transcript: TranscriptPanel(store: store)
            case .captions: CaptionsPanel(store: store)
            case .ai: AIPanel(store: store, ai: store.ai)
            }
        }
        .background(Theme.panelBG)
    }
}

struct MainToolbar: ToolbarContent {
    @ObservedObject var store: EditorStore

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            EditorToolbarButton(title: "가져오기", symbol: "plus") { store.importPanel() }
                .help("미디어 가져오기 (⌘I)")
            EditorToolbarButton(title: "텍스트", symbol: "textformat") { store.addTextClip() }
                .help("텍스트(제목) 추가 (T)")
            EditorToolbarButton(title: "자막", symbol: "captions.bubble") { store.leftTab = .captions }
            EditorToolbarButton(title: "영상 만들기", symbol: "film.badge.plus") { store.showVideoGeneration = true }
            EditorToolbarButton(title: "녹화", symbol: "record.circle") { store.recording.open() }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { store.undo() } label: { Label("실행 취소", systemImage: "arrow.uturn.backward") }
                .help("실행 취소 (⌘Z)").disabled(!store.canUndo)
            Button { store.redo() } label: { Label("다시 실행", systemImage: "arrow.uturn.forward") }
                .help("다시 실행 (⇧⌘Z)").disabled(!store.canRedo)
            EditorToolbarButton(title: "AI 편집", symbol: "sparkles") { store.leftTab = .ai }
            Menu {
                Button { store.showLinkSheet = true } label: { Label("링크로 가져오기…", systemImage: "link") }
                Button { store.showNaturalEdit = true } label: { Label("말·파일명 편집", systemImage: "waveform.and.sparkles") }
                Divider()
                Button { store.showSilenceSheet = true } label: { Label("무음 컷", systemImage: "scissors.badge.ellipsis") }
                Button { store.transcribeTimeline() } label: { Label("음성 인식", systemImage: "waveform.badge.mic") }
                Button { store.generateCaptions() } label: { Label("자막 생성", systemImage: "captions.bubble") }
                Divider()
                Button { store.showShortcuts = true } label: { Label("단축키", systemImage: "keyboard") }
            } label: { Label("더 보기", systemImage: "ellipsis") }
            .help("더 보기")
            .accessibilityIdentifier("editor-more-actions")
            Button { store.showExport = true } label: {
                HStack(spacing: 6) { Image(systemName: "square.and.arrow.up"); Text("내보내기") }
                    .fixedSize()
            }
                .help("영상 내보내기 (⌘E)")
                .buttonStyle(.borderedProminent)
        }
    }
}

/// 도구 이름을 아이콘과 함께 표시해 익숙하지 않은 기호도 바로 알아볼 수 있게 한다.
struct EditorToolbarButton: View {
    let title: String
    let symbol: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                Text(L(title)).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 5).frame(height: 28).fixedSize()
        }
        .accessibilityLabel(L(title))
    }
}

struct TimelineToolbar: View {
    @ObservedObject var store: EditorStore

    var body: some View {
        HStack(spacing: 12) {
            Text("타임라인").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Button { store.splitAtPlayhead() } label: { Label("분할", systemImage: "scissors") }.help("분할 (S)")
            Button { store.deleteSelection(ripple: true) } label: { Label("삭제", systemImage: "trash") }.help("선택 삭제 후 빈틈 메우기 (⌘⌫)")
            Menu {
                Button("구간 시작 (I)") { store.setMarkIn() }
                Button("구간 끝 (O)") { store.setMarkOut() }
                if store.markIn != nil || store.markOut != nil { Button("구간 해제 (X)") { store.clearMarks() } }
            } label: { Label("구간", systemImage: "selection.pin.in.out") }
                .menuStyle(.borderlessButton).fixedSize()
            if let r = store.markRange {
                Text("\(TimeFormat.clock(r.lowerBound)) – \(TimeFormat.clock(r.upperBound))")
                    .font(.caption.monospacedDigit())
                Button("구간 잘라내기") { store.deleteSelection(ripple: true) }.help("In~Out 구간 삭제 (⌫)")
                Button { store.clearMarks() } label: { Image(systemName: "xmark") }.help("구간 해제 (X)")
            }
            Divider().frame(height: 16)
            Toggle(isOn: $store.snapping) { Label("스냅", systemImage: "magnet") }.toggleStyle(.button).help("스냅 (N)")
            Toggle(isOn: $store.followPlayhead) { Label("따라가기", systemImage: "arrow.right.to.line") }.toggleStyle(.button).help("재생 시 타임라인 따라가기")
            Button { store.addTrack() } label: { Label("트랙", systemImage: "plus.rectangle.on.rectangle") }.help("트랙 추가")
            Divider().frame(height: 16)
            Button { store.changeTrackHeight(by: 1 / 1.25) } label: {
                Image(systemName: "rectangle.compress.vertical").frame(width: 22, height: 20).contentShape(Rectangle())
            }
            .help("트랙 낮게")
            .disabled(store.trackHeight <= EditorStore.trackHeightRange.lowerBound)
            Button { store.changeTrackHeight(by: 1.25) } label: {
                Image(systemName: "rectangle.expand.vertical").frame(width: 22, height: 20).contentShape(Rectangle())
            }
            .help("트랙 높게")
            .disabled(store.trackHeight >= EditorStore.trackHeightRange.upperBound)
            Spacer()
            Button { store.zoom = max(0.5, store.zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass").frame(width: 22, height: 20).contentShape(Rectangle()) }.help("축소 (⌘-)")
            EZSlider(value: Binding(get: { log(store.zoom) }, set: { store.zoom = exp($0) }), in: log(0.5)...log(800))
                .frame(width: 90)
            Button { store.zoom = min(800, store.zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass").frame(width: 22, height: 20).contentShape(Rectangle()) }.help("확대 (⌘=)")
            Button("전체") { store.zoomToFit() }.help("전체 보기 (⇧Z)")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color(nsColor: Theme.header))
    }
}
