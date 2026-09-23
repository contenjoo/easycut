import SwiftUI
import AppKit

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--make-icon"), i + 1 < CommandLine.arguments.count {
            IconMaker.write(to: URL(fileURLWithPath: CommandLine.arguments[i + 1]))
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--audio-probe"), i + 2 < CommandLine.arguments.count {
            SelfTest.audioProbe(URL(fileURLWithPath: CommandLine.arguments[i + 1]), at: Double(CommandLine.arguments[i + 2]) ?? 0)
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--link-test"), i + 1 < CommandLine.arguments.count {
            let a = CommandLine.arguments
            let sem = DispatchSemaphore(value: 0)
            Task.detached {
                var o = LinkImporter.Options()
                o.quality = .p720
                if i + 3 < a.count { o.start = Double(a[i + 2]); o.end = Double(a[i + 3]) }
                do {
                    let r = try await LinkImporter.download(a[i + 1], options: o) { v, m in if Int(v * 100) % 25 == 0 { print(m) } }
                    let transcode = MediaConverter.needsTranscode(r.file)
                    let asset = try await MediaProbe.probe(r.file)
                    print("완료:", r.file.path, "제목:", r.title, String(format: "길이 %.1f초 %d×%d 오디오:%@ 변환필요:%@ 자막:%d",
                          asset.duration, Int(asset.width), Int(asset.height), asset.hasAudio ? "예" : "아니오", transcode ? "예" : "아니오", r.subtitles.count))
                } catch { print("오류:", error.localizedDescription) }
                sem.signal()
            }
            while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            return
        }
        if CommandLine.arguments.contains("--mcp") {
            MCPBridge.run()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--stt-test"), i + 2 < CommandLine.arguments.count {
            STTTest.run(URL(fileURLWithPath: CommandLine.arguments[i + 1]), out: URL(fileURLWithPath: CommandLine.arguments[i + 2]))
            return
        }
        EasyCutApp.main()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 창이 뜨기 전에 들어온 파일은 모아 뒀다가 연결되면 연다
    private var pending: [URL] = []
    weak var store: EditorStore? {
        didSet { if store != nil, !pending.isEmpty { let u = pending; pending = []; openURLs(u) } }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 인터넷에서 받은 설치 파일이면 내장 도구에 붙은 격리 표시를 풀어 바로 실행되게 한다
        if let dir = Tools.bundledDir, let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) {
            for f in files { removexattr(dir.appendingPathComponent(f).path, "com.apple.quarantine", 0) }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        return MainActor.assumeIsolated { store.confirmDiscard() } ? .terminateNow : .terminateCancel
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard store != nil else { pending += urls; return }
        openURLs(urls)
    }

    private var recent: [String: Date] = [:]

    /// 같은 파일이 두 경로(델리게이트·onOpenURL)로 동시에 들어와도 한 번만 연다
    func openURLs(_ urls: [URL]) {
        guard let store else { pending += urls; return }
        let now = Date()
        let urls = urls.filter { u in
            defer { recent[u.path] = now }
            return now.timeIntervalSince(recent[u.path] ?? .distantPast) > 3
        }
        guard !urls.isEmpty else { return }
        MainActor.assumeIsolated {
            let projects = urls.filter { $0.pathExtension.lowercased() == "easycut" }
            if let p = projects.first { store.open(p) }
            let media = urls.filter { $0.pathExtension.lowercased() != "easycut" }
            if !media.isEmpty { store.importFiles(media) }
        }
    }
}

struct EasyCutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = EditorStore()

    var body: some Scene {
        Window("EasyCut", id: "main") {
            ContentView(store: store)
                .onAppear { delegate.store = store }
                // 앱이 꺼진 상태에서 파일로 실행될 때 SwiftUI가 넘겨주는 경로
                .onOpenURL { url in if url.isFileURL { delegate.openURLs([url]) } }
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1440, height: 900)
        .commands { AppCommands(store: store) }
    }
}

struct AppCommands: Commands {
    @ObservedObject var store: EditorStore

    /// 글자 입력 중이면 해당 칸의 기본 동작을 쓰도록
    func textEditing() -> NSResponder? {
        guard let r = NSApp.keyWindow?.firstResponder else { return nil }
        if let tv = r as? NSTextView, tv.isEditable { return tv }
        return nil
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("새 프로젝트") { store.newProject() }.keyboardShortcut("n")
            Button("프로젝트 열기…") { store.openPanel() }.keyboardShortcut("o")
            Divider()
            Button("미디어 가져오기…") { store.importPanel() }.keyboardShortcut("i")
            Button("링크로 가져오기 (유튜브 등)…") { store.showLinkSheet = true }.keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("저장") { store.save() }.keyboardShortcut("s")
            Button("다른 이름으로 저장…") { store.save(as: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            Divider()
            Button("영상 내보내기…") { store.showExport = true }.keyboardShortcut("e")
            Button("SRT 자막 내보내기…") { store.exportSRT() }
            Button("대본 텍스트 내보내기…") { store.exportTranscript() }
            Button("현재 장면 PNG로 저장…") { store.snapshot() }
            Divider()
            Button("SRT 자막 가져오기…") { store.importSRT() }
        }
        CommandGroup(replacing: .undoRedo) {
            Button("실행 취소") {
                if let t = textEditing() { t.undoManager?.undo() } else { store.undo() }
            }.keyboardShortcut("z")
            Button("다시 실행") {
                if let t = textEditing() { t.undoManager?.redo() } else { store.redo() }
            }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        CommandMenu("타임라인") {
            Button("재생헤드에서 분할  (S)") { store.splitAtPlayhead() }.keyboardShortcut("t")
            Button("모든 트랙 분할") { store.splitAtPlayhead(all: true) }.keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("삭제  (⌫)") { store.deleteSelection(ripple: false) }
            Button("삭제 후 빈틈 메우기  (⌘⌫)") { store.deleteSelection(ripple: true) }
            Button("복제  (⌘D)") { store.duplicateSelection() }
            Divider()
            Button("구간 시작  (I)") { store.setMarkIn() }
            Button("구간 끝  (O)") { store.setMarkOut() }
            Button("구간 해제  (X)") { store.clearMarks() }
            Divider()
            Button("텍스트(제목) 추가  (T)") { store.addTextClip() }
            Button("트랙 추가") { store.addTrack() }
            Button("빈 트랙 정리") { store.removeEmptyTracks() }
            Divider()
            Button("확대") { store.zoom = min(800, store.zoom * 1.5) }.keyboardShortcut("=")
            Button("축소") { store.zoom = max(0.5, store.zoom / 1.5) }.keyboardShortcut("-")
            Button("전체 보기  (⇧Z)") { store.zoomToFit() }
        }
        CommandMenu("재생") {
            Button("재생 / 일시정지  (Space)") { store.player.toggle() }
            Button("빠르게  (L)") { store.player.faster() }
            Button("느리게  (J)") { store.player.slower() }
            Button("정지  (K)") { store.player.pause() }
            Divider()
            Menu("재생 속도") {
                ForEach(PlayerController.speeds, id: \.self) { s in
                    Button(TimelineNSView.speedLabel(s)) { store.player.setSpeed(s) }
                }
            }
            Divider()
            Button("처음으로  (Home)") { store.seek(0) }
            Button("끝으로  (End)") { store.seek(store.player.duration) }
            Button("이전 편집점  (↑)") { store.jumpEditPoint(forward: false) }
            Button("다음 편집점  (↓)") { store.jumpEditPoint(forward: true) }
        }
        CommandMenu("도구") {
            Button("음성 인식 (STT)") { store.transcribeTimeline() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("대본으로 자막 만들기") { store.generateCaptions() }.keyboardShortcut("c", modifiers: [.command, .shift])
            Button("무음 컷 (원클릭)…") { store.showSilenceSheet = true }.keyboardShortcut("x", modifiers: [.command, .shift])
            Button("군더더기 말 제거") { store.removeFillers() }
            Divider()
            Button("자막 추가  (C)") { store.addCaption() }
            Button("음성 인식 설정…") { store.showSTTSettings = true }.keyboardShortcut(",", modifiers: [.command, .shift])
            Button("Claude 연결…") { store.showClaudeSheet = true }
        }
        CommandGroup(replacing: .help) {
            Button("단축키 보기") { store.showShortcuts = true }.keyboardShortcut("/")
        }
    }
}

/// 앱 아이콘(1024px PNG) 생성
enum IconMaker {
    static func write(to url: URL) {
        let size = 1024
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let s = CGFloat(size)
        let body = CGRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
        let path = CGPath(roundedRect: body, cornerWidth: s * 0.18, cornerHeight: s * 0.18, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
        ctx.addPath(path); ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: [
            CGColor(srgbRed: 0.98, green: 0.36, blue: 0.33, alpha: 1),
            CGColor(srgbRed: 0.55, green: 0.24, blue: 0.93, alpha: 1),
            CGColor(srgbRed: 0.16, green: 0.45, blue: 0.98, alpha: 1)] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
        // 필름 구멍
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.22))
        for i in 0..<7 {
            let x = body.minX + s * 0.06 + CGFloat(i) * s * 0.105
            ctx.fill(CGRect(x: x, y: body.maxY - s * 0.085, width: s * 0.06, height: s * 0.045))
            ctx.fill(CGRect(x: x, y: body.minY + s * 0.04, width: s * 0.06, height: s * 0.045))
        }
        ctx.restoreGState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.36, weight: .bold)
        if let sym = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let tinted = sym.tinted(.white)
            let w = tinted.size.width, h = tinted.size.height
            tinted.draw(in: CGRect(x: (s - w) / 2, y: (s - h) / 2 + s * 0.03, width: w, height: h))
        }
        let t = "EasyCut" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: s * 0.075, weight: .heavy), .foregroundColor: NSColor.white.withAlphaComponent(0.92)]
        let ts = t.size(withAttributes: attrs)
        t.draw(at: CGPoint(x: (s - ts.width) / 2, y: body.minY + s * 0.1), withAttributes: attrs)
        NSGraphicsContext.current = nil
        let img = ctx.makeImage()!
        let d = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(d, img, nil)
        CGImageDestinationFinalize(d)
    }
}

/// `--stt-test 파일 결과.txt` : 앱 번들 안에서 Apple 음성 인식 전체 과정을 실행해 결과를 기록 (진단용)
enum STTTest {
    static func run(_ url: URL, out: URL) {
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            var log = ""
            do {
                let engine: STTEngine = CommandLine.arguments.contains("--whisper") ? .whisper : .apple
                var partials = 0
                let t0 = Date()
                let words = try await Transcriber.transcribe(url: url, engine: engine, language: STTLanguage.all[0], whisperModel: nil,
                                                             partial: { _ in partials += 1 }) { _, _ in }
                print(String(format: "엔진 %@ · %.1f초 · 단어 %d개 · 중간 표시 %d회", engine == .whisper ? "Whisper" : "Apple", Date().timeIntervalSince(t0), words.count, partials))
                log = words.map { String(format: "%.2f-%.2f %@", $0.start, $0.end, $0.text) }.joined(separator: "\n")
            } catch {
                log = "오류: \(error.localizedDescription)"
            }
            try? log.write(to: out, atomically: true, encoding: .utf8)
            sem.signal()
        }
        while sem.wait(timeout: .now() + 0.05) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
}
