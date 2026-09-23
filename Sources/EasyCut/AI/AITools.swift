import Foundation
import AppKit

/// AI(앱 내 Claude 대화, 외부 Claude MCP)가 호출하는 편집 도구 모음.
/// 모든 변경은 EditorStore.apply를 거치므로 ⌘Z로 되돌릴 수 있다.
enum AITools {
    static func tool(_ name: String, _ desc: String, _ props: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["name": name, "description": desc,
         "input_schema": ["type": "object", "properties": props, "required": required] as [String: Any]]
    }

    static let num: [String: Any] = ["type": "number"]
    static func num(_ d: String) -> [String: Any] { ["type": "number", "description": d] }
    static func str(_ d: String) -> [String: Any] { ["type": "string", "description": d] }
    static let rangeArray: [String: Any] = [
        "type": "array",
        "items": ["type": "object", "properties": ["start": num, "end": num], "required": ["start", "end"]] as [String: Any],
    ]

    static let definitions: [[String: Any]] = [
        tool("get_project_state", "현재 프로젝트 상태: 전체 길이, 재생헤드, 캔버스, 트랙별 클립(id, 종류, 이름, 시작/끝, 속도, 볼륨), 자막 목록 일부, 대본 유무, 선택 항목. 편집 전에 먼저 호출해 구조를 파악한다."),
        tool("get_transcript", "타임라인 순서의 대본 단어 목록. 각 줄은 '[단어번호] 시작-끝 단어' (초, 타임라인 기준). 범위를 주면 그 구간만.",
             ["from": num("시작 시간(초), 선택"), "to": num("끝 시간(초), 선택")]),
        tool("delete_words", "대본 단어 번호 구간을 삭제한다. 해당 말이 영상·오디오·자막에서 함께 잘리고 뒤가 당겨진다. 번호는 get_transcript 기준이며 삭제 후 번호가 바뀌므로 여러 구간은 한 번에 보낸다.",
             ["ranges": ["type": "array", "description": "삭제할 단어 번호 구간 목록 (from~to 포함)",
                         "items": ["type": "object", "properties": ["from": ["type": "integer"], "to": ["type": "integer"]], "required": ["from", "to"]] as [String: Any]] as [String: Any]],
             required: ["ranges"]),
        tool("delete_time_ranges", "타임라인 시간 구간(초)을 모든 트랙과 자막에서 잘라내고 뒤를 당긴다(리플 삭제).", ["ranges": rangeArray], required: ["ranges"]),
        tool("remove_silences", "말이 없는 구간을 찾아 모두 잘라낸다. 기본은 소리 크기(파형) 기준이라 음성 인식이 없어도 된다.",
             ["min_gap": num("이보다 긴 무음만 삭제 (초, 기본 0.6)"), "keep": num("앞뒤에 남길 여유 (초, 기본 0.12)"),
              "method": ["type": "string", "enum": ["audio", "transcript"], "description": "audio=소리 크기 기준(기본), transcript=대본 단어 사이 공백 기준"] as [String: Any],
              "threshold_db": num("audio 방식의 무음 기준 음량 dBFS (생략하면 자동)")]),
        tool("remove_fillers", "'음', '어', '그' 같은 군더더기 말을 모두 잘라낸다."),
        tool("split_at", "지정 시간에서 모든 트랙의 클립을 나눈다.", ["time": num("초")], required: ["time"]),
        tool("set_speed", "구간 또는 클립의 재생 속도를 바꾼다(0.1~20배). 구간을 주면 그 경계에서 나눈 뒤 구간 안 영상/오디오 클립에 적용한다.",
             ["speed": num("배속 0.1~20"), "start": num("구간 시작(초), 선택"), "end": num("구간 끝(초), 선택"),
              "clip_ids": ["type": "array", "items": ["type": "string"], "description": "대상 클립 id, 선택"] as [String: Any]],
             required: ["speed"]),
        tool("set_clip_properties", "클립 속성 변경: 볼륨(0~2), 불투명도(0~1), 크기(배율), 위치(offset_x/y: 캔버스 대비 -1~1), 페이드 인/아웃(초), 텍스트 클립의 글자.",
             ["clip_id": str("클립 id"), "volume": num, "opacity": num, "scale": num, "offset_x": num, "offset_y": num,
              "fade_in": num, "fade_out": num, "text": str("텍스트 클립 내용")],
             required: ["clip_id"]),
        tool("delete_clips", "클립 삭제. ripple=true면 같은 트랙 뒤 클립을 당긴다.",
             ["clip_ids": ["type": "array", "items": ["type": "string"]] as [String: Any], "ripple": ["type": "boolean"]],
             required: ["clip_ids"]),
        tool("move_clip", "클립을 다른 시간/트랙으로 옮긴다. 트랙 번호는 0이 맨 아래(기본).",
             ["clip_id": str("클립 id"), "start": num("새 시작 시간(초)"), "track": ["type": "integer"]], required: ["clip_id", "start"]),
        tool("add_text", "화면에 제목/텍스트를 추가한다.",
             ["text": str("내용"), "start": num("시작(초)"), "duration": num("길이(초, 기본 4)"),
              "position_y": num("세로 위치 0(위)~1(아래), 기본 0.5"), "font_size": num("1080p 기준 글자 크기, 기본 96"),
              "color": str("글자색 #RRGGBB")],
             required: ["text", "start"]),
        tool("generate_captions", "대본으로 자막을 새로 만든다(기존 자막 대체).", ["max_chars": ["type": "integer", "description": "자막 한 줄 최대 글자 수 (기본 20)"]]),
        tool("edit_captions", "자막 추가/수정/삭제. 번호는 get_project_state의 자막 번호.",
             ["add": ["type": "array", "items": ["type": "object", "properties": ["start": num, "end": num, "text": ["type": "string"]], "required": ["start", "end", "text"]] as [String: Any]] as [String: Any],
              "update": ["type": "array", "items": ["type": "object", "properties": ["index": ["type": "integer"], "text": ["type": "string"], "start": num, "end": num], "required": ["index"]] as [String: Any]] as [String: Any],
              "delete": ["type": "array", "items": ["type": "integer"]] as [String: Any]]),
        tool("cut_captions", "자막 번호들을 자막과 그 말이 나오는 영상 구간째 삭제한다(Vrew 방식).",
             ["indices": ["type": "array", "items": ["type": "integer"]] as [String: Any]], required: ["indices"]),
        tool("move_caption", "자막 한 줄을 그 영상 구간째 다른 자막 앞으로 옮겨 순서를 바꾼다. to_index가 자막 개수면 맨 끝으로.",
             ["index": ["type": "integer"], "to_index": ["type": "integer"]], required: ["index", "to_index"]),
        tool("set_caption_style", "전체 자막 스타일 변경.",
             ["font_size": num("1080p 기준 글자 크기"), "text_color": str("#RRGGBB"), "background_color": str("#RRGGBB"),
              "background_opacity": num("0~1 (0이면 배경 없음)"), "outline": ["type": "boolean"], "outline_color": str("외곽선 색 #RRGGBB"),
              "bold": ["type": "boolean"], "font_name": str("글꼴 PostScript 이름 (예: AppleSDGothicNeo-Bold), 빈 문자열이면 기본"),
              "position_y": num("0(위)~1(아래)"), "visible": ["type": "boolean", "description": "자막 표시 여부"]]),
        tool("set_canvas", "화면 크기/비율 변경.", ["width": num, "height": num], required: ["width", "height"]),
        tool("set_playhead", "재생헤드를 옮긴다.", ["time": num("초")], required: ["time"]),
        tool("set_playback_speed", "미리보기 재생 속도(0.25~20배)를 바꾸고 선택적으로 재생한다.",
             ["speed": num, "play": ["type": "boolean"]], required: ["speed"]),
        tool("import_url", "유튜브 등 영상 링크를 내려받아 프로젝트에 가져온다(빈 타임라인이면 바로 배치). 사용자가 권한이 있는 영상만.",
             ["url": str("영상 페이지 주소"), "quality": ["type": "string", "enum": ["720p", "1080p", "best", "audio"]] as [String: Any],
              "start": num("일부만 받을 때 시작(초)"), "end": num("일부만 받을 때 끝(초)")],
             required: ["url"]),
        tool("transcribe", "타임라인 영상/오디오의 음성 인식(STT)을 시작한다. 끝나면 대본과 자막이 생긴다(수 초~수 분)."),
        tool("undo", "마지막 편집을 되돌린다.", ["steps": ["type": "integer", "description": "되돌릴 횟수 (기본 1)"]]),
    ]

    static var toolNames: [String] { definitions.compactMap { $0["name"] as? String } }

    // MARK: 실행

    @MainActor
    static func execute(_ name: String, _ input: [String: Any], store: EditorStore) async -> (String, Bool) {
        func d(_ k: String) -> Double? { (input[k] as? NSNumber)?.doubleValue }
        func i(_ k: String) -> Int? { (input[k] as? NSNumber)?.intValue }
        func b(_ k: String) -> Bool? { (input[k] as? NSNumber)?.boolValue }
        func s(_ k: String) -> String? { input[k] as? String }
        let before = store.project.duration

        func changed(_ msg: String) -> (String, Bool) {
            (msg + String(format: " (길이 %.2f초 → %.2f초)", before, store.project.duration), false)
        }

        switch name {
        case "get_project_state":
            return (projectState(store), false)

        case "get_transcript":
            let words = store.project.timelineWords()
            if words.isEmpty { return ("대본이 없습니다. transcribe 도구로 음성 인식을 먼저 실행하세요.", false) }
            let from = d("from") ?? 0, to = d("to") ?? .infinity
            var lines: [String] = []
            for (n, w) in words.enumerated() where w.end > from && w.start < to {
                lines.append(String(format: "[%d] %.2f-%.2f %@", n, w.start, w.end, w.word.text))
            }
            if lines.count > 4000 { lines = Array(lines.prefix(4000)) + ["… (이후 생략, from/to로 범위를 좁히세요)"] }
            return (lines.joined(separator: "\n"), false)

        case "delete_words":
            let words = store.project.timelineWords()
            guard let arr = input["ranges"] as? [[String: Any]], !arr.isEmpty else { return ("ranges가 필요합니다", true) }
            var ids = Set<String>()
            for r in arr {
                guard let f = (r["from"] as? NSNumber)?.intValue, let t = (r["to"] as? NSNumber)?.intValue else { continue }
                let lo = max(0, min(f, t)), hi = min(words.count - 1, max(f, t))
                guard lo <= hi else { continue }
                for n in lo...hi { ids.insert(words[n].id) }
            }
            guard !ids.isEmpty else { return ("유효한 단어 번호가 없습니다 (0~\(words.count - 1))", true) }
            store.deleteWords(ids)
            return changed("\(ids.count)개 단어 삭제")

        case "delete_time_ranges":
            let ranges = parseRanges(input["ranges"])
            guard !ranges.isEmpty else { return ("ranges가 필요합니다", true) }
            store.apply { $0.rippleDelete(ranges: ranges) }
            return changed("\(ranges.count)개 구간 삭제")

        case "remove_silences":
            let gap = d("min_gap") ?? 0.6, keep = d("keep") ?? 0.12
            let ranges: [ClosedRange<Double>]
            if s("method") == "transcript" {
                ranges = store.project.silenceRanges(minGap: gap, keep: keep)
            } else {
                guard await store.ensureLoudness() else { return ("오디오 분석 실패", true) }
                let th = d("threshold_db") ?? store.autoSilenceThreshold()
                ranges = store.audioSilenceRanges(SilenceSettings(threshold: th, minSilence: gap, padding: keep))
            }
            store.applyCut(ranges, label: "무음")
            return changed("무음 \(ranges.count)곳 삭제")

        case "remove_fillers":
            let n = store.project.fillerWordIDs().count
            store.removeFillers()
            return changed("군더더기 \(n)개 삭제")

        case "split_at":
            guard let t = d("time") else { return ("time이 필요합니다", true) }
            store.apply { $0.splitAll(at: t) }
            return ("\(TimeFormat.clock(t))에서 분할", false)

        case "set_speed":
            guard let sp = d("speed") else { return ("speed가 필요합니다", true) }
            let speed = min(20, max(0.1, sp))
            if let ids = input["clip_ids"] as? [String], !ids.isEmpty {
                let set = Set(ids.compactMap { findClip($0, store.project) })
                guard !set.isEmpty else { return ("클립을 찾지 못했습니다", true) }
                store.setSpeed(speed, for: set)
                return changed("\(set.count)개 클립 \(speed)배속")
            }
            let a = d("start") ?? 0, e = d("end") ?? store.project.duration
            store.apply { p in
                p.splitAll(at: a)
                p.splitAll(at: e)
                // 뒤쪽 클립부터 바꿔야 앞쪽 변경으로 위치가 밀려도 대상이 흔들리지 않는다
                let targets = p.tracks.flatMap(\.clips)
                    .filter { $0.kind == .media && $0.start >= a - 0.01 && $0.end <= e + 0.01 && p.asset($0.assetID)?.kind != .image }
                    .sorted { $0.start > $1.start }
                for c in targets { p.setSpeed(clip: c.id, speed) }
            }
            return changed(String(format: "%.2f~%.2f초 구간 %g배속", a, e, speed))

        case "set_clip_properties":
            guard let cid = s("clip_id").flatMap({ findClip($0, store.project) }) else { return ("클립을 찾지 못했습니다", true) }
            store.apply { p in
                guard let loc = p.locate(clip: cid) else { return }
                var c = p.tracks[loc.track].clips[loc.index]
                if let v = d("volume") { c.volume = min(4, max(0, v)) }
                if let v = d("opacity") { c.opacity = min(1, max(0, v)) }
                if let v = d("scale") { c.scale = min(8, max(0.05, v)) }
                if let v = d("offset_x") { c.offsetX = v }
                if let v = d("offset_y") { c.offsetY = v }
                if let v = d("fade_in") { c.fadeIn = max(0, v) }
                if let v = d("fade_out") { c.fadeOut = max(0, v) }
                if let v = s("text"), c.kind == .text { c.text = v }
                p.tracks[loc.track].clips[loc.index] = c
            }
            return ("클립 속성 변경", false)

        case "delete_clips":
            let ids = Set((input["clip_ids"] as? [String] ?? []).compactMap { findClip($0, store.project) })
            guard !ids.isEmpty else { return ("클립을 찾지 못했습니다", true) }
            store.apply { $0.delete(clips: ids, ripple: b("ripple") ?? false) }
            return changed("\(ids.count)개 클립 삭제")

        case "move_clip":
            guard let cid = s("clip_id").flatMap({ findClip($0, store.project) }), let st = d("start"),
                  let loc = store.project.locate(clip: cid) else { return ("클립을 찾지 못했습니다", true) }
            store.apply { $0.move(clip: cid, toTrack: i("track") ?? loc.track, start: st) }
            return ("클립 이동", false)

        case "add_text":
            guard let text = s("text"), let st = d("start") else { return ("text, start가 필요합니다", true) }
            store.apply { p in
                let ti = max(1, p.tracks.count - 1)
                let id = p.insertText(text, track: ti, at: st, duration: d("duration") ?? 4)
                if let loc = p.locate(clip: id) {
                    if let y = d("position_y") { p.tracks[loc.track].clips[loc.index].textStyle.positionY = y }
                    if let f = d("font_size") { p.tracks[loc.track].clips[loc.index].textStyle.fontSize = f }
                    if let c = s("color").flatMap(hexColor) { p.tracks[loc.track].clips[loc.index].textStyle.textColor = c }
                }
            }
            return ("텍스트 추가: \(text)", false)

        case "generate_captions":
            let caps = store.project.generatedCaptions(maxChars: i("max_chars") ?? 20)
            guard !caps.isEmpty else { return ("대본이 없어 자막을 만들 수 없습니다", true) }
            store.apply { $0.captions = caps; $0.showCaptions = true }
            return ("자막 \(caps.count)개 생성", false)

        case "edit_captions":
            var added = 0, updated = 0, deleted = 0
            store.apply { p in
                let snapshot = p.captions
                var removeIDs = Set<UUID>()
                for n in (input["delete"] as? [NSNumber] ?? []).map(\.intValue) where snapshot.indices.contains(n) {
                    removeIDs.insert(snapshot[n].id); deleted += 1
                }
                for u in input["update"] as? [[String: Any]] ?? [] {
                    guard let n = (u["index"] as? NSNumber)?.intValue, snapshot.indices.contains(n),
                          let k = p.captions.firstIndex(where: { $0.id == snapshot[n].id }) else { continue }
                    if let t = u["text"] as? String { p.captions[k].text = t }
                    if let v = (u["start"] as? NSNumber)?.doubleValue { p.captions[k].start = v }
                    if let v = (u["end"] as? NSNumber)?.doubleValue { p.captions[k].end = v }
                    updated += 1
                }
                p.captions.removeAll { removeIDs.contains($0.id) }
                for a in input["add"] as? [[String: Any]] ?? [] {
                    guard let st = (a["start"] as? NSNumber)?.doubleValue, let en = (a["end"] as? NSNumber)?.doubleValue,
                          let t = a["text"] as? String else { continue }
                    p.captions.append(Caption(start: st, end: max(en, st + 0.2), text: t)); added += 1
                }
            }
            return ("자막 추가 \(added) · 수정 \(updated) · 삭제 \(deleted)", false)

        case "cut_captions":
            let sorted = store.project.captions.sorted { $0.start < $1.start }
            let ids = Set((input["indices"] as? [NSNumber] ?? []).map(\.intValue).filter { sorted.indices.contains($0) }.map { sorted[$0].id })
            guard !ids.isEmpty else { return ("유효한 자막 번호가 없습니다", true) }
            store.deleteCaptions(ids, withVideo: true)
            return changed("자막 \(ids.count)개와 영상 구간 삭제")

        case "move_caption":
            guard let from = i("index"), let to = i("to_index") else { return ("index, to_index가 필요합니다", true) }
            store.moveCaptions(from: IndexSet(integer: from), to: to)
            return ("자막 \(from)번을 \(to)번 자리로 옮김", false)

        case "set_caption_style":
            store.apply { p in
                if let v = d("font_size") { p.captionStyle.fontSize = v }
                if let c = s("text_color").flatMap(hexColor) { p.captionStyle.textColor = c }
                if let c = s("background_color").flatMap(hexColor) {
                    let a = p.captionStyle.backgroundColor.a
                    p.captionStyle.backgroundColor = RGBA(r: c.r, g: c.g, b: c.b, a: a > 0 ? a : 0.6)
                }
                if let v = d("background_opacity") { p.captionStyle.backgroundColor.a = min(1, max(0, v)) }
                if let v = b("outline") { p.captionStyle.outline = v }
                if let c = s("outline_color").flatMap(hexColor) { p.captionStyle.outlineColor = c; p.captionStyle.outline = true }
                if let v = s("font_name") { p.captionStyle.fontName = v }
                if let v = b("bold") { p.captionStyle.bold = v }
                if let v = d("position_y") { p.captionStyle.positionY = min(0.97, max(0.03, v)) }
                if let v = b("visible") { p.showCaptions = v }
            }
            return ("자막 스타일 변경", false)

        case "set_canvas":
            guard let w = d("width"), let h = d("height"), w >= 16, h >= 16 else { return ("width, height가 필요합니다", true) }
            store.apply { $0.canvasWidth = w.rounded(); $0.canvasHeight = h.rounded() }
            return ("화면 크기 \(Int(w))×\(Int(h))", false)

        case "set_playhead":
            guard let t = d("time") else { return ("time이 필요합니다", true) }
            store.seek(t)
            return ("재생헤드 \(TimeFormat.clock(t))", false)

        case "set_playback_speed":
            guard let sp = d("speed") else { return ("speed가 필요합니다", true) }
            store.player.setSpeed(sp)
            if b("play") == true { store.player.play() }
            return ("미리보기 \(TimelineNSView.speedLabel(store.player.speed)) 재생 속도", false)

        case "import_url":
            guard let u = s("url"), LinkImporter.isLink(u) else { return ("올바른 링크가 필요합니다", true) }
            var o = LinkImporter.Options()
            switch s("quality") { case "720p": o.quality = .p720; case "best": o.quality = .best; case "audio": o.quality = .audio; default: o.quality = .p1080 }
            o.start = d("start"); o.end = d("end")
            guard let file = await store.importLink(u, options: o) else { return ("가져오기 실패", true) }
            return changed("가져옴: \(file.lastPathComponent)")

        case "transcribe":
            let used = Set(store.project.tracks.flatMap(\.clips).compactMap(\.assetID))
            let targets = store.project.assets.filter { used.contains($0.id) && $0.hasAudio && $0.words == nil }
            guard !targets.isEmpty else { return ("인식할 새 미디어가 없습니다 (이미 대본이 있거나 오디오 없음)", false) }
            targets.forEach { store.transcribe($0.id) }
            // 끝날 때까지 기다린다 (최대 20분)
            for _ in 0..<2400 {
                if targets.allSatisfy({ store.transcribing[$0.id] == nil }) { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            return ("음성 인식 완료: 대본 단어 \(store.project.timelineWords().count)개", false)

        case "undo":
            let n = max(1, min(50, i("steps") ?? 1))
            for _ in 0..<n where store.canUndo { store.undo() }
            return changed("\(n)단계 되돌림")

        default:
            return ("알 수 없는 도구: \(name)", true)
        }
    }

    static func parseRanges(_ v: Any?) -> [ClosedRange<Double>] {
        (v as? [[String: Any]] ?? []).compactMap { r in
            guard let a = (r["start"] as? NSNumber)?.doubleValue, let b = (r["end"] as? NSNumber)?.doubleValue, abs(b - a) > 0.001 else { return nil }
            return min(a, b)...max(a, b)
        }
    }

    /// 전체 UUID 또는 앞 8자리로 클립 찾기
    static func findClip(_ key: String, _ p: Project) -> UUID? {
        let k = key.uppercased()
        return p.tracks.flatMap(\.clips).first { $0.id.uuidString == k || $0.id.uuidString.hasPrefix(k) }?.id
    }

    static func hexColor(_ s: String) -> RGBA? {
        var h = s.trimmingCharacters(in: .whitespaces).uppercased()
        if h.hasPrefix("#") { h.removeFirst() }
        let named: [String: String] = ["WHITE": "FFFFFF", "BLACK": "000000", "YELLOW": "FFD60A", "RED": "FF3B30", "BLUE": "0A84FF", "GREEN": "30D158"]
        if let n = named[h] { h = n }
        guard h.count == 6, let v = Int(h, radix: 16) else { return nil }
        return RGBA(r: Double((v >> 16) & 0xFF) / 255, g: Double((v >> 8) & 0xFF) / 255, b: Double(v & 0xFF) / 255, a: 1)
    }

    @MainActor
    static func projectState(_ store: EditorStore) -> String {
        let p = store.project
        var o: [String] = []
        o.append(String(format: "전체 길이 %.2f초, 재생헤드 %.2f초, 캔버스 %d×%d, %gfps", p.duration, store.time, Int(p.canvasWidth), Int(p.canvasHeight), p.fps))
        o.append("미디어: " + p.assets.map { "\($0.name)(\($0.kind.rawValue), \(String(format: "%.1f", $0.duration))초, 대본 \($0.words == nil ? "없음" : "\($0.words!.count)단어"))" }.joined(separator: ", "))
        for (ti, t) in p.tracks.enumerated() {
            o.append("트랙 \(ti)\(ti == 0 ? " (기본)" : "")\(t.muted ? " 음소거" : "")\(t.hidden ? " 숨김" : ""):")
            for c in t.clips {
                let label = c.kind == .text ? "텍스트 \"\(c.text)\"" : "\(p.asset(c.assetID)?.kind.rawValue ?? "?") \(p.asset(c.assetID)?.name ?? "")"
                o.append(String(format: "  - id %@ | %@ | %.2f~%.2f초 | 원본 %.2f~%.2f | %g배속 | 볼륨 %.0f%% | 크기 %.0f%%",
                                String(c.id.uuidString.prefix(8)), label, c.start, c.end, c.sourceIn, c.sourceOut, c.speed, c.volume * 100, c.scale * 100))
            }
        }
        o.append("자막 \(p.captions.count)개 (표시 \(p.showCaptions ? "켬" : "끔"), 크기 \(Int(p.captionStyle.fontSize)), 위치 \(String(format: "%.2f", p.captionStyle.positionY)))")
        for (n, c) in p.captions.prefix(60).enumerated() {
            o.append(String(format: "  [%d] %.2f~%.2f %@", n, c.start, c.end, c.text))
        }
        if p.captions.count > 60 { o.append("  … 이하 \(p.captions.count - 60)개 생략") }
        o.append("대본 단어 \(p.timelineWords().count)개")
        if !store.selection.isEmpty { o.append("선택된 클립: " + store.selection.map { String($0.uuidString.prefix(8)) }.joined(separator: ", ")) }
        if let r = store.markRange { o.append(String(format: "In/Out 구간: %.2f~%.2f", r.lowerBound, r.upperBound)) }
        return o.joined(separator: "\n")
    }
}
