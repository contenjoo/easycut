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
    mutating func split(clip id: UUID, at t: Double) -> UUID? {
        guard let loc = locate(clip: id) else { return nil }
        let c = tracks[loc.track].clips[loc.index]
        guard t > c.start + Project.minClipDuration, t < c.end - Project.minClipDuration else { return nil }
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

    mutating func splitAll(at t: Double, tracks only: Set<Int>? = nil) {
        for ti in tracks.indices where only?.contains(ti) ?? true {
            for c in tracks[ti].clips where t > c.start && t < c.end {
                split(clip: c.id, at: t)
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
        splitAll(at: a)
        splitAll(at: b)
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

    // MARK: 이동 / 트림

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

    /// 속도 변경. 같은 트랙의 뒤 클립은 길이 변화만큼 당기거나 민다.
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
