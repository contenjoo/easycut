import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

enum LeftTab: String, CaseIterable, Identifiable {
    case media = "미디어"
    case transcript = "대본"
    case captions = "자막"
    case ai = "AI"
    var id: String { rawValue }
}

struct JobProgress: Equatable {
    var value: Double
    var message: String
}

/// 앱 전체 편집 상태
@MainActor
final class EditorStore: ObservableObject {
    @Published private(set) var project = Project()
    @Published var selection: Set<UUID> = []
    @Published var selectedCaption: UUID?
    @Published var markIn: Double?
    @Published var markOut: Double?
    @Published var projectURL: URL?
    @Published var dirty = false
    @Published var toast: String?
    @Published var alert: String?
    @Published var transcribing: [UUID: JobProgress] = [:]
    /// MKV 등 변환 중인 파일 (파일 이름 → 진행률)
    @Published var converting: [String: JobProgress] = [:]
    @Published var leftTab: LeftTab = .media
    @Published var zoom: Double = 40 // px / 초
    @Published var showExport = false
    @Published var showShortcuts = false
    @Published var showSTTSettings = false
    @Published var showSilenceSheet = false
    @Published var showLinkSheet = false
    @Published var snapping = true
    @Published var followPlayhead = true
    @Published var timelineVersion = 0
    /// 무음 컷 미리보기 (타임라인에 빨간색으로 표시)
    @Published var silencePreview: [ClosedRange<Double>] = []
    @Published var showAIPanel = false
    private(set) var loudness: [UUID: [Float]] = [:]

    @AppStorage("sttEngine") var sttEngineRaw: String = STTEngine.apple.rawValue
    @AppStorage("sttLanguage") var sttLanguageID: String = "ko-KR"
    @AppStorage("whisperModel") var whisperModelID: String = WhisperModel.all[0].id

    let player = PlayerController()
    let media = MediaCache()
    let downloader = ModelDownloader()
    lazy var ai = AIAssistant(store: self)
    lazy var control = ControlServer(store: self)

    private var undoStack: [Project] = []
    private var redoStack: [Project] = []
    private var lastCoalesceKey: String?
    private var lastCoalesceTime = Date.distantPast
    private var rebuildTask: Task<Void, Never>?
    private var transcribeTasks: [UUID: Task<Void, Never>] = [:]
    private var clipboard: [(track: Int, clip: Clip)] = []
    private var toastTask: Task<Void, Never>?

    var sttEngine: STTEngine {
        get { STTEngine(rawValue: sttEngineRaw) ?? .apple }
        set { sttEngineRaw = newValue.rawValue; objectWillChange.send() }
    }

    var sttLanguage: STTLanguage {
        STTLanguage.all.first { $0.id == sttLanguageID } ?? STTLanguage.all[0]
    }

    var whisperModel: WhisperModel {
        WhisperModel.all.first { $0.id == whisperModelID } ?? WhisperModel.all[0]
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var time: Double { player.time }

    init() {
        Task { _ = try? await BlankVideo.url() }
        // Whisper가 준비돼 있고 사용자가 엔진을 고른 적 없으면 더 빠르고 정확한 Whisper를 기본으로
        if UserDefaults.standard.object(forKey: "sttEngine") == nil && Transcriber.whisperReady {
            sttEngineRaw = STTEngine.whisper.rawValue
        }
    }

    /// 인식 중간 결과를 실행 취소 기록 없이 바로 반영
    private func setWordsLive(_ id: UUID, _ words: [Word]) {
        guard let i = project.assets.firstIndex(where: { $0.id == id }) else { return }
        project.assets[i].words = words
        timelineVersion += 1
    }

    /// 실행 취소로 되돌릴 때 그 뒤에 생긴 대본은 지우지 않는다
    private func keepTranscripts(_ p: Project) -> Project {
        var p = p
        for i in p.assets.indices where p.assets[i].words == nil {
            if let cur = project.asset(p.assets[i].id)?.words { p.assets[i].words = cur }
        }
        return p
    }

    // MARK: 변경 적용

    /// 프로젝트를 바꾸고 실행 취소 기록을 남긴다. coalesce 키가 같으면 연속 조작을 하나로 묶는다.
    func apply(_ coalesce: String? = nil, _ change: (inout Project) -> Void) {
        var p = project
        change(&p)
        p.normalize()
        guard p != project else { return }
        let now = Date()
        let merge = coalesce != nil && coalesce == lastCoalesceKey && now.timeIntervalSince(lastCoalesceTime) < 1.5
        if !merge {
            undoStack.append(project)
            if undoStack.count > 300 { undoStack.removeFirst() }
        }
        lastCoalesceKey = coalesce
        lastCoalesceTime = now
        redoStack.removeAll()
        setProject(p)
    }

    private func setProject(_ p: Project) {
        project = p
        dirty = true
        let ids = Set(p.tracks.flatMap(\.clips).map(\.id))
        selection = selection.intersection(ids)
        if let c = selectedCaption, !p.captions.contains(where: { $0.id == c }) { selectedCaption = nil }
        timelineVersion += 1
        scheduleRebuild()
    }

    func undo() {
        guard let prev = undoStack.popLast() else { return }
        redoStack.append(project)
        lastCoalesceKey = nil
        setProject(keepTranscripts(prev))
        showToast("실행 취소")
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        lastCoalesceKey = nil
        setProject(keepTranscripts(next))
        showToast("다시 실행")
    }

    func scheduleRebuild(immediate: Bool = false) {
        rebuildTask?.cancel()
        let p = project
        rebuildTask = Task { [weak self] in
            if !immediate { try? await Task.sleep(nanoseconds: 120_000_000) }
            guard !Task.isCancelled, let self else { return }
            do {
                let built = try await CompositionBuilder.build(project: p, renderSize: CompositionBuilder.previewSize(for: p))
                guard !Task.isCancelled else { return }
                if built.duration <= 0 { self.player.clear() } else { self.player.load(built) }
                if !built.missing.isEmpty {
                    self.showToast("찾을 수 없는 파일: \(Set(built.missing).joined(separator: ", "))")
                }
            } catch {
                self.alert = "미리보기 생성 실패: \(error.localizedDescription)"
            }
        }
    }

    func showToast(_ s: String) {
        toast = s
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: 가져오기

    func importPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = MediaProbe.importTypes
        panel.message = "영상, 오디오, 사진 파일을 선택하세요"
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// 파일을 미디어 목록에 추가. place가 있으면 타임라인에도 놓는다.
    func importFiles(_ urls: [URL], place: (track: Int, time: Double)? = nil, subtitles: [Caption] = []) {
        Task { await importFilesNow(urls, place: place, subtitles: subtitles) }
    }

    /// 영상 링크(유튜브 등)에서 받아 가져오기. 성공하면 받은 파일 경로
    @discardableResult
    func importLink(_ link: String, options: LinkImporter.Options) async -> URL? {
        let key = "링크 영상"
        converting[key] = JobProgress(value: 0, message: "준비 중…")
        leftTab = .media
        defer { converting[key] = nil }
        do {
            let r = try await LinkImporter.download(link, options: options) { v, m in
                Task { @MainActor [weak self] in if self?.converting[key] != nil { self?.converting[key] = JobProgress(value: v, message: m) } }
            }
            var file = r.file
            if MediaConverter.needsTranscode(file) {
                converting[key] = JobProgress(value: 0, message: "편집용으로 변환 중…")
                let c = try await MediaConverter.convert(file) { v, m in
                    Task { @MainActor [weak self] in if self?.converting[key] != nil { self?.converting[key] = JobProgress(value: v, message: m) } }
                }
                file = c.video
            }
            await importFilesNow([file], place: nil, subtitles: r.subtitles)
            return r.file
        } catch {
            if !(error is CancellationError) { alert = error.localizedDescription }
            return nil
        }
    }

    private func importFilesNow(_ urls: [URL], place: (track: Int, time: Double)?, subtitles: [Caption]) async {
        do {
            var added: [MediaAsset] = []
            var failed: [String] = []
            var embeddedSubs: [Caption] = subtitles
            for url in urls {
                if let existing = project.assets.first(where: { $0.path == url.path || $0.originalPath == url.path }) { added.append(existing); continue }
                do {
                    if MediaConverter.needsConversion(url) {
                        let name = url.lastPathComponent
                        converting[name] = JobProgress(value: 0, message: "준비 중…")
                        defer { converting[name] = nil }
                        let r = try await MediaConverter.convert(url) { v, m in
                            Task { @MainActor [weak self] in if self?.converting[name] != nil { self?.converting[name] = JobProgress(value: v, message: m) } }
                        }
                        var a = try await MediaProbe.probe(r.video)
                        a.name = name
                        a.originalPath = url.path
                        added.append(a)
                        if embeddedSubs.isEmpty { embeddedSubs = r.subtitles }
                    } else {
                        added.append(try await MediaProbe.probe(url))
                    }
                } catch { failed.append(error.localizedDescription) }
            }
            if !failed.isEmpty { alert = failed.joined(separator: "\n") }
            guard !added.isEmpty else { return }
            let wasEmpty = project.duration == 0
            apply { p in
                for a in added where !p.assets.contains(where: { $0.id == a.id }) { p.assets.append(a) }
                // 첫 영상이면 캔버스를 영상 크기에 맞춘다
                if wasEmpty, p.assets.filter({ $0.kind == .video }).count == added.filter({ $0.kind == .video }).count,
                   let v = added.first(where: { $0.kind == .video }), v.width > 0 {
                    p.canvasWidth = v.width
                    p.canvasHeight = v.height
                }
                if let place {
                    var t = place.time
                    for a in added {
                        let id = p.insert(asset: a, track: place.track, at: t)
                        t = p.clip(id)?.end ?? t
                    }
                } else if wasEmpty {
                    // 빈 프로젝트면 바로 타임라인에 순서대로 놓는다
                    for a in added { Self.autoPlace(a, in: &p, at: nil) }
                }
            }
            // 빈 프로젝트에 자막 트랙이 든 MKV를 가져오면 자막도 함께
            if wasEmpty && place == nil && project.captions.isEmpty && !embeddedSubs.isEmpty {
                apply { $0.captions = embeddedSubs; $0.showCaptions = true }
            }
            for a in added { media.prepare(a) }
            showToast("\(added.count)개 파일을 가져왔습니다" + (embeddedSubs.isEmpty ? "" : " (자막 \(embeddedSubs.count)개)"))
        }
    }

    /// 종류에 맞는 트랙에 자동 배치 (영상→트랙1 끝, 오디오→트랙3, 사진→트랙2 재생헤드)
    static func autoPlace(_ a: MediaAsset, in p: inout Project, at time: Double?) {
        switch a.kind {
        case .video: p.insert(asset: a, track: 0, at: time ?? p.trackEnd(0))
        case .image: p.insert(asset: a, track: min(1, p.tracks.count), at: time ?? p.trackEnd(1))
        case .audio:
            let ti = max(2, p.tracks.count - 1)
            p.insert(asset: a, track: ti, at: time ?? p.trackEnd(ti))
        }
    }

    func addToTimeline(_ assetID: UUID, track: Int? = nil, at time: Double? = nil) {
        guard let a = project.asset(assetID) else { return }
        apply { p in
            if let track { p.insert(asset: a, track: track, at: time ?? p.trackEnd(track)) } else { Self.autoPlace(a, in: &p, at: time) }
        }
    }

    func removeAsset(_ id: UUID) {
        apply { p in
            p.assets.removeAll { $0.id == id }
            for ti in p.tracks.indices { p.tracks[ti].clips.removeAll { $0.assetID == id } }
        }
    }

    // MARK: 프로젝트 파일

    func newProject() {
        guard confirmDiscard() else { return }
        undoStack.removeAll(); redoStack.removeAll()
        player.clear()
        project = Project()
        projectURL = nil
        dirty = false
        selection = []
        timelineVersion += 1
    }

    func confirmDiscard() -> Bool {
        guard dirty, project.duration > 0 || !project.assets.isEmpty else { return true }
        let a = NSAlert()
        a.messageText = "저장하지 않은 변경 사항이 있습니다."
        a.informativeText = "저장하지 않고 계속할까요?"
        a.addButton(withTitle: "저장")
        a.addButton(withTitle: "저장 안 함")
        a.addButton(withTitle: "취소")
        switch a.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func openPanel() {
        guard confirmDiscard() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "easycut") ?? .json, .json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(url)
    }

    func open(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let p = try JSONDecoder().decode(Project.self, from: data)
            undoStack.removeAll(); redoStack.removeAll()
            project = p
            projectURL = url
            dirty = false
            selection = []
            timelineVersion += 1
            for a in p.assets { media.prepare(a) }
            scheduleRebuild(immediate: true)
            restoreConvertedAssets()
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            alert = "프로젝트를 열 수 없습니다: \(error.localizedDescription)"
        }
    }

    /// 변환 캐시가 지워졌으면 원본(MKV 등)에서 다시 변환
    func restoreConvertedAssets() {
        let targets = project.assets.filter { $0.isMissing && $0.originalPath.map { FileManager.default.fileExists(atPath: $0) } == true }
        guard !targets.isEmpty else { return }
        Task {
            for a in targets {
                guard let orig = a.originalPath else { continue }
                converting[a.name] = JobProgress(value: 0, message: "다시 변환 중…")
                if let r = try? await MediaConverter.convert(URL(fileURLWithPath: orig), progress: { _, _ in }) {
                    apply { p in if let i = p.assets.firstIndex(where: { $0.id == a.id }) { p.assets[i].path = r.video.path } }
                    if let fixed = project.asset(a.id) { media.prepare(fixed) }
                }
                converting[a.name] = nil
            }
        }
    }

    @discardableResult
    func save(as: Bool = false) -> Bool {
        var url = projectURL
        if url == nil || `as` {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "easycut") ?? .json]
            panel.nameFieldStringValue = "새 프로젝트.easycut"
            guard panel.runModal() == .OK, let u = panel.url else { return false }
            url = u
        }
        guard let url else { return false }
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            try enc.encode(project).write(to: url, options: .atomic)
            projectURL = url
            dirty = false
            showToast("저장했습니다")
            return true
        } catch {
            alert = "저장 실패: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: 타임라인 편집

    var selectedClips: [Clip] { selection.compactMap { project.clip($0) } }

    func splitAtPlayhead(all: Bool = false) {
        let t = time
        if all || selection.isEmpty {
            apply { $0.splitAll(at: t) }
        } else {
            let ids = selection
            var newIDs: [UUID] = []
            apply { p in
                for id in ids { if let n = p.split(clip: id, at: t) { newIDs.append(n) } }
            }
            if !newIDs.isEmpty { selection = Set(newIDs) }
        }
        showToast("분할")
    }

    func deleteSelection(ripple: Bool) {
        if let r = markRange {
            apply { $0.rippleDelete(from: r.lowerBound, to: r.upperBound) }
            clearMarks()
            showToast("구간 삭제")
            return
        }
        if selection.isEmpty, let cid = selectedCaption {
            apply { $0.captions.removeAll { $0.id == cid } }
            return
        }
        guard !selection.isEmpty else { return }
        let ids = selection
        apply { $0.delete(clips: ids, ripple: ripple) }
        selection = []
        showToast(ripple ? "리플 삭제" : "삭제")
    }

    func duplicateSelection() {
        let clips = selection.compactMap { id -> (Int, Clip)? in
            guard let loc = project.locate(clip: id) else { return nil }
            return (loc.track, project.tracks[loc.track].clips[loc.index])
        }
        guard !clips.isEmpty else { return }
        var newIDs: Set<UUID> = []
        apply { p in
            for (ti, c) in clips {
                var n = c
                n.id = UUID()
                n.start = c.end
                p.tracks[ti].clips.append(n)
                p.resolveOverlaps(track: ti, pinned: n.id)
                newIDs.insert(n.id)
            }
        }
        selection = newIDs
    }

    func copySelection() {
        clipboard = selection.compactMap { id in
            guard let loc = project.locate(clip: id) else { return nil }
            return (loc.track, project.tracks[loc.track].clips[loc.index])
        }
        if !clipboard.isEmpty { showToast("\(clipboard.count)개 클립 복사") }
    }

    func cutSelection() {
        copySelection()
        deleteSelection(ripple: false)
    }

    func paste() {
        guard let base = clipboard.map(\.clip.start).min() else { return }
        let t = time
        var newIDs: Set<UUID> = []
        let items = clipboard
        apply { p in
            for (ti, c) in items {
                var n = c
                n.id = UUID()
                n.start = t + (c.start - base)
                while p.tracks.count <= ti { p.tracks.append(Track(name: "트랙 \(p.tracks.count + 1)")) }
                p.tracks[ti].clips.append(n)
                p.resolveOverlaps(track: ti, pinned: n.id)
                newIDs.insert(n.id)
            }
        }
        selection = newIDs
    }

    func selectAll() {
        selection = Set(project.tracks.flatMap(\.clips).map(\.id))
    }

    func setSpeed(_ s: Double, for ids: Set<UUID>? = nil) {
        let targets = ids ?? selection
        guard !targets.isEmpty else {
            showToast("속도를 바꿀 클립을 선택하세요")
            return
        }
        apply("speed-\(targets.hashValue)") { p in
            for id in targets {
                if let c = p.clip(id), c.kind == .media, p.asset(c.assetID)?.kind != .image { p.setSpeed(clip: id, s) }
            }
        }
    }

    func updateClip(_ id: UUID, key: String, _ f: (inout Clip) -> Void) {
        apply("\(key)-\(id)") { p in
            guard let loc = p.locate(clip: id) else { return }
            f(&p.tracks[loc.track].clips[loc.index])
        }
    }

    func addTextClip() {
        let t = time
        var id: UUID?
        apply { p in
            let ti = max(1, p.tracks.count - 1)
            id = p.insertText("텍스트를 입력하세요", track: ti, at: t)
        }
        if let id { selection = [id] }
    }

    func addTrack() {
        apply { p in p.tracks.append(Track(name: "트랙 \(p.tracks.count + 1)")) }
    }

    func removeEmptyTracks() {
        apply { p in
            p.tracks.removeAll { $0.clips.isEmpty }
            if p.tracks.isEmpty { p.tracks = [Track(name: "트랙 1")] }
            for i in p.tracks.indices { p.tracks[i].name = "트랙 \(i + 1)" }
        }
    }

    func toggleTrack(_ ti: Int, mute: Bool) {
        apply { p in
            guard p.tracks.indices.contains(ti) else { return }
            if mute { p.tracks[ti].muted.toggle() } else { p.tracks[ti].hidden.toggle() }
        }
    }

    // MARK: 구간 (In/Out)

    var markRange: ClosedRange<Double>? {
        guard let a = markIn, let b = markOut, abs(b - a) > 0.02 else { return nil }
        return min(a, b)...max(a, b)
    }

    func setMarkIn() { markIn = time; if let o = markOut, o < time { markOut = nil }; showToast("시작 지점 (I) \(TimeFormat.clock(time))") }
    func setMarkOut() { markOut = time; if let i = markIn, i > time { markIn = nil }; showToast("끝 지점 (O) \(TimeFormat.clock(time))") }
    func clearMarks() { markIn = nil; markOut = nil }

    // MARK: 재생 이동

    func seek(_ t: Double) { player.seek(t) }

    func jumpEditPoint(forward: Bool) {
        let pts = project.editPoints + project.captions.flatMap { [$0.start] }
        let t = time
        if forward {
            if let n = pts.filter({ $0 > t + 0.01 }).min() { seek(n) }
        } else {
            if let n = pts.filter({ $0 < t - 0.01 }).max() { seek(n) } else { seek(0) }
        }
    }

    // MARK: 음성 인식 / 대본

    /// 타임라인에 쓰인 미디어 중 아직 인식하지 않은 것 전부 인식
    func transcribeTimeline() {
        let used = Set(project.tracks.flatMap(\.clips).compactMap(\.assetID))
        let targets = project.assets.filter { used.contains($0.id) && $0.hasAudio && $0.words == nil }
        if targets.isEmpty {
            let any = project.assets.filter { used.contains($0.id) && $0.hasAudio }
            if any.isEmpty { alert = "음성이 있는 영상/오디오를 먼저 타임라인에 올려 주세요." } else {
                let a = NSAlert()
                a.messageText = "이미 인식이 끝났습니다. 다시 인식할까요?"
                a.informativeText = "기존 대본 수정 내용은 사라집니다."
                a.addButton(withTitle: "다시 인식"); a.addButton(withTitle: "취소")
                if a.runModal() == .alertFirstButtonReturn { any.forEach { transcribe($0.id) } }
            }
            return
        }
        targets.forEach { transcribe($0.id) }
    }

    func transcribe(_ assetID: UUID) {
        guard let asset = project.asset(assetID), transcribeTasks[assetID] == nil else { return }
        guard asset.hasAudio else { alert = "\(asset.name)에는 오디오가 없습니다."; return }
        let engine = sttEngine, lang = sttLanguage, model = whisperModel
        transcribing[assetID] = JobProgress(value: 0, message: "준비 중…")
        leftTab = .transcript
        transcribeTasks[assetID] = Task { [weak self] in
            do {
                let words = try await Transcriber.transcribe(url: asset.url, engine: engine, language: lang, whisperModel: model, partial: { ws in
                    Task { @MainActor in
                        guard let self, self.transcribing[assetID] != nil else { return }
                        self.setWordsLive(assetID, ws)
                    }
                }) { v, m in
                    Task { @MainActor in self?.transcribing[assetID] = JobProgress(value: v, message: m) }
                }
                guard let self else { return }
                self.transcribing[assetID] = nil
                self.transcribeTasks[assetID] = nil
                self.apply { p in
                    if let i = p.assets.firstIndex(where: { $0.id == assetID }) { p.assets[i].words = words }
                }
                self.showToast("\(asset.name): \(words.count)개 단어 인식 완료")
                // 자막이 비어 있으면 자동 생성
                if self.project.captions.isEmpty && !words.isEmpty { self.generateCaptions(confirm: false) }
            } catch {
                guard let self else { return }
                self.transcribing[assetID] = nil
                self.transcribeTasks[assetID] = nil
                if !(error is CancellationError) { self.alert = error.localizedDescription }
                else if self.project.asset(assetID)?.words?.isEmpty == false { self.showToast("음성 인식을 중지했습니다 (인식된 부분까지 남김)") }
            }
        }
    }

    func cancelTranscription(_ id: UUID) {
        transcribeTasks[id]?.cancel()
        transcribeTasks[id] = nil
        transcribing[id] = nil
    }

    /// 대본에서 선택한 단어 삭제 → 영상도 잘림
    func deleteWords(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let ranges = Project.deletionRanges(selected: ids, in: project.timelineWords())
        guard !ranges.isEmpty else { return }
        let removed = ranges.map { $0.upperBound - $0.lowerBound }.reduce(0, +)
        apply { $0.rippleDelete(ranges: ranges) }
        showToast(String(format: "%d개 단어 삭제 (%.1f초 잘림)", ids.count, removed))
    }

    func removeSilences(minGap: Double, keep: Double) {
        let ranges = project.silenceRanges(minGap: minGap, keep: keep)
        guard !ranges.isEmpty else { showToast("삭제할 무음 구간이 없습니다"); return }
        let total = ranges.map { $0.upperBound - $0.lowerBound }.reduce(0, +)
        apply { $0.rippleDelete(ranges: ranges) }
        showToast(String(format: "무음 %d곳 삭제 (%.1f초 단축)", ranges.count, total))
    }

    /// 기본 트랙에 쓰인 소리 있는 미디어의 음량 분석 (Recut 방식 무음 컷용)
    func ensureLoudness() async -> Bool {
        let used = Set(project.tracks.first?.clips.compactMap(\.assetID) ?? [])
        let targets = project.assets.filter { used.contains($0.id) && $0.hasAudio && loudness[$0.id] == nil && !$0.isMissing }
        for a in targets {
            do { loudness[a.id] = try await SilenceDetector.loudness(url: a.url) } catch {
                alert = "오디오 분석 실패: \(a.name) — \(error.localizedDescription)"
                return false
            }
        }
        return true
    }

    func audioSilenceRanges(_ settings: SilenceSettings) -> [ClosedRange<Double>] {
        project.audioSilenceRanges(loudness: loudness, settings: settings)
    }

    /// 기본 트랙 소리의 자동 기준 음량
    func autoSilenceThreshold() -> Double {
        let used = project.tracks.first?.clips.compactMap(\.assetID) ?? []
        let all = used.compactMap { loudness[$0] }.flatMap { $0 }
        return SilenceDetector.autoThreshold(all)
    }

    func applyCut(_ ranges: [ClosedRange<Double>], label: String) {
        silencePreview = []
        guard !ranges.isEmpty else { showToast("잘라낼 구간이 없습니다"); return }
        let total = ranges.map { $0.upperBound - $0.lowerBound }.reduce(0, +)
        apply { $0.rippleDelete(ranges: ranges) }
        showToast(String(format: "%@ %d곳 삭제 (%.1f초 단축)", label, ranges.count, total))
    }

    func removeFillers() {
        let ids = project.fillerWordIDs()
        guard !ids.isEmpty else { showToast("군더더기 말(음, 어…)을 찾지 못했습니다"); return }
        deleteWords(ids)
    }

    func updateWord(asset: UUID, word: UUID, text: String) {
        apply { $0.updateWord(asset: asset, word: word, text: text) }
    }

    func generateCaptions(confirm: Bool = true) {
        let caps = project.generatedCaptions()
        guard !caps.isEmpty else { alert = "대본이 없습니다. 먼저 음성 인식을 실행하세요."; return }
        if confirm && !project.captions.isEmpty {
            let a = NSAlert()
            a.messageText = "기존 자막을 대본으로 다시 만들까요?"
            a.informativeText = "직접 수정한 자막 내용은 사라집니다."
            a.addButton(withTitle: "다시 만들기"); a.addButton(withTitle: "취소")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        apply { $0.captions = caps; $0.showCaptions = true }
        showToast("자막 \(caps.count)개 생성")
    }

    // MARK: 자막

    func addCaption() {
        let t = time
        let c = Caption(start: t, end: t + 3, text: "새 자막")
        apply { $0.captions.append(c) }
        selectedCaption = c.id
        leftTab = .captions
    }

    func updateCaption(_ id: UUID, key: String = "caption", _ f: (inout Caption) -> Void) {
        apply("\(key)-\(id)") { p in
            guard let i = p.captions.firstIndex(where: { $0.id == id }) else { return }
            f(&p.captions[i])
            if p.captions[i].end < p.captions[i].start + 0.1 { p.captions[i].end = p.captions[i].start + 0.1 }
        }
    }

    func updateProject(key: String, _ f: (inout Project) -> Void) {
        apply(key, f)
    }

    func importSRT() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url,
              let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .utf16)) else { return }
        let caps = SRT.parse(text)
        guard !caps.isEmpty else { alert = "SRT 자막을 읽지 못했습니다."; return }
        apply { $0.captions = caps; $0.showCaptions = true }
        showToast("자막 \(caps.count)개 가져옴")
    }

    func exportSRT() {
        guard !project.captions.isEmpty else { alert = "자막이 없습니다."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = baseName + ".srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try Exporter.exportSRT(project.captions, to: url); showToast("SRT 저장 완료") } catch { alert = error.localizedDescription }
    }

    func exportTranscript() {
        let text = project.transcriptText()
        guard !text.isEmpty else { alert = "대본이 없습니다."; return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = baseName + " 대본.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8); showToast("대본 저장 완료") } catch { alert = error.localizedDescription }
    }

    func snapshot() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = baseName + " \(TimeFormat.short(time).replacingOccurrences(of: ":", with: "-")).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let p = project, t = time
        Task {
            do { try await Exporter.snapshot(project: p, time: t, to: url); showToast("장면을 PNG로 저장했습니다") } catch { alert = error.localizedDescription }
        }
    }

    var baseName: String {
        if let u = projectURL { return u.deletingPathExtension().lastPathComponent }
        if let first = project.tracks.first?.clips.first, let a = project.asset(first.assetID) {
            return (a.name as NSString).deletingPathExtension
        }
        return "EasyCut"
    }

    var windowTitle: String {
        "\(projectURL?.deletingPathExtension().lastPathComponent ?? "새 프로젝트")\(dirty ? " — 편집됨" : "")"
    }
}
