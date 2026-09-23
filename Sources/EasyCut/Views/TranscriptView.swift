import SwiftUI
import AppKit
import Combine

/// 대본(텍스트) 기반 편집 패널: 단어를 지우면 영상도 잘린다
struct TranscriptPanel: View {
    @ObservedObject var store: EditorStore
    @State private var selectedCount = 0

    var body: some View {
        let words = store.project.timelineWords()
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button {
                    store.transcribeTimeline()
                } label: {
                    Label("음성 인식", systemImage: "waveform.badge.mic")
                }
                .buttonStyle(.borderedProminent)
                .help("타임라인의 영상/오디오 음성을 텍스트로 변환 (⇧⌘R)")
                Button { store.showSTTSettings = true } label: {
                    Text("\(store.sttLanguage.name) · \(store.sttEngine == .apple ? "Apple" : "Whisper")")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("인식 엔진/언어 설정")
                Spacer()
            }
            .padding(10)

            ForEach(Array(store.transcribing.keys), id: \.self) { id in
                if let job = store.transcribing[id] {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(store.project.asset(id)?.name ?? "").font(.caption.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Button("취소") { store.cancelTranscription(id) }.controlSize(.small)
                        }
                        ProgressView(value: job.value)
                        Text(job.message).font(.caption2).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10).padding(.bottom, 8)
                }
            }

            Divider()
            if words.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    Image(systemName: "text.bubble").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("아직 대본이 없습니다").font(.headline)
                    Text("영상을 타임라인에 올리고 [음성 인식]을 누르면\n말한 내용이 텍스트로 나타납니다.\n\n텍스트를 선택해 ⌫ 를 누르면\n그 부분이 영상에서 잘려 나갑니다.")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding()
            } else {
                TranscriptTextView(store: store, selectedCount: $selectedCount)
                Divider()
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Text(selectedCount > 0 ? "\(selectedCount)개 단어 선택됨" : "단어 \(words.count)개 · 클릭=이동, 드래그=선택")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    HStack(spacing: 6) {
                        Button {
                            NotificationCenter.default.post(name: .transcriptDeleteSelection, object: nil)
                        } label: { Label("선택 삭제", systemImage: "scissors") }
                            .disabled(selectedCount == 0)
                            .help("선택한 단어 구간을 영상에서 잘라냄 (⌫)")
                        Button { store.showSilenceSheet = true } label: { Label("무음 제거", systemImage: "waveform.path.badge.minus") }
                            .help("말이 없는 구간을 한 번에 삭제")
                        Button { store.removeFillers() } label: { Label("군더더기", systemImage: "text.badge.minus") }
                            .help("'음', '어' 같은 군더더기 말 삭제")
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        Button { store.generateCaptions() } label: { Label("자막 만들기", systemImage: "captions.bubble") }
                            .help("대본으로 자막 자동 생성 (⇧⌘C)")
                        Button { store.exportTranscript() } label: { Label("TXT", systemImage: "square.and.arrow.up") }
                            .help("대본을 텍스트 파일로 저장")
                        Spacer(minLength: 0)
                    }
                }
                .controlSize(.small)
                .padding(8)
            }
        }
    }
}

extension Notification.Name {
    static let transcriptDeleteSelection = Notification.Name("transcriptDeleteSelection")
}

extension NSAttributedString.Key {
    static let ecWord = NSAttributedString.Key("ecWord")
    static let ecSeek = NSAttributedString.Key("ecSeek")
}

struct TranscriptTextView: NSViewRepresentable {
    @ObservedObject var store: EditorStore
    @Binding var selectedCount: Int

    func makeCoordinator() -> Coordinator { Coordinator(store: store, selectedCount: $selectedCount) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let tv = TranscriptNSTextView(usingTextLayoutManager: false)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = true
        tv.drawsBackground = true
        tv.backgroundColor = NSColor(white: 0.11, alpha: 1)
        tv.textContainerInset = NSSize(width: 12, height: 12)
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.selectedTextAttributes = [.backgroundColor: NSColor.systemBlue.withAlphaComponent(0.45)]
        tv.delegate = context.coordinator
        tv.coordinator = context.coordinator
        scroll.documentView = tv
        context.coordinator.textView = tv
        context.coordinator.rebuild()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.rebuildIfNeeded()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let store: EditorStore
        var selectedCount: Binding<Int>
        weak var textView: TranscriptNSTextView?
        var words: [TimelineWord] = []
        var ranges: [NSRange] = []
        private var builtSignature = -1
        private var current: Int?
        private var bag: Set<AnyCancellable> = []

        init(store: EditorStore, selectedCount: Binding<Int>) {
            self.store = store
            self.selectedCount = selectedCount
            super.init()
            store.player.$time
                .throttle(for: .milliseconds(80), scheduler: RunLoop.main, latest: true)
                .sink { [weak self] t in self?.highlight(time: t) }
                .store(in: &bag)
            NotificationCenter.default.publisher(for: .transcriptDeleteSelection)
                .sink { [weak self] _ in self?.deleteSelection() }
                .store(in: &bag)
        }

        var signature: Int {
            var h = Hasher()
            h.combine(store.timelineVersion)
            return h.finalize()
        }

        func rebuildIfNeeded() {
            if signature != builtSignature { rebuild() }
        }

        func rebuild() {
            guard let tv = textView else { return }
            builtSignature = signature
            words = store.project.timelineWords()
            ranges = []
            let out = NSMutableAttributedString()
            let para = NSMutableParagraphStyle()
            para.lineSpacing = 5
            para.paragraphSpacing = 12
            let font = NSFont.systemFont(ofSize: 15)
            let normal: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.92, alpha: 1), .paragraphStyle: para]
            let filler: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.systemOrange, .paragraphStyle: para]
            let stamp: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                                                        .foregroundColor: NSColor.systemTeal, .paragraphStyle: para]
            var paraChars = 0
            for (i, w) in words.enumerated() {
                var newPara = i == 0
                if i > 0 {
                    let prev = words[i - 1]
                    let gap = w.start - prev.end
                    let sentenceEnd = prev.word.text.last.map { ".?!".contains($0) } ?? false
                    if gap > 1.5 || prev.clipID != w.clipID || (sentenceEnd && paraChars > 160) { newPara = true }
                }
                if newPara {
                    if i > 0 { out.append(NSAttributedString(string: "\n", attributes: normal)) }
                    var s = stamp
                    s[.ecSeek] = w.start
                    out.append(NSAttributedString(string: TimeFormat.short(w.start) + "  ", attributes: s))
                    paraChars = 0
                } else {
                    out.append(NSAttributedString(string: " ", attributes: normal))
                }
                var a = Project.fillerWords.contains(Project.normalized(w.word.text)) ? filler : normal
                a[.ecWord] = i
                let r = NSRange(location: out.length, length: (w.word.text as NSString).length)
                out.append(NSAttributedString(string: w.word.text, attributes: a))
                ranges.append(r)
                paraChars += w.word.text.count + 1
            }
            let visible = tv.enclosingScrollView?.contentView.bounds.origin
            tv.textStorage?.setAttributedString(out)
            current = nil
            if let visible { tv.enclosingScrollView?.contentView.scroll(to: visible) }
            highlight(time: store.player.time)
            DispatchQueue.main.async { [weak self] in self?.selectedCount.wrappedValue = 0 }
        }

        func wordIndex(atChar c: Int) -> Int? {
            var lo = 0, hi = ranges.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                let r = ranges[mid]
                if c < r.location { hi = mid - 1 } else if c >= r.location + r.length { lo = mid + 1 } else { return mid }
            }
            return nil
        }

        func selectedWordIndices() -> [Int] {
            guard let tv = textView else { return [] }
            var out: [Int] = []
            for v in tv.selectedRanges {
                let sel = v.rangeValue
                guard sel.length > 0 else { continue }
                // 첫 단어 찾기 (이진 탐색)
                var lo = 0, hi = ranges.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if ranges[mid].location + ranges[mid].length <= sel.location { lo = mid + 1 } else { hi = mid }
                }
                var i = lo
                while i < ranges.count, ranges[i].location < sel.location + sel.length {
                    out.append(i); i += 1
                }
            }
            return out
        }

        /// 드래그 선택을 단어 단위로 맞춘다
        func textView(_ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange) -> NSRange {
            guard new.length > 0, !ranges.isEmpty else { return new }
            var lo = 0, hi = ranges.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if NSMaxRange(ranges[mid]) <= new.location { lo = mid + 1 } else { hi = mid }
            }
            guard lo < ranges.count, ranges[lo].location < NSMaxRange(new) else { return new }
            var last = lo
            while last + 1 < ranges.count, ranges[last + 1].location < NSMaxRange(new) { last += 1 }
            let start = min(new.location, ranges[lo].location)
            let end = max(NSMaxRange(new), NSMaxRange(ranges[last]))
            return NSRange(location: start, length: end - start)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            selectedCount.wrappedValue = selectedWordIndices().count
        }

        func highlight(time t: Double) {
            guard let tv = textView, let storage = tv.textStorage, !words.isEmpty else { return }
            // 현재 시간의 단어 찾기
            var lo = 0, hi = words.count - 1, found: Int?
            while lo <= hi {
                let mid = (lo + hi) / 2
                if words[mid].start <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            if let f = found, t > words[f].end + 0.6 { found = nil }
            guard found != current else { return }
            storage.beginEditing()
            if let c = current, c < ranges.count, NSMaxRange(ranges[c]) <= storage.length {
                storage.removeAttribute(.backgroundColor, range: ranges[c])
            }
            if let f = found, NSMaxRange(ranges[f]) <= storage.length {
                storage.addAttribute(.backgroundColor, value: NSColor.systemYellow.withAlphaComponent(0.35), range: ranges[f])
                if store.player.isPlaying { tv.scrollRangeToVisible(ranges[f]) }
            }
            storage.endEditing()
            current = found
        }

        func click(at charIndex: Int) {
            guard let storage = textView?.textStorage, charIndex < storage.length else { return }
            if let t = storage.attribute(.ecSeek, at: charIndex, effectiveRange: nil) as? Double {
                store.seek(t)
            } else if let i = wordIndex(atChar: charIndex) {
                store.player.pause()
                store.seek(words[i].start + 0.001)
            }
        }

        func deleteSelection() {
            let idx = selectedWordIndices()
            guard !idx.isEmpty else { return }
            let ids = Set(idx.map { words[$0].id })
            store.deleteWords(ids)
        }

        func editSelectedWord() {
            guard let i = selectedWordIndices().first ?? (current) else { return }
            let w = words[i]
            let a = NSAlert()
            a.messageText = "단어 고치기"
            a.informativeText = "인식이 잘못된 글자를 바로잡습니다. 자막을 다시 만들면 반영됩니다."
            let field = NSTextField(string: w.word.text)
            field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            a.accessoryView = field
            a.addButton(withTitle: "확인")
            a.addButton(withTitle: "취소")
            a.window.initialFirstResponder = field
            if a.runModal() == .alertFirstButtonReturn {
                let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { store.deleteWords([w.id]) } else { store.updateWord(asset: w.assetID, word: w.word.id, text: text) }
            }
        }

        func menu() -> NSMenu {
            let m = NSMenu()
            let n = selectedWordIndices().count
            let del = MenuAction.item(n > 0 ? "선택한 \(n)개 단어를 영상에서 잘라내기  (⌫)" : "단어를 선택하세요") { [weak self] in self?.deleteSelection() }
            del.isEnabled = n > 0
            m.addItem(del)
            m.addItem(MenuAction.item("단어 고치기  (↩)") { [weak self] in self?.editSelectedWord() })
            if let first = selectedWordIndices().first {
                let t = words[first].start
                m.addItem(MenuAction.item("여기서 재생") { [weak self] in self?.store.seek(t); self?.store.player.play() })
                let r0 = words[first].start
                let r1 = words[selectedWordIndices().last ?? first].end
                m.addItem(MenuAction.item("선택 구간을 자막으로 추가") { [weak self] in
                    let text = self?.selectedWordIndices().compactMap { self?.words[$0].word.text }.joined(separator: " ") ?? ""
                    self?.store.apply { $0.captions.append(Caption(start: r0, end: r1 + 0.2, text: text)) }
                })
            }
            m.addItem(.separator())
            m.addItem(MenuAction.item("무음 제거…") { [weak self] in self?.store.showSilenceSheet = true })
            m.addItem(MenuAction.item("군더더기 말 제거") { [weak self] in self?.store.removeFillers() })
            return m
        }
    }
}

final class TranscriptNSTextView: NSTextView {
    weak var coordinator: TranscriptTextView.Coordinator?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 51, 117: // delete, forward delete
            coordinator?.deleteSelection()
        case 36, 76: // return
            coordinator?.editSelectedWord()
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if selectedRange().length == 0 {
            let pt = convert(event.locationInWindow, from: nil)
            let idx = characterIndexForInsertion(at: pt)
            coordinator?.click(at: max(0, min(idx, (textStorage?.length ?? 1) - 1)))
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        coordinator?.menu()
    }
}

enum SilenceMode: String, CaseIterable, Identifiable {
    case audio = "소리 크기로 (음성 인식 불필요)"
    case transcript = "대본 기준 (말 사이 공백)"
    var id: String { rawValue }
}

/// Recut 스타일 원클릭 무음 컷: 잘릴 곳을 타임라인에 미리 보여주고 한 번에 적용
struct SilenceSheet: View {
    @ObservedObject var store: EditorStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("silenceMode") private var modeRaw = SilenceMode.audio.rawValue
    @AppStorage("silenceThreshold") private var threshold = -40.0
    @AppStorage("silenceAuto") private var autoThreshold = true
    @AppStorage("silenceMinGap") private var minGap = 0.6
    @AppStorage("silenceKeep") private var keep = 0.12
    @State private var analyzing = true
    @State private var ranges: [ClosedRange<Double>] = []

    var mode: SilenceMode { SilenceMode(rawValue: modeRaw) ?? .audio }
    var hasTranscript: Bool { !store.project.timelineWords().isEmpty }

    var body: some View {
        let total = ranges.map { $0.upperBound - $0.lowerBound }.reduce(0, +)
        let dur = store.project.duration
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "scissors.badge.ellipsis").font(.title2).foregroundStyle(.red)
                Text("무음 컷").font(.title2.bold())
                Spacer()
                if analyzing { ProgressView().controlSize(.small); Text("소리 분석 중…").font(.caption) }
            }
            Text("말이 없는 부분을 찾아 한 번에 잘라냅니다. 잘릴 곳은 타임라인에 빨간색으로 표시됩니다.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("기준", selection: $modeRaw) {
                ForEach(SilenceMode.allCases) { Text($0.rawValue).tag($0.rawValue).disabled($0 == .transcript && !hasTranscript) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if mode == .audio {
                HStack {
                    Text("기준 음량").frame(width: 100, alignment: .leading)
                    Slider(value: Binding(get: { threshold }, set: { threshold = $0; autoThreshold = false }), in: -65 ... -15, step: 1)
                    Text("\(Int(threshold)) dB").monospacedDigit().frame(width: 56)
                    Toggle("자동", isOn: $autoThreshold).toggleStyle(.checkbox)
                }
                Text("이 음량보다 작은 소리는 무음으로 봅니다. 잡음이 많으면 오른쪽(크게)으로, 작은 말소리까지 잘리면 왼쪽으로.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("최소 무음 길이").frame(width: 100, alignment: .leading)
                Slider(value: $minGap, in: 0.2...3, step: 0.1)
                Text(String(format: "%.1f초", minGap)).monospacedDigit().frame(width: 56)
            }
            HStack {
                Text("앞뒤 여유").frame(width: 100, alignment: .leading)
                Slider(value: $keep, in: 0...0.6, step: 0.02)
                Text(String(format: "%.2f초", keep)).monospacedDigit().frame(width: 56)
            }
            HStack(spacing: 6) {
                Text("빠른 설정").font(.caption).foregroundStyle(.secondary)
                Button("자연스럽게") { minGap = 1.0; keep = 0.2 }
                Button("보통") { minGap = 0.6; keep = 0.12 }
                Button("빠른 템포") { minGap = 0.3; keep = 0.05 }
            }
            .controlSize(.small)

            GroupBox {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ranges.isEmpty ? "잘라낼 무음이 없습니다" : "\(ranges.count)곳 · \(String(format: "%.1f", total))초 삭제")
                            .font(.headline)
                            .foregroundStyle(ranges.isEmpty ? Color.secondary : Color.red)
                        Text("\(TimeFormat.clock(dur)) → \(TimeFormat.clock(max(0, dur - total)))  (\(dur > 0 ? Int(total / dur * 100) : 0)% 단축)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }
            HStack {
                Spacer()
                Button("취소") { store.silencePreview = []; dismiss() }.keyboardShortcut(.cancelAction)
                Button("무음 잘라내기") {
                    store.applyCut(ranges, label: "무음")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(ranges.isEmpty || analyzing)
            }
        }
        .padding(22)
        .frame(width: 520)
        .task {
            if !hasTranscript { modeRaw = SilenceMode.audio.rawValue }
            analyzing = true
            _ = await store.ensureLoudness()
            analyzing = false
            if autoThreshold { threshold = store.autoSilenceThreshold().rounded() }
            recompute()
        }
        .onChange(of: modeRaw) { _, _ in recompute() }
        .onChange(of: threshold) { _, _ in recompute() }
        .onChange(of: autoThreshold) { _, on in if on { threshold = store.autoSilenceThreshold().rounded() } }
        .onChange(of: minGap) { _, _ in recompute() }
        .onChange(of: keep) { _, _ in recompute() }
        .onDisappear { store.silencePreview = [] }
    }

    func recompute() {
        guard !analyzing else { return }
        switch mode {
        case .audio:
            ranges = store.audioSilenceRanges(SilenceSettings(threshold: threshold, minSilence: minGap, padding: keep))
        case .transcript:
            ranges = store.project.silenceRanges(minGap: minGap, keep: keep)
        }
        store.silencePreview = ranges
    }
}
