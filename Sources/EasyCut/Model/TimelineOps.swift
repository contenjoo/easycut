import Foundation

/// 타임라인 편집 연산. 모든 시간은 초 단위.
extension Project {
    static let minClipDuration = 0.04
    static let eps = 0.0005

    // MARK: 정리

    mutating func normalize() {
        for ti in tracks.indices {
            tracks[ti].clips.removeAll { $0.duration < Project.minClipDuration }
            for ci in tracks[ti].clips.indices where tracks[ti].clips[ci].start < 0 {
                tracks[ti].clips[ci].start = 0
            }
            tracks[ti].clips.sort { $0.start < $1.start }
        }
        captions.removeAll { $0.end - $0.start < 0.05 || $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        captions.sort { $0.start < $1.start }
    }

    /// 겹치는 클립은 뒤로 밀어서 한 트랙 안에서 겹치지 않도록 한다.
    mutating func resolveOverlaps(track ti: Int, pinned: UUID? = nil) {
        guard tracks.indices.contains(ti) else { return }
        var clips = tracks[ti].clips
        clips.sort { a, b in
            if abs(a.start - b.start) < Project.eps { return a.id == pinned }
            return a.start < b.start
        }
        var cursor = 0.0
        for i in clips.indices {
            if clips[i].start < cursor - Project.eps { clips[i].start = cursor }
            cursor = max(cursor, clips[i].end)
        }
        tracks[ti].clips = clips
    }

    // MARK: 추가

    @discardableResult
    mutating func insert(asset: MediaAsset, track ti: Int, at time: Double, imageDuration: Double = 5) -> UUID {
        while tracks.count <= ti { tracks.append(Track(name: "트랙 \(tracks.count + 1)")) }
        let dur = asset.kind == .image ? imageDuration : asset.duration
        let clip = Clip(assetID: asset.id, start: max(0, time), sourceIn: 0, sourceOut: dur)
        tracks[ti].clips.append(clip)
        resolveOverlaps(track: ti, pinned: clip.id)
        return clip.id
    }

    @discardableResult
    mutating func insertText(_ text: String, track ti: Int, at time: Double, duration: Double = 4) -> UUID {
        while tracks.count <= ti { tracks.append(Track(name: "트랙 \(tracks.count + 1)")) }
        let clip = Clip(kind: .text, text: text, textStyle: .title, start: max(0, time), sourceIn: 0, sourceOut: duration)
        tracks[ti].clips.append(clip)
        resolveOverlaps(track: ti, pinned: clip.id)
        return clip.id
    }

    func trackEnd(_ ti: Int) -> Double {
        tracks.indices.contains(ti) ? (tracks[ti].clips.map(\.end).max() ?? 0) : 0
    }

    // MARK: 분할

    /// 클립을 t 지점에서 둘로 나눈다. 새 오른쪽 클립 id를 돌려준다.
    @discardableResult
    /// minPiece: 양쪽 조각이 이보다 짧아지면 나누지 않는다 (구간 삭제는 아주 작은 값으로 정확히 자른다)
    mutating func split(clip id: UUID, at t: Double, minPiece: Double = Project.minClipDuration) -> UUID? {
        guard let loc = locate(clip: id) else { return nil }
        let c = tracks[loc.track].clips[loc.index]
        guard t > c.start + minPiece, t < c.end - minPiece else { return nil }
        let cut = c.sourceTime(atTimeline: t)
        var left = c
        var right = c
        left.sourceOut = cut
        left.fadeOut = 0
        right.id = UUID()
        right.sourceIn = cut
        right.start = t
        right.fadeIn = 0
        tracks[loc.track].clips[loc.index] = left
        tracks[loc.track].clips.insert(right, at: loc.index + 1)
        return right.id
    }

    mutating func splitAll(at t: Double, tracks only: Set<Int>? = nil, minPiece: Double = Project.minClipDuration) {
        for ti in tracks.indices where only?.contains(ti) ?? true {
            for c in tracks[ti].clips where t > c.start && t < c.end {
                split(clip: c.id, at: t, minPiece: minPiece)
            }
        }
    }

    // MARK: 삭제

    /// 선택 클립 삭제. ripple이면 같은 트랙의 뒤 클립을 당겨 빈틈을 없앤다.
    mutating func delete(clips ids: Set<UUID>, ripple: Bool) {
        for ti in tracks.indices {
            let removed = tracks[ti].clips.filter { ids.contains($0.id) }.sorted { $0.start > $1.start }
            guard !removed.isEmpty else { continue }
            tracks[ti].clips.removeAll { ids.contains($0.id) }
            if ripple {
                for r in removed {
                    for ci in tracks[ti].clips.indices where tracks[ti].clips[ci].start >= r.end - Project.eps {
                        tracks[ti].clips[ci].start -= r.duration
                    }
                }
            }
        }
    }

    /// 모든 트랙과 자막에서 [t0, t1) 구간을 잘라내고 뒤를 당긴다.
    mutating func rippleDelete(from t0: Double, to t1: Double) {
        let a = max(0, min(t0, t1)), b = max(t0, t1)
        let len = b - a
        guard len > Project.eps else { return }
        // 클립 경계 바로 옆(40ms 안)이라도 정확히 잘라야 구간이 남거나 겹치지 않는다. 남은 아주 작은 조각은 normalize가 지운다
        splitAll(at: a, minPiece: Project.eps)
        splitAll(at: b, minPiece: Project.eps)
        for ti in tracks.indices {
            tracks[ti].clips.removeAll { $0.start >= a - Project.eps && $0.end <= b + Project.eps }
            for ci in tracks[ti].clips.indices where tracks[ti].clips[ci].start >= b - Project.eps {
                tracks[ti].clips[ci].start -= len
            }
        }
        var out: [Caption] = []
        for var c in captions {
            if c.end <= a { out.append(c); continue }
            if c.start >= b { c.start -= len; c.end -= len; out.append(c); continue }
            // 구간과 겹침
            let keepBefore = max(0, a - c.start)
            let keepAfter = max(0, c.end - b)
            if keepBefore + keepAfter < 0.2 { continue }
            c.start = min(c.start, a)
            c.end = c.start + keepBefore + keepAfter
            out.append(c)
        }
        captions = out
        normalize()
    }

    /// 여러 구간을 뒤에서부터 잘라낸다.
    mutating func rippleDelete(ranges: [ClosedRange<Double>]) {
        for r in Project.merge(ranges).reversed() {
            rippleDelete(from: r.lowerBound, to: r.upperBound)
        }
    }

    static func merge(_ ranges: [ClosedRange<Double>], gap: Double = 0.01) -> [ClosedRange<Double>] {
        let sorted = ranges.filter { $0.upperBound - $0.lowerBound > 0.001 }.sorted { $0.lowerBound < $1.lowerBound }
        var out: [ClosedRange<Double>] = []
        for r in sorted {
            if let last = out.last, r.lowerBound <= last.upperBound + gap {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    // MARK: 구간째 옮기기 (자막 단위 순서 바꾸기)

    /// 타임라인 [a, b) 구간을 모든 트랙·자막째 떼어 내 t 지점(현재 타임라인 기준)에 끼워 넣는다.
    mutating func moveRange(from a: Double, to b: Double, insertAt t: Double) {
        let len = b - a
        guard len > Project.eps, t < a - Project.eps || t > b + Project.eps else { return }
        splitAll(at: a)
        splitAll(at: b)
        var moved: [(Int, Clip)] = []
        for ti in tracks.indices {
            for c in tracks[ti].clips where c.start >= a - Project.eps && c.end <= b + Project.eps {
                var n = c
                n.start -= a
                moved.append((ti, n))
            }
        }
        let movedCaps = captions.filter { $0.start >= a - Project.eps && $0.end <= b + Project.eps }
            .map { c -> Caption in var n = c; n.start -= a; n.end -= a; return n }
        rippleDelete(from: a, to: b)
        let ins = t > b ? t - len : t
        splitAll(at: ins)
        for ti in tracks.indices {
            for ci in tracks[ti].clips.indices where tracks[ti].clips[ci].start >= ins - Project.eps {
                tracks[ti].clips[ci].start += len
            }
        }
        for i in captions.indices {
            if captions[i].start >= ins - Project.eps {
                captions[i].start += len; captions[i].end += len
            } else if captions[i].end > ins {
                captions[i].end += len // 끼워 넣는 지점에 걸친 자막은 늘려 준다
            }
        }
        for (ti, c) in moved {
            var n = c
            n.start += ins
            tracks[ti].clips.append(n)
        }
        captions += movedCaps.map { c -> Caption in var n = c; n.start += ins; n.end += ins; return n }
        normalize()
    }

    /// 자막 하나가 차지하는 영상 구간 (다음 자막 직전까지 포함해 어색한 공백을 남기지 않는다)
    func span(ofCaption id: UUID) -> ClosedRange<Double>? {
        let sorted = captions.sorted { $0.start < $1.start }
        guard let i = sorted.firstIndex(where: { $0.id == id }) else { return nil }
        let c = sorted[i]
        var end = c.end
        if i + 1 < sorted.count {
            let next = sorted[i + 1].start
            // 문장 뒤 쉬는 시간(3초 이내)도 그 문장과 함께 옮기거나 지운다
            if next - c.end < 3.0 { end = max(c.end, next) }
        }
        end = min(end, max(duration, c.end))
        return c.start...max(end, c.start + 0.05)
    }

    /// 기본 트랙 클립을 떨어뜨린 위치(포인터 시각)에 맞춰 순서를 바꾼다
    mutating func reorder(clip id: UUID, pointer t: Double) {
        guard let loc = locate(clip: id) else { return }
        let c = tracks[loc.track].clips[loc.index]
        let others = tracks[loc.track].clips.filter { $0.id != id }
        guard let target = insertionPoint(track: loc.track, excluding: id, pointer: t), !others.isEmpty else { return }
        moveRange(from: c.start, to: c.end, insertAt: target)
    }

    /// 포인터 아래 클립의 앞/뒤 경계 (앞쪽 절반이면 앞, 뒤쪽 절반이면 뒤)
    func insertionPoint(track ti: Int, excluding id: UUID, pointer t: Double) -> Double? {
        let others = tracks[ti].clips.filter { $0.id != id }
        if let under = others.first(where: { t >= $0.start && t < $0.end }) {
            return t < (under.start + under.end) / 2 ? under.start : under.end
        }
        var bounds: [Double] = [0]
        for o in others { bounds += [o.start, o.end] }
        return bounds.min { abs($0 - t) < abs($1 - t) }
    }

    // MARK: 이동 / 트림

    // MARK: 그룹 · 합치기

    /// 선택한 클립에 같은 그룹을 달아 함께 선택·이동되게 한다 (2개 이상)
    @discardableResult
    mutating func group(_ ids: Set<UUID>) -> Bool {
        let all = groupMembers(of: ids)
        guard all.count >= 2 else { return false }
        let gid = UUID()
        for ti in tracks.indices {
            for ci in tracks[ti].clips.indices where all.contains(tracks[ti].clips[ci].id) { tracks[ti].clips[ci].groupID = gid }
        }
        return true
    }

    mutating func ungroup(_ ids: Set<UUID>) {
        let all = groupMembers(of: ids)
        for ti in tracks.indices {
            for ci in tracks[ti].clips.indices where all.contains(tracks[ti].clips[ci].id) { tracks[ti].clips[ci].groupID = nil }
        }
    }

    /// 선택에 그룹 동료를 더한 집합
    func groupMembers(of ids: Set<UUID>) -> Set<UUID> {
        let all = tracks.flatMap(\.clips)
        let groups = Set(all.filter { ids.contains($0.id) }.compactMap(\.groupID))
        guard !groups.isEmpty else { return ids }
        return ids.union(all.filter { $0.groupID.map(groups.contains) == true }.map(\.id))
    }

    /// 선택한 클립을 트랙별로 하나로 합친다.
    /// 원래 한 클립이던 조각(같은 원본·같은 속도·원본 구간이 이어짐)은 한 클립으로 되돌리고,
    /// 그렇지 않은 클립은 빈틈 없이 붙인 뒤 그룹으로 묶는다. 사이에 선택 안 한 클립이 있으면 거기서 끊는다.
    @discardableResult
    mutating func join(_ ids: Set<UUID>) -> (merged: Int, grouped: Int) {
        var merged = 0, grouped = 0
        for ti in tracks.indices {
            var clips = tracks[ti].clips.sorted { $0.start < $1.start }
            var i = 0
            var chains: [[UUID]] = []
            var chain: [UUID] = []
            while i < clips.count {
                guard ids.contains(clips[i].id) else {
                    if chain.count > 1 { chains.append(chain) }
                    chain = []
                    i += 1
                    continue
                }
                if chain.isEmpty { chain = [clips[i].id]; i += 1; continue }
                let p = i - 1
                // 빈틈 메우기 (선택한 클립만 왼쪽으로)
                let gap = clips[i].start - clips[p].end
                if gap > Project.eps { clips[i].start = clips[p].end }
                let a = clips[p], b = clips[i]
                let same = a.kind == .media && b.kind == .media && a.assetID != nil && a.assetID == b.assetID
                    && abs(a.speed - b.speed) < 0.0001 && abs(a.sourceOut - b.sourceIn) < 0.002
                    && abs(a.volume - b.volume) < 0.0001 && abs(a.opacity - b.opacity) < 0.0001
                    && abs(a.scale - b.scale) < 0.0001 && abs(a.offsetX - b.offsetX) < 0.0001 && abs(a.offsetY - b.offsetY) < 0.0001
                if same {
                    clips[p].sourceOut = b.sourceOut
                    clips[p].fadeOut = b.fadeOut
                    // 가리기 영역은 원본 시간 기준이라 그대로 합친다
                    let blurs = (a.blurs ?? []) + (b.blurs ?? []).filter { r in !(a.blurs ?? []).contains { $0.id == r.id } }
                    clips[p].blurs = blurs.isEmpty ? nil : blurs
                    clips.remove(at: i)
                    merged += 1
                } else {
                    chain.append(b.id)
                    i += 1
                }
            }
            if chain.count > 1 { chains.append(chain) }
            tracks[ti].clips = clips
            for c in chains {
                let gid = UUID()
                for ci in tracks[ti].clips.indices where c.contains(tracks[ti].clips[ci].id) { tracks[ti].clips[ci].groupID = gid }
                grouped += c.count
            }
        }
        return (merged, grouped)
    }

    mutating func move(clip id: UUID, toTrack newTrack: Int, start: Double) {
        guard let loc = locate(clip: id) else { return }
        var c = tracks[loc.track].clips.remove(at: loc.index)
        c.start = max(0, start)
        let ti = max(0, newTrack)
        while tracks.count <= ti { tracks.append(Track(name: "트랙 \(tracks.count + 1)")) }
        tracks[ti].clips.append(c)
        resolveOverlaps(track: ti, pinned: c.id)
    }

    /// 왼쪽 가장자리를 새 타임라인 위치로 트림.
    mutating func trimStart(clip id: UUID, to newStart: Double, maxSource: Double?) {
        guard let loc = locate(clip: id) else { return }
        var c = tracks[loc.track].clips[loc.index]
        let prevEnd = tracks[loc.track].clips.filter { $0.id != id && $0.end <= c.start + Project.eps }.map(\.end).max() ?? 0
        var s = min(max(newStart, prevEnd), c.end - Project.minClipDuration)
        if c.kind == .media, maxSource != nil {
            // 원본 시작보다 앞으로 늘릴 수 없다
            let earliest = c.start - c.sourceIn / c.speed
            s = max(s, earliest)
            c.sourceIn = c.sourceTime(atTimeline: s)
            c.start = s
        } else {
            let end = c.end
            c.start = s
            c.sourceIn = 0
            c.sourceOut = end - s
        }
        tracks[loc.track].clips[loc.index] = c
    }

    /// 오른쪽 가장자리를 새 타임라인 위치로 트림.
    mutating func trimEnd(clip id: UUID, to newEnd: Double, maxSource: Double?) {
        guard let loc = locate(clip: id) else { return }
        var c = tracks[loc.track].clips[loc.index]
        let nextStart = tracks[loc.track].clips.filter { $0.id != id && $0.start >= c.end - Project.eps }.map(\.start).min() ?? .infinity
        var e = max(min(newEnd, nextStart), c.start + Project.minClipDuration)
        if let maxSource {
            e = min(e, c.timelineTime(atSource: maxSource))
        }
        c.sourceOut = c.sourceTime(atTimeline: e)
        tracks[loc.track].clips[loc.index] = c
    }

    // MARK: 경계 조정 · 잘린 구간 복원

    /// t 이후에 시작하는 모든 클립(except 제외)과 자막을 d초 뒤로 민다
    mutating func rippleShift(from t: Double, by d: Double, except: UUID?) {
        guard abs(d) > 1e-9 else { return }
        for ti in tracks.indices {
            for ci in tracks[ti].clips.indices where tracks[ti].clips[ci].id != except && tracks[ti].clips[ci].start >= t - Project.eps {
                tracks[ti].clips[ci].start += d
            }
        }
        for i in captions.indices where captions[i].start >= t - Project.eps {
            captions[i].start += d
            captions[i].end += d
        }
    }

    /// 클립 가장자리를 원본 기준 seconds만큼 늘리거나(+) 줄인다(−). 뒤의 영상·자막은 함께 밀리거나 당겨진다.
    /// 돌려주는 값: 실제로 바뀐 원본 초 (원본 처음/끝, 최소 길이에서 멈춘다)
    @discardableResult
    mutating func adjustEdge(clip id: UUID, end atEnd: Bool, seconds: Double, sourceDuration: Double) -> Double {
        guard let loc = locate(clip: id) else { return 0 }
        let c = tracks[loc.track].clips[loc.index]
        guard c.kind == .media else { return 0 }
        if seconds >= 0 {
            let x = atEnd ? min(seconds, max(0, sourceDuration - c.sourceOut)) : min(seconds, max(0, c.sourceIn))
            guard x > 1e-6 else { return 0 }
            let t = atEnd ? c.end : c.start
            if atEnd { tracks[loc.track].clips[loc.index].sourceOut += x } else { tracks[loc.track].clips[loc.index].sourceIn -= x }
            rippleShift(from: t, by: x / c.speed, except: id)
            return x
        }
        // 줄이기: 이 클립만 줄이고, 클립 끝 뒤에 시작하는 것만 당긴다 (다른 트랙의 배경음악 등은 자르지 않는다)
        let x = min(-seconds, max(0, (c.sourceOut - c.sourceIn) - Project.minClipDuration * c.speed))
        guard x > 1e-6 else { return 0 }
        if atEnd { tracks[loc.track].clips[loc.index].sourceOut -= x } else { tracks[loc.track].clips[loc.index].sourceIn += x }
        rippleShift(from: c.end, by: -x / c.speed, except: id)
        for ti in tracks.indices { resolveOverlaps(track: ti) }
        return -x
    }

    /// 같은 원본을 잘라 이어 붙인 경계 (앞 클립, 뒤 클립, 잘린 원본 구간)
    struct CutPoint {
        var left: UUID
        var right: UUID
        var track: Int
        var time: Double
        var gap: ClosedRange<Double>
    }

    func cutPoints(track only: Int? = nil) -> [CutPoint] {
        var out: [CutPoint] = []
        for (ti, t) in tracks.enumerated() where only == nil || only == ti {
            let clips = t.clips.sorted { $0.start < $1.start }
            for i in clips.indices.dropFirst() {
                let a = clips[i - 1], b = clips[i]
                guard a.kind == .media, b.kind == .media, a.assetID != nil, a.assetID == b.assetID,
                      abs(a.end - b.start) < 0.01, abs(a.speed - b.speed) < 0.0001, b.sourceIn > a.sourceOut + 0.001 else { continue }
                out.append(CutPoint(left: a.id, right: b.id, track: ti, time: b.start, gap: a.sourceOut...b.sourceIn))
            }
        }
        return out.sorted { $0.time < $1.time }
    }

    /// 잘린 경계에서 원본을 되살린다. before = 앞 클립 끝을 늘릴 원본 초, after = 뒤 클립 시작을 당길 원본 초.
    /// 둘 다 nil이면 잘린 구간 전체를 되살리고 두 클립을 하나로 합친다. 돌려주는 값: 되살린 원본 구간
    @discardableResult
    mutating func restoreCut(_ cp: CutPoint, before: Double?, after: Double?) -> [ClosedRange<Double>] {
        let gap = cp.gap.upperBound - cp.gap.lowerBound
        var b = before ?? (after == nil ? gap : 0)
        var a = after ?? 0
        b = min(max(0, b), gap)
        a = min(max(0, a), gap - b)
        var out: [ClosedRange<Double>] = []
        if b > 1e-6 {
            adjustEdge(clip: cp.left, end: true, seconds: b, sourceDuration: .infinity)
            out.append(cp.gap.lowerBound...(cp.gap.lowerBound + b))
        }
        if a > 1e-6 {
            adjustEdge(clip: cp.right, end: false, seconds: a, sourceDuration: .infinity)
            out.append((cp.gap.upperBound - a)...cp.gap.upperBound)
        }
        // 빈틈 없이 이어지면 한 클립으로
        if let la = locate(clip: cp.left), let lb = locate(clip: cp.right), la.track == lb.track {
            let l = tracks[la.track].clips[la.index], r = tracks[lb.track].clips[lb.index]
            let alike = l.volume == r.volume && l.opacity == r.opacity && l.scale == r.scale && l.offsetX == r.offsetX && l.offsetY == r.offsetY
                && l.shape == r.shape && l.backgroundEffect == r.backgroundEffect && l.showClicks == r.showClicks
            if alike, abs(r.sourceIn - l.sourceOut) < 0.0005, abs(l.end - r.start) < 0.01 {
                var m = l
                m.sourceOut = r.sourceOut
                m.fadeOut = r.fadeOut
                let blurs = (l.blurs ?? []) + (r.blurs ?? []).filter { x in !(l.blurs ?? []).contains { $0.id == x.id } }
                m.blurs = blurs.isEmpty ? nil : blurs
                tracks[la.track].clips[la.index] = m
                tracks[lb.track].clips.removeAll { $0.id == cp.right }
            }
        }
        return out
    }


    mutating func setSpeed(clip id: UUID, _ speed: Double) {
        guard let loc = locate(clip: id) else { return }
        let old = tracks[loc.track].clips[loc.index]
        let s = min(max(speed, 0.1), 20)
        var c = old
        c.speed = s
        let delta = c.end - old.end
        tracks[loc.track].clips[loc.index] = c
        for ci in tracks[loc.track].clips.indices where tracks[loc.track].clips[ci].id != id && tracks[loc.track].clips[ci].start >= old.end - Project.eps {
            tracks[loc.track].clips[ci].start += delta
        }
        resolveOverlaps(track: loc.track, pinned: id)
    }

    /// 시간 t에 있는 클립 경계 목록 (편집 지점 이동용)
    var editPoints: [Double] {
        var pts = Set<Double>([0])
        for c in tracks.flatMap(\.clips) { pts.insert(c.start); pts.insert(c.end) }
        return pts.sorted()
    }
}
