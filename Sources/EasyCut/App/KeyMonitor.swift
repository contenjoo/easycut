import AppKit

/// 수정키 없는 단축키(Space, J/K/L, S, I/O, 화살표 …) 처리.
/// 글자를 입력 중인 칸에서는 동작하지 않는다.
@MainActor
final class KeyMonitor {
    private var monitor: Any?
    weak var store: EditorStore?

    init(store: EditorStore) {
        self.store = store
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let store = self.store else { return e }
            return self.handle(e, store) ? nil : e
        }
    }

    static let keyMap: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q", 13: "w",
        14: "e", 15: "r", 16: "y", 17: "t", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "o", 32: "u", 33: "[", 34: "i", 35: "p", 37: "l", 38: "j",
        40: "k", 42: "\\", 43: ",", 44: "/", 45: "n", 46: "m", 47: ".",
    ]

    private func isTyping(_ window: NSWindow?) -> Bool {
        guard let r = window?.firstResponder else { return false }
        if let tv = r as? NSTextView { return tv.isEditable }
        return r is NSTextField
    }

    private func handle(_ e: NSEvent, _ s: EditorStore) -> Bool {
        guard let win = e.window ?? NSApp.keyWindow, win.attachedSheet == nil, NSApp.modalWindow == nil else { return false }
        // 시트/패널 창에서는 무시
        guard win.sheetParent == nil, !(win is NSPanel) else { return false }
        if isTyping(win) { return false }
        let flags = e.modifierFlags.intersection([.command, .option, .control, .shift])
        // 한글 입력 상태에서도 동작하도록 글자 대신 키 위치로 판단
        let key = Self.keyMap[e.keyCode] ?? (e.charactersIgnoringModifiers?.lowercased() ?? "")
        let p = s.player
        let inTranscript = win.firstResponder is TranscriptNSTextView

        // ⌘ 조합 중 메뉴에 없는 것
        if flags == [.command] {
            switch key {
            case "c": if inTranscript { return false }; s.copySelection(); return true
            case "x": if inTranscript { return false }; s.cutSelection(); return true
            case "v": s.paste(); return true
            case "a": if inTranscript { return false }; s.selectAll(); return true
            case "d": s.duplicateSelection(); return true
            case "1": s.leftTab = .media; return true
            case "2": s.leftTab = .transcript; return true
            case "3": s.leftTab = .captions; return true
            case "4": s.leftTab = .ai; return true
            default: break
            }
            if e.keyCode == 51 { if inTranscript { return false }; s.deleteSelection(ripple: true); return true }
            return false
        }
        if flags == [.option], let d = Int(key), (0...9).contains(d) {
            let table: [Double] = [20, 1, 2, 3, 4, 5, 8, 10, 12, 16]
            p.setSpeed(table[d])
            s.showToast("재생 속도 \(TimelineNSView.speedLabel(table[d]))")
            return true
        }
        if flags == [.shift] {
            switch e.keyCode {
            case 123: s.seek(p.time - 5); return true
            case 124: s.seek(p.time + 5); return true
            default: break
            }
            if key == "z" { s.zoomToFit(); return true }
            return false
        }
        guard flags.isEmpty else { return false }

        switch e.keyCode {
        case 49: p.toggle(); return true                       // space
        case 123: p.pause(); s.seek(p.time - 1); return true   // ←
        case 124: p.pause(); s.seek(p.time + 1); return true   // →
        case 126: s.jumpEditPoint(forward: false); return true // ↑
        case 125: s.jumpEditPoint(forward: true); return true  // ↓
        case 115: s.seek(0); return true                       // home
        case 119: s.seek(p.duration); return true              // end
        case 51, 117:                                          // delete
            if inTranscript { return false }
            s.deleteSelection(ripple: false); return true
        case 53:                                               // esc
            s.selection = []; s.selectedCaption = nil; s.clearMarks(); return true
        default: break
        }
        if inTranscript && (e.keyCode == 36 || e.keyCode == 76) { return false }

        switch key {
        case "k": p.pause(); return true
        case "l": p.faster(); return true
        case "j": p.slower(); return true
        case "]": p.stepUp(); s.showToast("재생 속도 \(TimelineNSView.speedLabel(p.speed))"); return true
        case "[": p.setSpeed((PlayerController.speeds.last { $0 < p.speed - 0.01 }) ?? 0.25); s.showToast("재생 속도 \(TimelineNSView.speedLabel(p.speed))"); return true
        case "\\": p.setSpeed(1); s.showToast("1배속"); return true
        case ",": p.step(frames: -1, fps: s.project.fps); return true
        case ".": p.step(frames: 1, fps: s.project.fps); return true
        case "s": s.splitAtPlayhead(); return true
        case "i": s.setMarkIn(); return true
        case "o": s.setMarkOut(); return true
        case "x": s.clearMarks(); return true
        case "c": s.addCaption(); return true
        case "t": s.addTextClip(); return true
        case "n": s.snapping.toggle(); s.showToast(s.snapping ? "스냅 켬" : "스냅 끔"); return true
        case "=", "+": s.zoom = min(800, s.zoom * 1.5); return true
        case "-": s.zoom = max(0.5, s.zoom / 1.5); return true
        default: return false
        }
    }
}

extension EditorStore {
    func zoomToFit() {
        let width = (NSApp.keyWindow?.frame.width ?? 1200) - 160
        zoom = min(800, max(0.5, Double(width) / max(5, project.duration)))
    }
}
