import Foundation
import AppKit

/// 편집 결과를 검토하고 고치는 AI 도구: 전체 자막 읽기, 클립 경계·원본 연결 보기, 구간 소리 듣기, 경계 조정·잘린 말 되살리기.
extension AITools {
    static let reviewDefinitions: [[String: Any]] = [
        tool("get_captions", "자막 전체를 번호·시작~끝·내용으로 돌려준다(get_project_state는 처음 20개만 보여 준다). 길면 from/to(초)나 start_index로 나눠 읽는다. 번호는 edit_captions·cut_captions에 그대로 쓴다.",
             ["from": num("시작 시간(초), 선택"), "to": num("끝 시간(초), 선택"),
              "start_index": ["type": "integer", "description": "이 번호부터, 선택"], "limit": ["type": "integer", "description": "최대 개수 (기본 300)"]]),
        tool("get_clips", "구간 안 클립의 상세: 트랙, 타임라인 시작~끝, 원본 시작~끝, 속도, 그리고 같은 원본을 잘라 붙인 경계마다 잘린 원본 구간과 그 안에 있던 말, 경계에 걸쳐 일부만 남은 말. 말이 잘렸는지 볼 때 쓴다.",
             ["from": num("시작(초), 선택"), "to": num("끝(초), 선택"), "track": ["type": "integer", "description": "트랙 번호, 선택"]]),
        tool("listen_range", "타임라인 구간의 실제 소리를 확인한다: 원본 대본 단어를 남은 말/잘린 말/경계에 걸린 말로 표시하고, 클립 경계 앞뒤의 소리 크기로 말소리 중간에서 잘렸는지 알려 준다. recognize=true면 그 구간 원음을 Whisper로 다시 받아써 자막과 비교할 수 있다(수 초 걸림).",
             ["start": num("시작(초)"), "end": num("끝(초)"), "pad": num("클립 경계 바깥(잘린 쪽)으로 더 볼 원본 초 (기본 1.0)"),
              "recognize": ["type": "boolean", "description": "원음을 다시 받아쓰기 (기본 false)"]],
             required: ["start", "end"]),
        tool("adjust_clip_edge", "클립 가장자리를 원본 기준으로 늘리거나(seconds>0, 잘린 말 되살리기) 줄인다(seconds<0). 뒤의 영상·오디오·자막 시간도 함께 밀리거나 당겨진다.",
             ["clip_id": str("클립 id"), "edge": ["type": "string", "enum": ["start", "end"]] as [String: Any], "seconds": num("원본 초. +늘리기, -줄이기")],
             required: ["clip_id", "edge", "seconds"]),
        tool("restore_cut", "같은 원본을 잘라 붙인 경계에서 잘라낸 원본을 되살린다. before/after를 모두 생략하면 잘린 구간 전체를 되살려 두 클립을 합친다. before=앞 클립 끝을 늘릴 원본 초, after=뒤 클립 시작을 당길 원본 초. 뒤의 영상·자막도 함께 밀린다. 되살린 말에는 자막이 없으므로 필요하면 edit_captions로 추가한다.",
             ["time": num("경계 근처 타임라인 시간(초)"), "track": ["type": "integer", "description": "트랙 번호, 선택"],
              "before": num("앞 클립 끝을 늘릴 원본 초, 선택"), "after": num("뒤 클립 시작을 당길 원본 초, 선택")],
             required: ["time"]),
        tool("check_caption_sync", "자막 시작 시간과 실제 말소리가 시작되는 순간(소리 크기 기준)을 자막마다 비교해, 자막이 빠른지 늦은지와 그 차이가 일정한지 알려 준다. 미리보기 소리 출력 장치(블루투스 등)의 지연도 함께 알려 준다. 자막 시간을 고치기 전에 먼저 쓴다.",
             ["from": num("시작(초), 선택"), "to": num("끝(초), 선택")]),
        tool("align_captions", "check_caption_sync와 같은 측정으로 자막 시간을 실제 말소리에 맞춘다. mode=auto(기본): 차이가 일정하면 한꺼번에 옮기고 아니면 자막마다 맞춤. shift: seconds만큼(생략하면 측정한 중앙값) 한꺼번에 옮김. snap: 잴 수 있는 자막마다 말 시작에 맞춤.",
             ["mode": ["type": "string", "enum": ["auto", "shift", "snap"]] as [String: Any], "seconds": num("shift 때 옮길 초 (+늦추기, -앞당기기), 선택"),
              "from": num("시작(초), 선택"), "to": num("끝(초), 선택")]),
        tool("export_range", "타임라인 구간만 짧게 MP4로 내보내 기본 플레이어(QuickTime)로 연다. 미리보기에서만 어긋나는지, 내보낸 영상도 어긋나는지 사용자가 확인할 때 쓴다.",
             ["start": num("시작(초)"), "end": num("끝(초)"), "captions": ["type": "boolean", "description": "자막 굽기 (기본 true)"],
              "open": ["type": "boolean", "description": "내보낸 뒤 열기 (기본 true)"]],
             required: ["start", "end"]),
    ]

    @MainActor
    static func syncReport(_ store: EditorStore, from: Double, to: Double) async -> CaptionSyncReport {
        var loud: [UUID: [Float]] = [:], th: [UUID: Double] = [:]
        let used = Set(store.project.tracks.flatMap(\.clips).compactMap(\.assetID))
        for a in store.project.assets where used.contains(a.id) && a.hasAudio {
            if let db = await store.loudness(of: a) { loud[a.id] = db; th[a.id] = SilenceDetector.autoThreshold(db) }
        }
        return store.project.captionSync(loudness: loud, thresholds: th, from: from, to: to)
    }

    static func short(_ id: UUID) -> String { String(id.uuidString.prefix(8)) }

    /// 원본 구간 안의 단어 (가운데가 구간 안)
    static func words(_ a: MediaAsset?, _ r: ClosedRange<Double>) -> [Word] {
        (a?.words ?? []).filter { let m = ($0.start + $0.end) / 2; return m >= r.lowerBound && m < r.upperBound }
    }

    @MainActor
    static func executeReview(_ name: String, _ input: [String: Any], store: EditorStore) async -> (String, Bool)? {
        func d(_ k: String) -> Double? { (input[k] as? NSNumber)?.doubleValue }
        func i(_ k: String) -> Int? { (input[k] as? NSNumber)?.intValue }
        func b(_ k: String) -> Bool? { (input[k] as? NSNumber)?.boolValue }
        func s(_ k: String) -> String? { input[k] as? String }
        let p = store.project

        switch name {
        case "get_captions":
            let from = d("from") ?? 0, to = d("to") ?? .infinity
            let first = max(0, i("start_index") ?? 0), limit = max(1, i("limit") ?? 300)
            var o = ["자막 \(p.captions.count)개 (번호 시작~끝초 내용)"]
            var chars = 0, shown = 0
            for (n, c) in p.captions.enumerated() where n >= first && c.end > from && c.start < to {
                if shown >= limit || chars > 60_000 {
                    o.append("… 이어서 보려면 start_index=\(n)")
                    break
                }
                let line = String(format: "[%d] %.2f~%.2f %@", n, c.start, c.end, c.text)
                chars += line.count
                shown += 1
                o.append(line)
            }
            if shown == 0 { o.append("(이 범위에 자막이 없습니다)") }
            return (o.joined(separator: "\n"), false)

        case "get_clips":
            let from = d("from") ?? 0, to = d("to") ?? .infinity
            let cuts = p.cutPoints(track: i("track"))
            var o: [String] = []
            var chars = 0
            for (ti, t) in p.tracks.enumerated() where i("track") == nil || i("track") == ti {
                for c in t.clips where c.end > from && c.start < to {
                    let a = p.asset(c.assetID)
                    let label = c.kind == .text ? "텍스트 \"\(c.text)\"" : "\(a?.kind.rawValue ?? "?") \(a?.name ?? "")"
                    var line = String(format: "트랙 %d | id %@ | %@ | 타임라인 %.2f~%.2f | 원본 %.2f~%.2f | %g배속", ti, short(c.id), label, c.start, c.end, c.sourceIn, c.sourceOut, c.speed)
                    if c.kind == .media, let ws = a?.words {
                        // 경계에 걸쳐 일부만 남은 말
                        if let w = ws.first(where: { $0.start < c.sourceIn - 0.02 && $0.end > c.sourceIn + 0.02 }) {
                            line += String(format: "\n    시작 경계에 걸친 말 \"%@\" (원본 %.2f~%.2f, 앞 %.2f초 잘림)", w.text, w.start, w.end, c.sourceIn - w.start)
                        }
                        if let w = ws.first(where: { $0.start < c.sourceOut - 0.02 && $0.end > c.sourceOut + 0.02 }) {
                            line += String(format: "\n    끝 경계에 걸친 말 \"%@\" (원본 %.2f~%.2f, 뒤 %.2f초 잘림)", w.text, w.start, w.end, w.end - c.sourceOut)
                        }
                    }
                    if let cp = cuts.first(where: { $0.right == c.id }) {
                        let gone = words(a, cp.gap).map(\.text).joined(separator: " ")
                        line += String(format: "\n    ↑ 앞 클립과의 경계 %.2f초: 원본 %.2f~%.2f (%.2f초) 잘림%@", cp.time, cp.gap.lowerBound, cp.gap.upperBound,
                                       cp.gap.upperBound - cp.gap.lowerBound, gone.isEmpty ? " (말 없음)" : " — 잘린 말: \(gone)")
                    }
                    chars += line.count
                    if chars > 60_000 { o.append(String(format: "… 길어서 여기까지. 이어서 보려면 from=%.2f", c.start)); break }
                    o.append(line)
                }
            }
            if o.isEmpty { return ("이 범위에 클립이 없습니다", false) }
            return (o.joined(separator: "\n"), false)

        case "listen_range":
            guard let st = d("start"), let en = d("end"), en > st else { return ("start < end 가 필요합니다", true) }
            let pad = min(5, max(0, d("pad") ?? 1.0))
            let recognize = b("recognize") ?? false
            var o: [String] = []
            for (ti, t) in p.tracks.enumerated() where !t.muted {
                for c in t.clips where c.kind == .media && c.end > st && c.start < en {
                    guard let a = p.asset(c.assetID), a.hasAudio, c.volume > 0.001 else { continue }
                    let ta = max(st, c.start), tb = min(en, c.end)
                    let atStart = ta <= c.start + 0.001, atEnd = tb >= c.end - 0.001
                    let sa = c.sourceTime(atTimeline: ta), sb = c.sourceTime(atTimeline: tb)
                    let wa = atStart ? max(0, sa - pad) : sa, wb = atEnd ? min(a.duration, sb + pad) : sb
                    o.append(String(format: "■ 트랙 %d 클립 %@ (%@) 타임라인 %.2f~%.2f = 원본 %.2f~%.2f. 원본 %.2f~%.2f 구간 확인", ti, short(c.id), a.name, ta, tb, sa, sb, wa, wb))
                    func tag(_ w: Word) -> String {
                        if w.end <= c.sourceIn + 0.01 || w.start >= c.sourceOut - 0.01 {
                            return String(format: "✂ \"%@\" 잘림 (원본 %.2f~%.2f)", w.text, w.start, w.end)
                        }
                        if w.start < c.sourceIn - 0.02 || w.end > c.sourceOut + 0.02 {
                            return String(format: "◐ \"%@\" 일부 잘림 (원본 %.2f~%.2f, 남은 부분 타임라인 %.2f~%.2f)", w.text, w.start, w.end,
                                          c.timelineTime(atSource: max(w.start, c.sourceIn)), c.timelineTime(atSource: min(w.end, c.sourceOut)))
                        }
                        return String(format: "▶ \"%@\" %.2f~%.2f", w.text, c.timelineTime(atSource: w.start), c.timelineTime(atSource: w.end))
                    }
                    if a.words == nil {
                        o.append("  (대본 없음 — transcribe로 음성 인식을 먼저 하거나 recognize=true로 받아쓰기)")
                    } else {
                        let ws = (a.words ?? []).filter { $0.end > wa && $0.start < wb }
                        o.append("  대본 단어: " + (ws.isEmpty ? "(없음)" : ws.map(tag).joined(separator: " · ")))
                    }
                    // 경계 앞뒤 소리 크기
                    if let db = await store.loudness(of: a), !db.isEmpty {
                        let th = SilenceDetector.autoThreshold(db)
                        func level(_ x: Double, _ y: Double) -> Double {
                            let i0 = max(0, Int(x / SilenceDetector.hop)), i1 = min(db.count, Int(y / SilenceDetector.hop))
                            guard i1 > i0 else { return -100 }
                            return Double(db[i0..<i1].max() ?? -100)
                        }
                        func edge(_ name: String, _ s: Double, keptAfter: Bool) {
                            let cut = keptAfter ? level(s - 0.2, s) : level(s, s + 0.2)
                            let kept = keptAfter ? level(s, s + 0.2) : level(s - 0.2, s)
                            let speech = cut > th && kept > th
                            o.append(String(format: "  %@ 경계(원본 %.2f): 잘린 쪽 %.0fdB, 남은 쪽 %.0fdB (말소리 기준 %.0fdB) → %@", name, s, cut, kept, th,
                                            speech ? "말소리가 이어지는 중에 잘렸을 수 있음" : (cut > th ? "잘린 쪽에 소리가 있음" : "경계는 조용함")))
                        }
                        if atStart, c.sourceIn > 0.05 { edge("시작", c.sourceIn, keptAfter: true) }
                        if atEnd, c.sourceOut < a.duration - 0.05 { edge("끝", c.sourceOut, keptAfter: false) }
                    }
                    if recognize {
                        if !Transcriber.whisperReady {
                            o.append("  (Whisper가 준비되지 않아 받아쓰기를 못 했습니다)")
                        } else {
                            let lang = store.sttLanguage, model = store.whisperModel, url = a.url
                            do {
                                let heard = try await Task.detached {
                                    let pcm = try await Transcriber.pcm16k(url: url, range: wa...wb)
                                    return try await Transcriber.transcribeWhisper(samples: pcm, language: lang, model: model) { _, _ in }
                                }.value
                                let shifted = heard.map { Word(text: $0.text, start: $0.start + wa, end: $0.end + wa) }
                                o.append("  다시 받아쓴 원음: " + (shifted.isEmpty ? "(말소리 없음)" : shifted.map(tag).joined(separator: " · ")))
                            } catch {
                                o.append("  받아쓰기 실패: \(error.localizedDescription)")
                            }
                        }
                    }
                }
            }
            let caps = p.captions.enumerated().filter { $0.element.end > st && $0.element.start < en }
            o.append("이 구간 자막: " + (caps.isEmpty ? "(없음)" : caps.map { String(format: "[%d] %.2f~%.2f %@", $0.offset, $0.element.start, $0.element.end, $0.element.text) }.joined(separator: " / ")))
            if o.count == 1 { o.insert("이 구간에 소리가 있는 클립이 없습니다", at: 0) }
            return (o.joined(separator: "\n"), false)

        case "adjust_clip_edge":
            guard let cid = s("clip_id").flatMap({ findClip($0, p) }), let c = p.clip(cid), c.kind == .media,
                  let a = p.asset(c.assetID) else { return ("영상/오디오 클립을 찾지 못했습니다", true) }
            guard let sec = d("seconds"), abs(sec) > 0.0005 else { return ("seconds가 필요합니다", true) }
            if a.kind == .image { return ("사진 클립은 길이를 바꾸세요 (원본이 없습니다)", true) }
            let atEnd = s("edge") != "start"
            let before = p.duration
            var done = 0.0
            store.apply { done = $0.adjustEdge(clip: cid, end: atEnd, seconds: sec, sourceDuration: a.duration) }
            if abs(done) < 0.0005 { return ("더 늘리거나 줄일 수 없습니다 (원본 처음/끝 또는 최소 길이)", true) }
            let r = atEnd ? (done > 0 ? c.sourceOut...(c.sourceOut + done) : (c.sourceOut + done)...c.sourceOut)
                          : (done > 0 ? (c.sourceIn - done)...c.sourceIn : c.sourceIn...(c.sourceIn - done))
            let ws = words(a, r).map(\.text).joined(separator: " ")
            return (String(format: "%@ %@ 원본 %.2f초 %@ (원본 %.2f~%.2f%@). 길이 %.2f초 → %.2f초", atEnd ? "끝" : "시작", done > 0 ? "늘림" : "줄임", abs(done),
                           done > 0 ? "되살림" : "잘라냄", r.lowerBound, r.upperBound, ws.isEmpty ? "" : ", 말: \(ws)", before, store.project.duration), false)

        case "restore_cut":
            guard let t = d("time") else { return ("time이 필요합니다", true) }
            let cuts = p.cutPoints(track: i("track"))
            guard let cp = cuts.min(by: { abs($0.time - t) < abs($1.time - t) }), abs(cp.time - t) <= 1.5 else {
                return (String(format: "%.2f초 근처(±1.5초)에 같은 원본을 잘라 붙인 경계가 없습니다. get_clips로 경계를 확인하세요", t), true)
            }
            let a = p.asset(p.clip(cp.left)?.assetID)
            let before = p.duration
            var restored: [ClosedRange<Double>] = []
            store.apply { restored = $0.restoreCut(cp, before: d("before"), after: d("after")) }
            if restored.isEmpty { return ("되살릴 구간이 없습니다", true) }
            let ws = restored.flatMap { words(a, $0) }.map(\.text).joined(separator: " ")
            let rs = restored.map { String(format: "%.2f~%.2f", $0.lowerBound, $0.upperBound) }.joined(separator: ", ")
            return (String(format: "%.2f초 경계에서 원본 %@ 되살림%@. 길이 %.2f초 → %.2f초 (뒤 영상·자막도 밀림)", cp.time, rs,
                           ws.isEmpty ? " (말 없음)" : " — 되살린 말: \(ws) (이 말이 자막에 없으면 edit_captions로 추가)", before, store.project.duration), false)

        case "check_caption_sync":
            let from = d("from") ?? 0, to = d("to") ?? .infinity
            guard !p.captions.isEmpty else { return ("자막이 없습니다", true) }
            let r = await syncReport(store, from: from, to: to)
            var o: [String] = []
            if r.measures.isEmpty {
                o.append("잴 수 있는 자막이 없습니다 (자막 앞에 조용한 틈이 있어야 말 시작을 찾을 수 있습니다). 건너뜀 \(r.skipped)개")
            } else {
                let dir = r.median > 0 ? "빠름 (늦춰야 함)" : "늦음 (앞당겨야 함)"
                o.append(String(format: "자막 %d개를 잼 (건너뜀 %d개): 자막이 말보다 중앙값 %.2f초 %@, 편차 %.2f초 → %@", r.measures.count, r.skipped, abs(r.median), abs(r.median) < 0.03 ? "차이 없음" : dir, r.spread,
                                r.consistent ? (abs(r.median) < 0.05 ? "자막 시간은 맞습니다" : "차이가 일정하므로 align_captions mode=shift로 한꺼번에 옮기면 됩니다") : "구간마다 달라서 align_captions mode=snap으로 자막마다 맞추는 게 좋습니다"))
                for m in r.measures.prefix(60) {
                    o.append(String(format: "  [%d] 자막 %.2f / 말 시작 %.2f → %+.2f초", m.index, m.captionStart, m.onset, m.offset))
                }
                if r.measures.count > 60 { o.append("  … (\(r.measures.count - 60)개 더)") }
            }
            o.append(AudioOutput.summary())
            return (o.joined(separator: "\n"), false)

        case "align_captions":
            let from = d("from") ?? 0, to = d("to") ?? .infinity
            guard !p.captions.isEmpty else { return ("자막이 없습니다", true) }
            let r = await syncReport(store, from: from, to: to)
            var mode = s("mode") ?? "auto"
            if mode == "auto" { mode = r.consistent ? "shift" : "snap" }
            if mode == "shift" {
                guard let sec = d("seconds") ?? (r.measures.isEmpty ? nil : r.median), abs(sec) > 0.005 else {
                    return ("옮길 만큼의 차이가 없습니다 (잰 자막 \(r.measures.count)개)", false)
                }
                store.apply { $0.shiftCaptions(by: sec, from: from, to: to) }
                return (String(format: "자막을 %.2f초 %@ (%@)", abs(sec), sec > 0 ? "늦춤" : "앞당김", d("seconds") == nil ? "측정한 중앙값" : "지정한 값"), false)
            }
            guard !r.measures.isEmpty else { return ("잴 수 있는 자막이 없어 맞추지 못했습니다", true) }
            store.apply { $0.snapCaptions(r.measures) }
            return (String(format: "자막 %d개의 시작을 실제 말 시작에 맞춤 (평균 %+.2f초). 잴 수 없던 %d개는 그대로", r.measures.count,
                           r.measures.map(\.offset).reduce(0, +) / Double(r.measures.count), r.skipped), false)

        case "export_range":
            guard let st = d("start"), let en = d("end"), en - st > 0.1 else { return ("start < end 가 필요합니다", true) }
            var q = p
            let total = q.duration
            guard st < total else { return ("시작이 영상 길이보다 뒤입니다", true) }
            if st > 0 { q.rippleDelete(from: 0, to: st) }
            let len = min(en, total) - st
            if q.duration > len { q.rippleDelete(from: len, to: q.duration + 1) }
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/EasyCut 확인용", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let f = DateFormatter(); f.dateFormat = "HHmmss"
            let url = dir.appendingPathComponent(String(format: "구간 %.1f-%.1f초 %@.mp4", st, min(en, total), f.string(from: Date())))
            let scale = min(1, 1080 / max(1, min(q.canvasWidth, q.canvasHeight)))
            let size = CGSize(width: (q.canvasWidth * scale / 2).rounded() * 2, height: (q.canvasHeight * scale / 2).rounded() * 2)
            do {
                try await Exporter.export(project: q, format: .mp4H264, size: size, burnCaptions: b("captions") ?? true, to: url, cancel: Exporter.Box()) { _ in }
            } catch {
                return ("내보내기 실패: \(error.localizedDescription)", true)
            }
            if b("open") ?? true { NSWorkspace.shared.open(url) }
            return (String(format: "%.2f~%.2f초를 내보냄: %@%@", st, min(en, total), url.path, (b("open") ?? true) ? " (기본 플레이어로 열었습니다. 사용자에게 내보낸 영상에서도 자막이 어긋나는지 물어보세요)" : ""), false)

        default:
            return nil
        }
    }
}
