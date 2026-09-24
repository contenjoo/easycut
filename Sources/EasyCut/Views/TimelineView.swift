import SwiftUI
import AppKit
import Combine

/// 멀티 트랙 타임라인 (AppKit 커스텀 뷰: 긴 영상도 보이는 부분만 그린다)
struct TimelineContainer: NSViewRepresentable {
    @ObservedObject var store: EditorStore

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = false
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.timelineBG
        let view = TimelineNSView(store: store)
        scroll.documentView = view
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(view, selector: #selector(TimelineNSView.scrolled), name: NSView.boundsDidChangeNotification, object: scroll.contentView)
        view.refreshSize()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? TimelineNSView)?.refreshSize()
        scroll.documentView?.needsDisplay = true
    }
}

final class TimelineNSView: NSView {
    unowned let store: EditorStore
    private var bag: Set<AnyCancellable> = []

    // 레이아웃
    let headerW: CGFloat = 116
    let rulerH: CGFloat = 26
    let captionH: CGFloat = 30
    var trackH: CGFloat { CGFloat(store.trackHeight) }
    /// 트랙이 낮으면 이름과 아이콘을 한 줄에 놓는다
    private var compactHeader: Bool { trackH < 52 }
    private func iconOrigin(track ti: Int, mute: Bool) -> NSPoint {
        let y = rowY(track: ti)
        if compactHeader { return NSPoint(x: mute ? 52 : 76, y: y + (trackH - 16) / 2) }
        return NSPoint(x: mute ? 10 : 36, y: y + 30)
    }
    let edgeW: CGFloat = 7

    // 드래그 상태
    private enum Drag {
        case scrub
        case move(id: UUID, grabDT: Double, origStart: Double, origTrack: Int, dt: Double, dTrack: Int)
        case trim(id: UUID, left: Bool, dt: Double)
        case captionMove(id: UUID, dt: Double)
        case captionTrim(id: UUID, left: Bool, dt: Double)
        case marquee(from: NSPoint, to: NSPoint)
        case range(from: Double)
    }
    private var drag: Drag?
    private var mouseDownPoint: NSPoint = .zero
    private var dropIndicator: (track: Int, time: Double)?
    private var lastPlayheadX: CGFloat = -1

    init(store: EditorStore) {
        self.store = store
        super.init(frame: .zero)
        registerForDraggedTypes([.string, .fileURL])
        store.player.$time
            .receive(on: RunLoop.main)
            .sink { [weak self] t in self?.playheadMoved(t) }
            .store(in: &bag)
        store.media.$version
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.needsDisplay = true }
            .store(in: &bag)
        Publishers.Merge4(store.$selection.map { _ in () }, store.$selectedCaption.map { _ in () },
                          store.$markIn.map { _ in () }, store.$markOut.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.needsDisplay = true }
            .store(in: &bag)
        store.$silencePreview
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.needsDisplay = true }
            .store(in: &bag)
        store.$zoom
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.zoomChanged() } }
            .store(in: &bag)
        store.$trackHeight
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshSize()
                    self.needsDisplay = true
                    self.window?.invalidateCursorRects(for: self)
                }
            }
            .store(in: &bag)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var project: Project { store.project }
    var zoom: CGFloat { CGFloat(store.zoom) }

    func x(_ t: Double) -> CGFloat { headerW + CGFloat(t) * zoom }
    func t(_ x: CGFloat) -> Double { max(0, Double((x - headerW) / zoom)) }

    /// 트랙 인덱스 → 행의 y (위에서부터: 자막 행, 가장 위 트랙 … 트랙 1)
    func rowY(track ti: Int) -> CGFloat {
        rulerH + captionH + CGFloat(project.tracks.count - 1 - ti) * trackH
    }

    func track(atY y: CGFloat) -> Int? {
        let rel = y - rulerH - captionH
        guard rel >= 0 else { return nil }
        let row = Int(rel / trackH)
        let ti = project.tracks.count - 1 - row
        return ti
    }

    func refreshSize() {
        guard let clip = enclosingScrollView?.contentView else { return }
        let dur = max(project.duration, store.player.duration) + 30
        let w = max(clip.bounds.width, x(dur) + 200)
        let h = max(clip.bounds.height, rulerH + captionH + CGFloat(project.tracks.count) * trackH + trackH)
        if abs(frame.width - w) > 0.5 || abs(frame.height - h) > 0.5 {
            setFrameSize(NSSize(width: w, height: h))
        }
    }

    @objc func scrolled() {
        needsDisplay = true
    }

    private func zoomChanged() {
        guard let clip = enclosingScrollView?.contentView else { return }
        // 재생헤드를 화면의 같은 위치에 유지하며 확대/축소
        let px = x(store.time)
        refreshSize()
        let target = max(0, px - clip.bounds.width * 0.4)
        clip.scroll(to: NSPoint(x: min(target, max(0, frame.width - clip.bounds.width)), y: clip.bounds.origin.y))
        enclosingScrollView?.reflectScrolledClipView(clip)
        needsDisplay = true
    }

    private func playheadMoved(_ time: Double) {
        let px = x(time)
        guard abs(px - lastPlayheadX) >= 0.5 else { return }
        let vis = visibleRect
        setNeedsDisplay(NSRect(x: lastPlayheadX - 8, y: vis.minY, width: 16, height: vis.height))
        setNeedsDisplay(NSRect(x: px - 8, y: vis.minY, width: 16, height: vis.height))
        // 시간 표시가 있는 눈금자 영역도 다시 그림
        setNeedsDisplay(NSRect(x: vis.minX, y: vis.minY, width: vis.width, height: rulerH))
        lastPlayheadX = px
        if store.player.isPlaying && store.followPlayhead, drag == nil, let clip = enclosingScrollView?.contentView {
            let b = clip.bounds
            if px > b.maxX - 40 || px < b.minX + headerW {
                refreshSize()
                clip.scroll(to: NSPoint(x: max(0, px - headerW - 40), y: b.origin.y))
                enclosingScrollView?.reflectScrolledClipView(clip)
                needsDisplay = true
            }
        }
    }

    // MARK: 그리기

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let vis = visibleRect
        Theme.timelineBG.setFill()
        dirtyRect.fill()

        let p = project
        // 트랙 행 배경
        for ti in p.tracks.indices {
            let y = rowY(track: ti)
            let r = NSRect(x: vis.minX, y: y, width: vis.width, height: trackH)
            guard r.intersects(dirtyRect) else { continue }
            (ti % 2 == 0 ? Theme.rowA : Theme.rowB).setFill()
            r.fill()
            Theme.gridLine.setFill()
            NSRect(x: vis.minX, y: y + trackH - 1, width: vis.width, height: 1).fill()
        }
        // 자막 행
        let capRow = NSRect(x: vis.minX, y: rulerH, width: vis.width, height: captionH)
        Theme.captionRow.setFill()
        capRow.fill()

        // 구간(In/Out)
        if let a = store.markIn ?? store.markRange?.lowerBound {
            let b = store.markOut ?? a
            let r = NSRect(x: x(min(a, b)), y: vis.minY, width: max(2, abs(x(b) - x(a))), height: vis.height)
            Theme.markRange.setFill()
            r.fill()
        }

        drawCaptions(p, dirtyRect)
        drawClips(p, dirtyRect, ctx)

        // 무음 컷 미리보기
        if !store.silencePreview.isEmpty {
            let top = rulerH
            for r in store.silencePreview {
                let rr = NSRect(x: x(r.lowerBound), y: top, width: max(1, CGFloat(r.upperBound - r.lowerBound) * zoom), height: vis.maxY - top)
                guard rr.intersects(dirtyRect) else { continue }
                NSColor.systemRed.withAlphaComponent(0.28).setFill()
                rr.fill()
                NSColor.systemRed.withAlphaComponent(0.8).setFill()
                NSRect(x: rr.minX, y: top, width: rr.width, height: 3).fill()
            }
        }

        // 기본 트랙에서 끌면 끼워 넣을 위치를 노란 선으로 보여 준다
        if let (tIns, ti) = reorderTarget() {
            Theme.handle.setFill()
            NSRect(x: x(tIns) - 1.5, y: rowY(track: ti) - 2, width: 3, height: trackH + 4).fill()
        }

        if let d = dropIndicator {
            Theme.accent.setFill()
            NSRect(x: x(d.time) - 1, y: rowY(track: d.track), width: 3, height: trackH).fill()
        }
        if case .marquee(let a, let b) = drag {
            let r = NSRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
            Theme.accent.withAlphaComponent(0.15).setFill(); r.fill()
            Theme.accent.setStroke(); NSBezierPath(rect: r).stroke()
        }

        drawRuler(vis)
        drawHeaders(p, vis)
        drawPlayhead(vis)
    }

    /// 기본 트랙(트랙 1) 클립을 ⌥ 없이 끄는 중이면 순서 바꾸기(끼워 넣기) 위치
    private var freeMove = false
    private var marqueeBase: Set<UUID> = []
    private var lastPointerT: Double = 0

    private func reorderTarget() -> (Double, Int)? {
        guard case .move(let id, _, _, let origTrack, _, let dTrack) = drag, origTrack == 0, dTrack == 0, !freeMove,
              store.selection.count <= 1, let c = project.clip(id) else { return nil }
        guard let t = project.insertionPoint(track: 0, excluding: id, pointer: lastPointerT),
              t < c.start - Project.eps || t > c.end + Project.eps else { return nil }
        return (t, 0)
    }

    private func drawRuler(_ vis: NSRect) {
        let r = NSRect(x: vis.minX, y: vis.minY, width: vis.width, height: rulerH)
        Theme.ruler.setFill()
        r.fill()
        // 눈금 간격: 라벨이 최소 70px 떨어지도록
        let steps: [Double] = [0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let major = steps.first { CGFloat($0) * zoom >= 80 } ?? 3600
        let minor = major / 5
        let t0 = t(vis.minX + headerW), t1 = t(vis.maxX)
        var tt = (t0 / minor).rounded(.down) * minor
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular), .foregroundColor: Theme.rulerText]
        while tt <= t1 + minor {
            let px = x(tt)
            let isMajor = abs((tt / major).rounded() - tt / major) < 0.001
            Theme.rulerTick.setFill()
            NSRect(x: px, y: vis.minY + (isMajor ? 12 : 19), width: 1, height: isMajor ? 14 : 7).fill()
            if isMajor {
                let label = major < 1 ? String(format: "%.1f", tt) : TimeFormat.short(tt)
                (label as NSString).draw(at: NSPoint(x: px + 3, y: vis.minY + 1), withAttributes: attrs)
            }
            tt += minor
        }
    }

    private func drawHeaders(_ p: Project, _ vis: NSRect) {
        let bg = NSRect(x: vis.minX, y: vis.minY, width: headerW, height: vis.height)
        Theme.header.setFill()
        bg.fill()
        Theme.gridLine.setFill()
        NSRect(x: vis.minX + headerW - 1, y: vis.minY, width: 1, height: vis.height).fill()

        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let dim: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        (L("자막") as NSString).draw(at: NSPoint(x: vis.minX + 10, y: rulerH + 8), withAttributes: title)
        let capToggle = store.project.showCaptions ? "표시" : "숨김"
        (L(capToggle) as NSString).draw(at: NSPoint(x: vis.minX + headerW - 38, y: rulerH + 8), withAttributes: dim)

        for (ti, tr) in p.tracks.enumerated() {
            let y = rowY(track: ti)
            (L(tr.name) as NSString).draw(at: NSPoint(x: vis.minX + 10, y: compactHeader ? y + (trackH - 14) / 2 : y + 8), withAttributes: title)
            let m = iconOrigin(track: ti, mute: true), h = iconOrigin(track: ti, mute: false)
            drawIcon(tr.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", at: NSPoint(x: vis.minX + m.x, y: m.y), on: !tr.muted)
            drawIcon(tr.hidden ? "eye.slash.fill" : "eye.fill", at: NSPoint(x: vis.minX + h.x, y: h.y), on: !tr.hidden)
        }
        // 눈금자 왼쪽 모서리
        Theme.ruler.setFill()
        NSRect(x: vis.minX, y: vis.minY, width: headerW, height: rulerH).fill()
        let tc: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold), .foregroundColor: Theme.playhead]
        (TimeFormat.clock(store.time) as NSString).draw(at: NSPoint(x: vis.minX + 8, y: vis.minY + 5), withAttributes: tc)
    }

    private func drawIcon(_ name: String, at pt: NSPoint, on: Bool) {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular)) else { return }
        let tinted = img.tinted(on ? NSColor.labelColor : NSColor.systemRed)
        tinted.draw(in: NSRect(x: pt.x, y: pt.y, width: 18, height: 16))
    }

    private func headerIconHit(_ pt: NSPoint) -> (track: Int, mute: Bool)? {
        guard let ti = track(atY: pt.y), project.tracks.indices.contains(ti) else { return nil }
        let lx = pt.x - visibleRect.minX
        for mute in [true, false] {
            let o = iconOrigin(track: ti, mute: mute)
            if NSRect(x: o.x - 4, y: o.y - 4, width: 26, height: 24).contains(NSPoint(x: lx, y: pt.y)) { return (ti, mute) }
        }
        return nil
    }

    private func drawPlayhead(_ vis: NSRect) {
        let px = x(store.time)
        Theme.playhead.setFill()
        NSRect(x: px - 0.5, y: vis.minY, width: 2, height: vis.height).fill()
        let tri = NSBezierPath()
        tri.move(to: NSPoint(x: px - 6, y: vis.minY + rulerH - 10))
        tri.line(to: NSPoint(x: px + 7, y: vis.minY + rulerH - 10))
        tri.line(to: NSPoint(x: px + 0.5, y: vis.minY + rulerH))
        tri.close()
        tri.fill()
        lastPlayheadX = px
    }

    /// 드래그 중 미리보기 반영한 클립 위치
    private func displayed(_ c: Clip, track ti: Int) -> (clip: Clip, track: Int) {
        guard let drag else { return (c, ti) }
        switch drag {
        case .move(let id, _, _, _, let dt, let dTrack) where store.selection.contains(c.id) || id == c.id:
            var n = c
            n.start = max(0, c.start + dt)
            return (n, max(0, min(project.tracks.count - 1, ti + dTrack)))
        case .trim(let id, let left, let dt) where id == c.id:
            var n = c
            if left {
                let s = min(c.end - Project.minClipDuration, max(0, c.start + dt))
                if n.kind == .media, project.asset(n.assetID)?.kind != .image {
                    let s2 = max(s, c.start - c.sourceIn / c.speed)
                    n.sourceIn = c.sourceTime(atTimeline: s2); n.start = s2
                } else { n.start = s; n.sourceOut = c.end - s; n.sourceIn = 0 }
            } else {
                var e = max(c.start + Project.minClipDuration, c.end + dt)
                if n.kind == .media, let a = project.asset(n.assetID), a.kind != .image { e = min(e, c.timelineTime(atSource: a.duration)) }
                n.sourceOut = c.sourceTime(atTimeline: e)
            }
            return (n, ti)
        default:
            return (c, ti)
        }
    }

    private func drawClips(_ p: Project, _ dirty: NSRect, _ ctx: CGContext) {
        let nameAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        for (ti0, tr) in p.tracks.enumerated() {
            for c0 in tr.clips {
                let (c, ti) = displayed(c0, track: ti0)
                let r = NSRect(x: x(c.start), y: rowY(track: ti) + 3, width: max(2, CGFloat(c.duration) * zoom), height: trackH - 6)
                guard r.intersects(dirty) else { continue }
                let asset = p.asset(c.assetID)
                let kind: MediaKind? = c.kind == .text ? nil : asset?.kind
                let color: NSColor = {
                    if c.kind == .text { return Theme.textClip }
                    switch kind { case .video: return Theme.videoClip; case .audio: return Theme.audioClip; case .image: return Theme.imageClip; default: return .gray }
                }()
                let path = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
                ctx.saveGState()
                path.addClip()
                color.withAlphaComponent(tr.hidden ? 0.35 : 1).setFill()
                r.fill()
                let visibleX = r.intersection(dirty.insetBy(dx: -150, dy: 0))

                // 썸네일
                if let asset, kind == .video || kind == .image {
                    let thumbW = (r.height - 16) * 16 / 9
                    let thumbRect = NSRect(x: r.minX, y: r.minY + 16, width: r.width, height: r.height - 16)
                    if thumbW > 4 {
                        var sx = max(r.minX, floor((visibleX.minX - r.minX) / thumbW) * thumbW + r.minX)
                        while sx < min(r.maxX, visibleX.maxX) {
                            let src = kind == .image ? 0 : c.sourceTime(atTimeline: t(sx + thumbW / 2))
                            if let img = store.media.thumb(asset.id, at: src) {
                                let iw = CGFloat(img.width), ih = CGFloat(img.height)
                                let h = thumbRect.height, w = min(thumbW, h * iw / max(1, ih))
                                ctx.saveGState()
                                ctx.translateBy(x: sx, y: thumbRect.maxY)
                                ctx.scaleBy(x: 1, y: -1)
                                ctx.setAlpha(0.85)
                                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                                ctx.restoreGState()
                            }
                            sx += thumbW
                        }
                    }
                }
                // 파형
                if let asset, kind == .audio || kind == .video, let wave = store.media.waveforms[asset.id], !wave.isEmpty {
                    let h: CGFloat = kind == .audio ? r.height - 18 : 16
                    let baseY = r.maxY - 2
                    let mid = kind == .audio ? r.minY + 16 + h / 2 : baseY - h / 2
                    (kind == .audio ? NSColor.white.withAlphaComponent(0.75) : NSColor(calibratedRed: 0.6, green: 1, blue: 0.7, alpha: 0.85)).setFill()
                    if kind == .video {
                        NSColor.black.withAlphaComponent(0.35).setFill()
                        NSRect(x: r.minX, y: baseY - h, width: r.width, height: h).fill()
                        NSColor(calibratedRed: 0.55, green: 0.95, blue: 0.65, alpha: 0.9).setFill()
                    }
                    var px = max(r.minX, visibleX.minX)
                    let end = min(r.maxX, visibleX.maxX)
                    let volScale = CGFloat(min(1.5, c.volume))
                    while px < end {
                        let s0 = c.sourceTime(atTimeline: t(px)), s1 = c.sourceTime(atTimeline: t(px + 2))
                        let i0 = max(0, Int(s0 * MediaCache.waveRate)), i1 = min(wave.count, max(i0 + 1, Int(s1 * MediaCache.waveRate)))
                        var peak: Float = 0
                        if i0 < wave.count { for i in i0..<i1 { peak = max(peak, wave[i]) } }
                        let ph = max(1, CGFloat(peak) * h * volScale * (tr.muted ? 0.3 : 1))
                        NSRect(x: px, y: min(max(mid - ph / 2, r.minY), r.maxY - ph), width: 1.5, height: min(ph, h)).fill()
                        px += 2
                    }
                }
                // 제목 띠
                NSColor.black.withAlphaComponent(0.28).setFill()
                NSRect(x: r.minX, y: r.minY, width: r.width, height: 16).fill()
                var label = c.kind == .text ? "T  \(c.text)" : (asset?.name ?? L("(없음)"))
                if abs(c.speed - 1) > 0.001 { label = "⏩\(Self.speedLabel(c.speed))  " + label }
                if asset?.words != nil { label = "💬 " + label }
                if c.groupID != nil { label = "🔗 " + label }
                let labelX = max(r.minX + 5, min(visibleRect.minX + headerW + 5, r.maxX - 60))
                (label as NSString).draw(with: NSRect(x: labelX, y: r.minY + 1, width: max(0, r.maxX - labelX - 4), height: 14),
                                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: nameAttrs)
                ctx.restoreGState()

                // 선택 테두리 / 트림 손잡이
                if store.selection.contains(c.id) {
                    NSColor.white.setStroke()
                    let sp = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
                    sp.lineWidth = 2
                    sp.stroke()
                    Theme.handle.setFill()
                    NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.minY + 12, width: 5, height: r.height - 24), xRadius: 2, yRadius: 2).fill()
                    NSBezierPath(roundedRect: NSRect(x: r.maxX - 5, y: r.minY + 12, width: 5, height: r.height - 24), xRadius: 2, yRadius: 2).fill()
                } else {
                    NSColor.black.withAlphaComponent(0.4).setStroke()
                    NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5).stroke()
                }
                // 그룹: 아래쪽 청록 띠
                if c.groupID != nil {
                    NSColor.systemTeal.setFill()
                    NSRect(x: r.minX + 2, y: r.maxY - 4, width: max(0, r.width - 4), height: 3).fill()
                }
            }
        }
    }

    static func speedLabel(_ s: Double) -> String {
        s == s.rounded() ? "\(Int(s))x" : String(format: "%.2gx", s)
    }

    private func displayedCaption(_ c: Caption) -> Caption {
        guard let drag else { return c }
        var n = c
        switch drag {
        case .captionMove(let id, let dt) where id == c.id:
            let d = max(-c.start, dt)
            n.start += d; n.end += d
        case .captionTrim(let id, let left, let dt) where id == c.id:
            if left { n.start = min(c.end - 0.1, max(0, c.start + dt)) } else { n.end = max(c.start + 0.1, c.end + dt) }
        default: break
        }
        return n
    }

    private func drawCaptions(_ p: Project, _ dirty: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.white]
        for c0 in p.captions {
            let c = displayedCaption(c0)
            let r = NSRect(x: x(c.start), y: rulerH + 4, width: max(2, CGFloat(c.end - c.start) * zoom), height: captionH - 8)
            guard r.intersects(dirty) else { continue }
            let sel = store.selectedCaption == c.id
            (sel ? Theme.captionClipSel : Theme.captionClip).setFill()
            NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            if r.width > 14 {
                (c.text as NSString).draw(with: r.insetBy(dx: 4, dy: 3), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attrs)
            }
            if sel {
                NSColor.white.setStroke()
                NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).stroke()
            }
        }
    }

    // MARK: 마우스

    private func clipHit(_ pt: NSPoint) -> (clip: Clip, track: Int, edge: Int)? {
        guard let ti = track(atY: pt.y), project.tracks.indices.contains(ti) else { return nil }
        let y = rowY(track: ti)
        guard pt.y >= y + 3, pt.y <= y + trackH - 3 else { return nil }
        for c in project.tracks[ti].clips.reversed() {
            let x0 = x(c.start), x1 = x(c.end)
            if pt.x >= x0 - 2 && pt.x <= x1 + 2 {
                let edgeZone = min(edgeW, (x1 - x0) / 3)
                let edge = pt.x <= x0 + edgeZone ? -1 : (pt.x >= x1 - edgeZone ? 1 : 0)
                return (c, ti, edge)
            }
        }
        return nil
    }

    private func captionHit(_ pt: NSPoint) -> (Caption, Int)? {
        guard pt.y >= rulerH, pt.y < rulerH + captionH else { return nil }
        for c in project.captions {
            let x0 = x(c.start), x1 = x(c.end)
            if pt.x >= x0 - 2 && pt.x <= x1 + 2 {
                let z = min(edgeW, (x1 - x0) / 3)
                return (c, pt.x <= x0 + z ? -1 : (pt.x >= x1 - z ? 1 : 0))
            }
        }
        return nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        let vis = visibleRect
        for (ti, tr) in project.tracks.enumerated() {
            let y = rowY(track: ti)
            for c in tr.clips {
                let x0 = x(c.start), x1 = x(c.end)
                guard x1 > vis.minX + headerW, x0 < vis.maxX else { continue }
                let z = min(edgeW, (x1 - x0) / 3)
                addCursorRect(NSRect(x: x0, y: y + 3, width: z, height: trackH - 6), cursor: .resizeLeftRight)
                addCursorRect(NSRect(x: x1 - z, y: y + 3, width: z, height: trackH - 6), cursor: .resizeLeftRight)
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let pt = convert(event.locationInWindow, from: nil)
        mouseDownPoint = pt
        let vis = visibleRect

        // 구간(시작~끝)이 잡혀 있을 때 다른 곳을 누르면 구간을 푼다 → 모르고 ⌫ 눌러 그 구간이 지워지는 일 방지
        // (I만 찍은 상태는 그대로 두어 I → 이동 → O 흐름은 유지)
        if store.markRange != nil, !(pt.y - vis.minY < rulerH && abs(pt.x - x(store.time)) <= 8) {
            store.clearMarks()
        }
        // 눈금자: 재생헤드를 잡으면 이동, 다른 곳을 끌면 구간 선택
        if pt.y - vis.minY < rulerH {
            store.player.pause()
            if abs(pt.x - x(store.time)) <= 8 {
                drag = .scrub
            } else {
                drag = .range(from: snap(t(max(pt.x, vis.minX + headerW)), excluding: nil))
            }
            store.seek(t(max(pt.x, vis.minX + headerW)))
            return
        }
        // 트랙 헤더
        if pt.x - vis.minX < headerW {
            if pt.y >= rulerH && pt.y < rulerH + captionH {
                store.updateProject(key: "showCaptions") { $0.showCaptions.toggle() }
            } else if let h = headerIconHit(pt) {
                store.toggleTrack(h.track, mute: h.mute)
            }
            return
        }
        // 자막 행
        if pt.y >= rulerH && pt.y < rulerH + captionH {
            if let (c, edge) = captionHit(pt) {
                store.selection = []
                store.selectedCaption = c.id
                drag = edge == 0 ? .captionMove(id: c.id, dt: 0) : .captionTrim(id: c.id, left: edge < 0, dt: 0)
                if event.clickCount == 2 { store.leftTab = .captions; store.seek(c.start) }
            } else {
                store.selectedCaption = nil
                store.seek(t(pt.x))
                drag = .range(from: snap(t(pt.x), excluding: nil))
            }
            return
        }
        // 클립
        if let hit = clipHit(pt) {
            store.selectedCaption = nil
            if event.modifierFlags.contains(.command) {
                if store.selection.contains(hit.clip.id) { store.selection.remove(hit.clip.id) } else { store.selection.insert(hit.clip.id) }
            } else if event.modifierFlags.contains(.shift) {
                store.selection.insert(hit.clip.id)
            } else if !store.selection.contains(hit.clip.id) {
                store.selection = [hit.clip.id]
            }
            // 그룹이면 동료 클립도 함께 선택
            store.selection = project.groupMembers(of: store.selection)
            if hit.edge != 0 && hit.clip.groupID == nil {
                store.selection = [hit.clip.id]
                drag = .trim(id: hit.clip.id, left: hit.edge < 0, dt: 0)
            } else {
                drag = .move(id: hit.clip.id, grabDT: t(pt.x) - hit.clip.start, origStart: hit.clip.start, origTrack: hit.track, dt: 0, dTrack: 0)
            }
            if event.clickCount == 2, hit.clip.kind == .media { store.seek(hit.clip.start) }
            needsDisplay = true
            return
        }
        // 빈 곳: 선택 해제 + 재생헤드 이동. 끌면 클립 여러 개 선택 (⇧/⌘ = 기존 선택에 더하기)
        // 시간 구간 선택은 눈금자를 끈다
        let additive = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
        marqueeBase = additive ? store.selection : []
        if !additive { store.selection = [] }
        store.selectedCaption = nil
        store.seek(t(pt.x))
        drag = .marquee(from: pt, to: pt)
    }

    private func snap(_ time: Double, excluding id: UUID?) -> Double {
        guard store.snapping else { return time }
        var cands = [0, store.time]
        for c in project.tracks.flatMap(\.clips) where c.id != id && !store.selection.contains(c.id) { cands.append(c.start); cands.append(c.end) }
        if let a = store.markIn { cands.append(a) }
        if let b = store.markOut { cands.append(b) }
        let tol = Double(8 / zoom)
        if let best = cands.min(by: { abs($0 - time) < abs($1 - time) }), abs(best - time) < tol { return best }
        return time
    }

    override func mouseDragged(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        autoscroll(with: event)
        guard let d = drag else { return }
        switch d {
        case .scrub:
            store.seek(t(max(pt.x, visibleRect.minX + headerW)))
        case .move(let id, let grab, let orig, let origTrack, _, _):
            guard let c = project.clip(id) else { return }
            lastPointerT = t(pt.x)
            freeMove = event.modifierFlags.contains(.option)
            var newStart = max(0, t(pt.x) - grab)
            // 시작/끝 모두 스냅 후보로
            let s1 = snap(newStart, excluding: id)
            if s1 != newStart { newStart = s1 } else {
                let e1 = snap(newStart + c.duration, excluding: id)
                if e1 != newStart + c.duration { newStart = e1 - c.duration }
            }
            let targetTrack = track(atY: pt.y) ?? origTrack
            let dTrack = max(0, min(project.tracks.count - 1, targetTrack)) - origTrack
            drag = .move(id: id, grabDT: grab, origStart: orig, origTrack: origTrack, dt: newStart - orig, dTrack: dTrack)
        case .trim(let id, let left, _):
            guard let c = project.clip(id) else { return }
            let tt = snap(t(pt.x), excluding: id)
            drag = .trim(id: id, left: left, dt: tt - (left ? c.start : c.end))
        case .captionMove(let id, _):
            guard let c = project.captions.first(where: { $0.id == id }) else { return }
            drag = .captionMove(id: id, dt: snap(t(pt.x) - t(mouseDownPoint.x) + c.start, excluding: nil) - c.start)
        case .captionTrim(let id, let left, _):
            guard let c = project.captions.first(where: { $0.id == id }) else { return }
            let tt = snap(t(pt.x), excluding: nil)
            drag = .captionTrim(id: id, left: left, dt: tt - (left ? c.start : c.end))
        case .range(let from):
            // 4px 이상 끌어야 구간으로 본다 (그냥 클릭은 재생헤드 이동만)
            guard abs(pt.x - x(from)) > 4 else { return }
            let to = snap(t(max(pt.x, visibleRect.minX + headerW)), excluding: nil)
            // 구간을 잡으면 클립 선택은 풀어 ⌫가 구간에만 적용되게
            if !store.selection.isEmpty { store.selection = [] }
            store.markIn = min(from, to)
            store.markOut = max(from, to)
            store.seek(to)
        case .marquee(let from, _):
            drag = .marquee(from: from, to: pt)
            let r = NSRect(x: min(from.x, pt.x), y: min(from.y, pt.y), width: abs(from.x - pt.x), height: abs(from.y - pt.y))
            if r.width > 4 || r.height > 4 {
                var sel = marqueeBase
                for (ti, tr) in project.tracks.enumerated() {
                    for c in tr.clips {
                        let cr = NSRect(x: x(c.start), y: rowY(track: ti) + 3, width: CGFloat(c.duration) * zoom, height: trackH - 6)
                        if cr.intersects(r) { sel.insert(c.id) }
                    }
                }
                store.selection = project.groupMembers(of: sel)
            }
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; needsDisplay = true; window?.invalidateCursorRects(for: self) }
        guard let d = drag else { return }
        switch d {
        case .move(let id, _, _, let origTrack, let dt, let dTrack):
            guard abs(dt) > 0.0001 || dTrack != 0 else { return }
            // 기본 트랙: 끼워 넣어 순서 바꾸기 (⌥를 누르면 자유 이동)
            if reorderTarget() != nil {
                let pointer = lastPointerT
                store.apply { $0.reorder(clip: id, pointer: pointer) }
                store.showToast("순서를 바꿨습니다 (⌥를 누른 채 끌면 자유 이동)")
                return
            }
            let ids = store.selection.contains(id) ? store.selection : [id]
            store.apply { p in
                // 선택된 클립을 함께 이동
                let moving = ids.compactMap { cid -> (UUID, Int, Double)? in
                    guard let loc = p.locate(clip: cid) else { return nil }
                    return (cid, loc.track, p.tracks[loc.track].clips[loc.index].start)
                }.sorted { $0.2 < $1.2 }
                for (cid, ti, start) in moving {
                    let nt = max(0, min(p.tracks.count - 1, ti + dTrack))
                    p.move(clip: cid, toTrack: nt, start: start + dt)
                }
                _ = origTrack
            }
        case .trim(let id, let left, let dt):
            guard abs(dt) > 0.0001, let c = project.clip(id) else { return }
            let a = project.asset(c.assetID)
            let maxSrc: Double? = (c.kind == .media && a?.kind != .image) ? a?.duration : nil
            store.apply { p in
                if left { p.trimStart(clip: id, to: c.start + dt, maxSource: maxSrc) } else { p.trimEnd(clip: id, to: c.end + dt, maxSource: maxSrc) }
            }
        case .captionMove(let id, let dt):
            guard abs(dt) > 0.0001 else { return }
            store.updateCaption(id, key: "capmove") { c in
                let d = max(-c.start, dt)
                c.start += d; c.end += d
            }
        case .captionTrim(let id, let left, let dt):
            guard abs(dt) > 0.0001 else { return }
            store.updateCaption(id, key: "captrim") { c in
                if left { c.start = min(c.end - 0.1, max(0, c.start + dt)) } else { c.end = max(c.start + 0.1, c.end + dt) }
            }
        case .range:
            if let r = store.markRange {
                store.showToast("구간 \(TimeFormat.clock(r.lowerBound)) – \(TimeFormat.clock(r.upperBound)) · ⌫ 잘라내기 · 해제는 빈 곳 클릭, X, esc")
            }
        default:
            break
        }
    }

    override func scrollWheel(with event: NSEvent) {
        // ⌘/⌥ + 스크롤 = 확대/축소
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            let f = 1 + event.scrollingDeltaY * 0.01
            store.zoom = min(800, max(0.5, store.zoom * Double(f)))
            return
        }
        super.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let pt = convert(event.locationInWindow, from: nil)
        let menu = NSMenu()
        if let hit = clipHit(pt) {
            if !store.selection.contains(hit.clip.id) { store.selection = [hit.clip.id] }
            menu.addItem(MenuAction.item("재생헤드에서 분할  (⌘T / S)") { [weak store] in store?.splitAtPlayhead() })
            menu.addItem(MenuAction.item("복제  (⌘D)") { [weak store] in store?.duplicateSelection() })
            menu.addItem(MenuAction.item("복사  (⌘C)") { [weak store] in store?.copySelection() })
            menu.addItem(.separator())
            if store.selection.count >= 2 {
                menu.addItem(MenuAction.item("그룹으로 묶기  (⌘G)") { [weak store] in store?.groupSelection() })
                menu.addItem(MenuAction.item("하나로 합치기  (⌘J)") { [weak store] in store?.joinSelection() })
            }
            if hit.clip.groupID != nil {
                menu.addItem(MenuAction.item("그룹 해제  (⇧⌘G)") { [weak store] in store?.ungroupSelection() })
            }
            menu.addItem(.separator())
            let speed = NSMenuItem(title: L("속도"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for s in [0.25, 0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4, 8, 12, 16, 20] {
                let it = MenuAction.item(Self.speedLabel(s)) { [weak store] in store?.setSpeed(s) }
                if abs(hit.clip.speed - s) < 0.001 { it.state = .on }
                sub.addItem(it)
            }
            speed.submenu = sub
            if hit.clip.kind == .media, project.asset(hit.clip.assetID)?.kind != .image { menu.addItem(speed) }
            if let a = project.asset(hit.clip.assetID), a.hasAudio {
                menu.addItem(MenuAction.item(a.words == nil ? "음성 인식 (STT)" : "음성 다시 인식") { [weak store] in store?.transcribe(a.id) })
            }
            menu.addItem(.separator())
            menu.addItem(MenuAction.item("삭제  (⌫)") { [weak store] in store?.deleteSelection(ripple: false) })
            menu.addItem(MenuAction.item("삭제 후 빈틈 메우기  (⌘⌫)") { [weak store] in store?.deleteSelection(ripple: true) })
        } else if let (c, _) = captionHit(pt) {
            store.selectedCaption = c.id
            menu.addItem(MenuAction.item("자막 편집") { [weak store] in store?.leftTab = .captions })
            menu.addItem(MenuAction.item("자막과 영상 함께 삭제") { [weak store] in store?.deleteCaptions([c.id], withVideo: true) })
            menu.addItem(MenuAction.item("자막만 삭제 (영상 유지)") { [weak store] in store?.deleteCaptions([c.id], withVideo: false) })
        } else {
            let tt = t(pt.x)
            menu.addItem(MenuAction.item("여기에 텍스트 추가") { [weak store] in store?.seek(tt); store?.addTextClip() })
            menu.addItem(MenuAction.item("여기에 자막 추가") { [weak store] in store?.seek(tt); store?.addCaption() })
            menu.addItem(MenuAction.item("모든 트랙 분할  (⇧⌘T)") { [weak store] in store?.splitAtPlayhead(all: true) })
            menu.addItem(.separator())
            menu.addItem(MenuAction.item("트랙 추가") { [weak store] in store?.addTrack() })
            menu.addItem(MenuAction.item("빈 트랙 정리") { [weak store] in store?.removeEmptyTracks() })
        }
        return menu
    }

    // MARK: 끌어다 놓기

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let pt = convert(sender.draggingLocation, from: nil)
        let ti = max(0, min(project.tracks.count - 1, track(atY: pt.y) ?? 0))
        dropIndicator = (ti, snap(t(pt.x), excluding: nil))
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropIndicator = nil
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let d = dropIndicator else { return false }
        dropIndicator = nil
        needsDisplay = true
        let pb = sender.draggingPasteboard
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            store.importFiles(urls, place: (d.track, d.time))
            return true
        }
        if let s = pb.string(forType: .string), let id = UUID(uuidString: s) {
            store.addToTimeline(id, track: d.track, at: d.time)
            return true
        }
        return false
    }
}

/// 클로저 기반 메뉴 항목
final class MenuAction: NSObject {
    let action: () -> Void
    init(_ a: @escaping () -> Void) { action = a }
    @objc func run() { action() }

    static func item(_ title: String, _ a: @escaping () -> Void) -> NSMenuItem {
        let target = MenuAction(a)
        let it = NSMenuItem(title: L(title), action: #selector(run), keyEquivalent: "")
        it.target = target
        it.representedObject = target // 유지
        return it
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = self.copy() as! NSImage
        img.lockFocus()
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}
