import AppKit
import Carbon

/// 화면에서 끌어서 녹화 영역 고르기. 결과는 그 화면 기준 포인트 좌표(왼쪽 위 원점).
@MainActor
enum AreaPicker {
    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class PickView: NSView {
        var start: NSPoint?
        var current: NSPoint?
        var done: ((NSRect?) -> Void)?

        override var acceptsFirstResponder: Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

        var selection: NSRect? {
            guard let a = start, let b = current else { return nil }
            return NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
            let hint = "끌어서 녹화할 영역을 고르세요 · esc 취소" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .semibold), .foregroundColor: NSColor.white]
            let hs = hint.size(withAttributes: attrs)
            hint.draw(at: NSPoint(x: bounds.midX - hs.width / 2, y: bounds.maxY - 90), withAttributes: attrs)
            guard let r = selection else { return }
            NSColor.clear.setFill()
            r.fill(using: .copy)
            NSColor.systemRed.setStroke()
            let p = NSBezierPath(rect: r)
            p.lineWidth = 2
            p.stroke()
            let size = "\(Int(r.width)) × \(Int(r.height))" as NSString
            size.draw(at: NSPoint(x: r.minX + 6, y: r.maxY + 6), withAttributes: attrs)
        }

        override func mouseDown(with event: NSEvent) { start = convert(event.locationInWindow, from: nil); current = start; needsDisplay = true }
        override func mouseDragged(with event: NSEvent) { current = convert(event.locationInWindow, from: nil); needsDisplay = true }
        override func mouseUp(with event: NSEvent) {
            current = convert(event.locationInWindow, from: nil)
            if let r = selection, r.width >= 40, r.height >= 40 { done?(r) } else { start = nil; current = nil; needsDisplay = true }
        }
        override func keyDown(with event: NSEvent) { if event.keyCode == 53 { done?(nil) } }
    }

    static func pick(on screen: NSScreen) async -> CGRect? {
        await withCheckedContinuation { (c: CheckedContinuation<CGRect?, Never>) in
            let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let v = PickView(frame: NSRect(origin: .zero, size: screen.frame.size))
            var finished = false
            v.done = { r in
                guard !finished else { return }
                finished = true
                w.orderOut(nil)
                // 뷰 좌표(왼쪽 아래 원점) → 화면 기준 왼쪽 위 원점
                c.resume(returning: r.map { CGRect(x: $0.minX, y: screen.frame.height - $0.maxY, width: $0.width, height: $0.height) })
            }
            w.contentView = v
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            w.makeFirstResponder(v)
        }
    }

    /// 녹화 중 영역 바깥에 그리는 빨간 테두리 (녹화에는 찍히지 않음)
    static func borderWindow(for area: CGRect, on screen: NSScreen) -> NSWindow {
        let f = NSRect(x: screen.frame.minX + area.minX, y: screen.frame.maxY - area.maxY, width: area.width, height: area.height).insetBy(dx: -4, dy: -4)
        let w = NSWindow(contentRect: f, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .floating
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let v = BorderView(frame: NSRect(origin: .zero, size: f.size))
        w.contentView = v
        return w
    }

    private final class BorderView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemRed.setStroke()
            let p = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
            p.lineWidth = 3
            p.setLineDash([10, 6], count: 2, phase: 0)
            p.stroke()
        }
    }
}

/// 녹화 중에만 쓰는 전역 단축키 (다른 앱이 앞에 있어도 동작, 별도 권한 불필요)
final class RecordHotKeys {
    enum Action: UInt32 { case stop = 1, pause = 2 }

    nonisolated(unsafe) private static var handler: ((Action) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    func register(_ onAction: @escaping (Action) -> Void) {
        unregister()
        Self.handler = onAction
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if let a = RecordHotKeys.Action(rawValue: hk.id) { DispatchQueue.main.async { RecordHotKeys.handler?(a) } }
            return noErr
        }, 1, &spec, nil, &eventHandler)
        let sig = OSType(0x4543_5452) // 'ECTR'
        for (key, action) in [(kVK_ANSI_Period, Action.stop), (kVK_ANSI_P, Action.pause)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), UInt32(cmdKey | optionKey), EventHotKeyID(signature: sig, id: action.rawValue),
                                GetApplicationEventTarget(), 0, &ref)
            if let ref { refs.append(ref) }
        }
    }

    func unregister() {
        for r in refs { UnregisterEventHotKey(r) }
        refs = []
        if let h = eventHandler { RemoveEventHandler(h); eventHandler = nil }
        Self.handler = nil
    }
}
