//! AI(앱 안 대화, 외부 Claude/Codex의 MCP)가 호출하는 편집 도구. 맥 AITools.swift와 이름·입력이 같다.
//! 모든 변경은 Editor::apply를 거치므로 Ctrl+Z로 되돌릴 수 있다.
use crate::{emit_state, job, silence_blocking, transcribe_blocking, AppState};
use easycut_core::silence::SilenceSettings;
use easycut_core::timeline_ops::TimeRange;
use easycut_core::transcript_ops::{deletion_ranges, normalized};
use easycut_core::{Caption, ClipKind, Id, MediaKind, Project, Rgba};
use serde_json::{json, Value};
use std::collections::HashSet;
use tauri::{AppHandle, Emitter, Manager};

fn tool(name: &str, desc: &str, props: Value, required: &[&str]) -> Value {
    json!({ "name": name, "description": desc,
            "input_schema": { "type": "object", "properties": props, "required": required } })
}

fn num(d: &str) -> Value {
    json!({ "type": "number", "description": d })
}

fn string(d: &str) -> Value {
    json!({ "type": "string", "description": d })
}

pub fn definitions() -> Vec<Value> {
    let n = json!({ "type": "number" });
    let range_array = json!({ "type": "array", "items": { "type": "object", "properties": { "start": n, "end": n }, "required": ["start", "end"] } });
    vec![
        tool("get_project_state", "현재 프로젝트 상태: 전체 길이, 재생헤드, 캔버스, 트랙별 클립(id, 종류, 이름, 시작/끝, 속도, 볼륨), 자막 목록 일부, 대본 유무, 선택 항목. 편집 전에 먼저 호출해 구조를 파악한다.", json!({}), &[]),
        tool("get_transcript", "대본을 문장 단위로 돌려준다. 각 줄은 '[첫단어번호-끝단어번호] 시작~끝초 문장'. 길면 from/to(초)로 범위를 나눠 읽는다. 특정 말을 찾을 때는 search_transcript가 훨씬 빠르다.",
             json!({ "from": num("시작 시간(초), 선택"), "to": num("끝 시간(초), 선택") }), &[]),
        tool("search_transcript", "대본에서 문구를 찾아 해당 단어 번호 구간과 시간을 돌려준다(띄어쓰기 무시). 찾은 번호로 delete_words를 바로 쓸 수 있다.",
             json!({ "query": string("찾을 말"), "limit": { "type": "integer", "description": "최대 결과 수 (기본 30)" } }), &["query"]),
        tool("delete_words", "대본 단어 번호 구간을 삭제한다. 해당 말이 영상·오디오·자막에서 함께 잘리고 뒤가 당겨진다. 번호는 get_transcript 기준이며 삭제 후 번호가 바뀌므로 여러 구간은 한 번에 보낸다.",
             json!({ "ranges": { "type": "array", "description": "삭제할 단어 번호 구간 목록 (from~to 포함)",
                     "items": { "type": "object", "properties": { "from": { "type": "integer" }, "to": { "type": "integer" } }, "required": ["from", "to"] } } }), &["ranges"]),
        tool("delete_time_ranges", "타임라인 시간 구간(초)을 모든 트랙과 자막에서 잘라내고 뒤를 당긴다(리플 삭제).", json!({ "ranges": range_array }), &["ranges"]),
        tool("remove_silences", "말이 없는 구간을 찾아 모두 잘라낸다. 기본은 소리 크기(파형) 기준이라 음성 인식이 없어도 된다.",
             json!({ "min_gap": num("이보다 긴 무음만 삭제 (초, 기본 0.6)"), "keep": num("앞뒤에 남길 여유 (초, 기본 0.12)"),
                     "method": { "type": "string", "enum": ["audio", "transcript"], "description": "audio=소리 크기 기준(기본), transcript=대본 단어 사이 공백 기준" },
                     "threshold_db": num("audio 방식의 무음 기준 음량 dBFS (생략하면 자동)") }), &[]),
        tool("remove_fillers", "'음', '어', '그' 같은 군더더기 말을 모두 잘라낸다.", json!({}), &[]),
        tool("split_at", "지정 시간에서 모든 트랙의 클립을 나눈다.", json!({ "time": num("초") }), &["time"]),
        tool("set_speed", "구간 또는 클립의 재생 속도를 바꾼다(0.1~20배). 구간을 주면 그 경계에서 나눈 뒤 구간 안 영상/오디오 클립에 적용한다.",
             json!({ "speed": num("배속 0.1~20"), "start": num("구간 시작(초), 선택"), "end": num("구간 끝(초), 선택"),
                     "clip_ids": { "type": "array", "items": { "type": "string" }, "description": "대상 클립 id, 선택" } }), &["speed"]),
        tool("set_clip_properties", "클립 속성 변경: 볼륨(0~2), 불투명도(0~1), 크기(배율), 위치(offset_x/y: 캔버스 대비 -1~1), 페이드 인/아웃(초), 텍스트 클립의 글자.",
             json!({ "clip_id": string("클립 id"), "volume": n, "opacity": n, "scale": n, "offset_x": n, "offset_y": n,
                     "fade_in": n, "fade_out": n, "text": string("텍스트 클립 내용") }), &["clip_id"]),
        tool("delete_clips", "클립 삭제. ripple=true면 같은 트랙 뒤 클립을 당긴다.",
             json!({ "clip_ids": { "type": "array", "items": { "type": "string" } }, "ripple": { "type": "boolean" } }), &["clip_ids"]),
        tool("move_clip", "클립을 다른 시간/트랙으로 옮긴다. 트랙 번호는 0이 맨 아래(기본).",
             json!({ "clip_id": string("클립 id"), "start": num("새 시작 시간(초)"), "track": { "type": "integer" } }), &["clip_id", "start"]),
        tool("add_text", "화면에 제목/텍스트를 추가한다.",
             json!({ "text": string("내용"), "start": num("시작(초)"), "duration": num("길이(초, 기본 4)"),
                     "position_y": num("세로 위치 0(위)~1(아래), 기본 0.5"), "font_size": num("1080p 기준 글자 크기, 기본 96"),
                     "color": string("글자색 #RRGGBB") }), &["text", "start"]),
        tool("generate_captions", "대본으로 자막을 새로 만든다(기존 자막 대체).", json!({ "max_chars": { "type": "integer", "description": "자막 한 줄 최대 글자 수 (기본 20)" } }), &[]),
        tool("edit_captions", "자막 추가/수정/삭제. 번호는 get_project_state의 자막 번호.",
             json!({ "add": { "type": "array", "items": { "type": "object", "properties": { "start": n, "end": n, "text": { "type": "string" } }, "required": ["start", "end", "text"] } },
                     "update": { "type": "array", "items": { "type": "object", "properties": { "index": { "type": "integer" }, "text": { "type": "string" }, "start": n, "end": n }, "required": ["index"] } },
                     "delete": { "type": "array", "items": { "type": "integer" } } }), &[]),
        tool("cut_captions", "자막 번호들을 자막과 그 말이 나오는 영상 구간째 삭제한다.",
             json!({ "indices": { "type": "array", "items": { "type": "integer" } } }), &["indices"]),
        tool("move_caption", "자막 한 줄을 그 영상 구간째 다른 자막 앞으로 옮겨 순서를 바꾼다. to_index가 자막 개수면 맨 끝으로.",
             json!({ "index": { "type": "integer" }, "to_index": { "type": "integer" } }), &["index", "to_index"]),
        tool("set_caption_style", "전체 자막 스타일 변경.",
             json!({ "font_size": num("1080p 기준 글자 크기"), "text_color": string("#RRGGBB"), "background_color": string("#RRGGBB"),
                     "background_opacity": num("0~1 (0이면 배경 없음)"), "outline": { "type": "boolean" }, "outline_color": string("외곽선 색 #RRGGBB"),
                     "bold": { "type": "boolean" }, "font_name": string("글꼴 이름 (예: Malgun Gothic), 빈 문자열이면 기본"),
                     "position_y": num("0(위)~1(아래)"), "visible": { "type": "boolean", "description": "자막 표시 여부" } }), &[]),
        tool("set_canvas", "화면 크기/비율 변경.", json!({ "width": n, "height": n }), &["width", "height"]),
        tool("set_playhead", "재생헤드를 옮긴다.", json!({ "time": num("초") }), &["time"]),
        tool("set_playback_speed", "미리보기 재생 속도(0.25~16배)를 바꾸고 선택적으로 재생한다.",
             json!({ "speed": n, "play": { "type": "boolean" } }), &["speed"]),
        tool("import_url", "유튜브 등 영상 링크를 내려받아 프로젝트에 가져온다(빈 타임라인이면 바로 배치). 사용자가 권한이 있는 영상만.",
             json!({ "url": string("영상 페이지 주소"), "quality": { "type": "string", "enum": ["720p", "1080p", "best", "audio"] },
                     "start": num("일부만 받을 때 시작(초)"), "end": num("일부만 받을 때 끝(초)") }), &["url"]),
        tool("transcribe", "타임라인 영상/오디오의 음성 인식(STT)을 시작한다. 끝나면 대본과 자막이 생긴다(수 초~수 분).", json!({}), &[]),
        tool("undo", "마지막 편집을 되돌린다.", json!({ "steps": { "type": "integer", "description": "되돌릴 횟수 (기본 1)" } }), &[]),
    ]
}

/// 도구 이름 → 짧은 한국어 이름 (대화창 표시용)
pub fn label(name: &str) -> String {
    let l = match name {
        "delete_words" => "말 삭제",
        "delete_time_ranges" => "구간 삭제",
        "remove_silences" => "무음 제거",
        "remove_fillers" => "군더더기 제거",
        "split_at" => "분할",
        "set_speed" => "속도 변경",
        "set_clip_properties" => "클립 속성",
        "delete_clips" => "클립 삭제",
        "move_clip" => "클립 이동",
        "add_text" => "텍스트 추가",
        "generate_captions" => "자막 생성",
        "edit_captions" => "자막 편집",
        "cut_captions" => "자막째 삭제",
        "move_caption" => "자막 순서 바꾸기",
        "set_caption_style" => "자막 스타일",
        "set_canvas" => "화면 크기",
        "set_playhead" => "재생헤드 이동",
        "set_playback_speed" => "재생 속도",
        "import_url" => "링크 가져오기",
        "transcribe" => "음성 인식",
        "undo" => "되돌리기",
        "get_project_state" => "상태 확인",
        "get_transcript" => "대본 읽기",
        "search_transcript" => "대본 검색",
        _ => name,
    };
    l.to_string()
}

fn d(input: &Value, k: &str) -> Option<f64> {
    input.get(k)?.as_f64()
}
fn i(input: &Value, k: &str) -> Option<i64> {
    input.get(k)?.as_f64().map(|v| v as i64)
}
fn b(input: &Value, k: &str) -> Option<bool> {
    input.get(k)?.as_bool()
}
fn s<'a>(input: &'a Value, k: &str) -> Option<&'a str> {
    input.get(k)?.as_str()
}

fn clock(t: f64) -> String {
    let t = t.max(0.0);
    let m = (t / 60.0).floor() as i64;
    format!("{:02}:{:05.2}", m, t - m as f64 * 60.0)
}

pub fn parse_ranges(v: Option<&Value>) -> Vec<TimeRange> {
    v.and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|r| {
            let (a, b) = (r.get("start")?.as_f64()?, r.get("end")?.as_f64()?);
            ((b - a).abs() > 0.001).then(|| TimeRange::new(a.min(b), a.max(b)))
        })
        .collect()
}

/// 전체 UUID 또는 앞 8자리로 클립 찾기
pub fn find_clip(key: &str, p: &Project) -> Option<Id> {
    let k = key.trim().to_uppercase();
    if k.is_empty() {
        return None;
    }
    p.tracks.iter().flat_map(|t| &t.clips).map(|c| c.id).find(|id| {
        let s = id.to_string();
        s == k || s.starts_with(&k)
    })
}

pub fn hex_color(s: &str) -> Option<Rgba> {
    let mut h = s.trim().to_uppercase();
    if let Some(x) = h.strip_prefix('#') {
        h = x.to_string();
    }
    let named = match h.as_str() {
        "WHITE" => Some("FFFFFF"),
        "BLACK" => Some("000000"),
        "YELLOW" => Some("FFD60A"),
        "RED" => Some("FF3B30"),
        "BLUE" => Some("0A84FF"),
        "GREEN" => Some("30D158"),
        _ => None,
    };
    if let Some(n) = named {
        h = n.to_string();
    }
    if h.len() != 6 {
        return None;
    }
    let v = u32::from_str_radix(&h, 16).ok()?;
    Some(Rgba { r: ((v >> 16) & 0xFF) as f64 / 255.0, g: ((v >> 8) & 0xFF) as f64 / 255.0, b: (v & 0xFF) as f64 / 255.0, a: 1.0 })
}

fn duration(app: &AppHandle) -> f64 {
    app.state::<AppState>().editor.lock().unwrap().project.duration()
}

/// 편집 하나를 적용하고 화면에 알린다
fn edit(app: &AppHandle, f: impl FnOnce(&mut Project)) {
    app.state::<AppState>().editor.lock().unwrap().apply(f);
    emit_state(app);
}

fn project(app: &AppHandle) -> Project {
    app.state::<AppState>().editor.lock().unwrap().project.clone()
}

/// 도구 실행 (블로킹: 음성 인식처럼 오래 걸리는 도구는 끝날 때까지 기다린다)
pub fn execute(app: &AppHandle, name: &str, input: &Value) -> (String, bool) {
    let before = duration(app);
    let changed = |msg: String| -> (String, bool) { (format!("{msg} (길이 {before:.2}초 → {:.2}초)", duration(app)), false) };
    let err = |m: &str| (m.to_string(), true);

    match name {
        "get_project_state" => (project_state(app), false),

        "get_transcript" => {
            let p = project(app);
            let words = p.timeline_words();
            if words.is_empty() {
                return ("대본이 없습니다. transcribe 도구로 음성 인식을 먼저 실행하세요.".into(), false);
            }
            let from = d(input, "from").unwrap_or(0.0);
            let to = d(input, "to").unwrap_or(f64::INFINITY);
            let mut lines = vec![];
            let mut chars = 0;
            let mut i = words.iter().position(|w| w.end > from).unwrap_or(words.len());
            while i < words.len() && words[i].start < to {
                // 문장 끝(.?!)·긴 쉼·20단어 단위로 한 줄
                let mut j = i;
                while j + 1 < words.len()
                    && words[j + 1].start < to
                    && j - i < 20
                    && !words[j].word.text.chars().last().is_some_and(|c| ".?!".contains(c))
                    && words[j + 1].start - words[j].end < 1.0
                {
                    j += 1;
                }
                let text = words[i..=j].iter().map(|w| w.word.text.as_str()).collect::<Vec<_>>().join(" ");
                let line = format!("[{i}-{j}] {:.1}~{:.1} {text}", words[i].start, words[j].end);
                chars += line.chars().count();
                if chars > 60_000 {
                    lines.push(format!("… 여기까지 {:.1}초. 이어서 보려면 from={:.1}", words[i].start, words[i].start));
                    break;
                }
                lines.push(line);
                i = j + 1;
            }
            (format!("단어 {}개, 전체 {}\n{}", words.len(), clock(p.duration()), lines.join("\n")), false)
        }

        "search_transcript" => {
            let Some(q) = s(input, "query").map(|q| q.replace(' ', "")).filter(|q| !q.is_empty()) else { return err("query가 필요합니다") };
            let q = normalized(&q).replace(' ', "");
            let words = project(app).timeline_words();
            let limit = i(input, "limit").unwrap_or(30).max(1) as usize;
            let qlen = q.chars().count();
            let mut hits = vec![];
            for st in 0..words.len() {
                if hits.len() >= limit {
                    break;
                }
                let mut acc = String::new();
                let mut en = st;
                while en < words.len() && acc.chars().count() < qlen + 20 {
                    acc += &normalized(&words[en].word.text).replace(' ', "");
                    if acc.starts_with(&q) {
                        break;
                    }
                    if !q.starts_with(&acc) {
                        break;
                    }
                    en += 1;
                }
                if en >= words.len() || !acc.starts_with(&q) {
                    continue;
                }
                let (a, z) = (st.saturating_sub(4), (en + 4).min(words.len() - 1));
                let ctx = words[a..=z].iter().map(|w| w.word.text.as_str()).collect::<Vec<_>>().join(" ");
                hits.push(format!("[{st}-{en}] {:.1}~{:.1}초 · …{ctx}…", words[st].start, words[en].end));
            }
            if hits.is_empty() {
                (format!("'{q}'를 찾지 못했습니다"), false)
            } else {
                (format!("{}곳 찾음\n{}", hits.len(), hits.join("\n")), false)
            }
        }

        "delete_words" => {
            let words = project(app).timeline_words();
            let Some(arr) = input.get("ranges").and_then(Value::as_array).filter(|a| !a.is_empty()) else { return err("ranges가 필요합니다") };
            let mut ids = HashSet::new();
            for r in arr {
                let (Some(f), Some(t)) = (r.get("from").and_then(Value::as_f64), r.get("to").and_then(Value::as_f64)) else { continue };
                let (f, t) = (f as i64, t as i64);
                let lo = f.min(t).max(0) as usize;
                let hi = (f.max(t).max(0) as usize).min(words.len().saturating_sub(1));
                if words.is_empty() || lo > hi {
                    continue;
                }
                for w in &words[lo..=hi] {
                    ids.insert(w.id());
                }
            }
            if ids.is_empty() {
                return (format!("유효한 단어 번호가 없습니다 (0~{})", words.len().saturating_sub(1)), true);
            }
            let ranges = deletion_ranges(&ids, &words);
            edit(app, |p| p.ripple_delete_ranges(&ranges));
            changed(format!("{}개 단어 삭제", ids.len()))
        }

        "delete_time_ranges" => {
            let ranges = parse_ranges(input.get("ranges"));
            if ranges.is_empty() {
                return err("ranges가 필요합니다");
            }
            edit(app, |p| p.ripple_delete_ranges(&ranges));
            changed(format!("{}개 구간 삭제", ranges.len()))
        }

        "remove_silences" => {
            let gap = d(input, "min_gap").unwrap_or(0.6);
            let keep = d(input, "keep").unwrap_or(0.12);
            if s(input, "method") == Some("transcript") {
                let ranges = project(app).silence_ranges(gap, keep);
                edit(app, |p| p.ripple_delete_ranges(&ranges));
                return changed(format!("무음 {}곳 삭제", ranges.len()));
            }
            let th = d(input, "threshold_db");
            let settings = SilenceSettings { threshold: th.unwrap_or(-40.0), min_silence: gap, padding: keep };
            match silence_blocking(app, Some(settings), th.is_none(), true) {
                Ok(v) => changed(format!("무음 {}곳 삭제", v["ranges"].as_array().map_or(0, Vec::len))),
                Err(e) => (format!("오디오 분석 실패: {e}"), true),
            }
        }

        "remove_fillers" => {
            let p = project(app);
            let ids = p.filler_word_ids();
            let ranges = deletion_ranges(&ids, &p.timeline_words());
            edit(app, |p| p.ripple_delete_ranges(&ranges));
            changed(format!("군더더기 {}개 삭제", ids.len()))
        }

        "split_at" => {
            let Some(t) = d(input, "time") else { return err("time이 필요합니다") };
            edit(app, |p| p.split_all(t, None));
            (format!("{}에서 분할", clock(t)), false)
        }

        "set_speed" => {
            let Some(sp) = d(input, "speed") else { return err("speed가 필요합니다") };
            let speed = sp.clamp(0.1, 20.0);
            let p = project(app);
            if let Some(ids) = input.get("clip_ids").and_then(Value::as_array).filter(|a| !a.is_empty()) {
                let set: Vec<Id> = ids.iter().filter_map(Value::as_str).filter_map(|k| find_clip(k, &p)).collect();
                if set.is_empty() {
                    return err("클립을 찾지 못했습니다");
                }
                edit(app, |p| set.iter().for_each(|id| p.set_speed(*id, speed)));
                return changed(format!("{}개 클립 {speed}배속", set.len()));
            }
            let a = d(input, "start").unwrap_or(0.0);
            let e = d(input, "end").unwrap_or(p.duration());
            edit(app, |p| {
                p.split_all(a, None);
                p.split_all(e, None);
                // 뒤쪽 클립부터 바꿔야 앞쪽 변경으로 위치가 밀려도 대상이 흔들리지 않는다
                let mut targets: Vec<(f64, Id)> = p
                    .tracks
                    .iter()
                    .flat_map(|t| &t.clips)
                    .filter(|c| c.kind == ClipKind::Media && c.start >= a - 0.01 && c.end() <= e + 0.01)
                    .filter(|c| p.asset(c.asset_id).is_some_and(|x| x.kind != MediaKind::Image))
                    .map(|c| (c.start, c.id))
                    .collect();
                targets.sort_by(|x, y| y.0.total_cmp(&x.0));
                for (_, id) in targets {
                    p.set_speed(id, speed);
                }
            });
            changed(format!("{a:.2}~{e:.2}초 구간 {speed}배속"))
        }

        "set_clip_properties" => {
            let Some(cid) = s(input, "clip_id").and_then(|k| find_clip(k, &project(app))) else { return err("클립을 찾지 못했습니다") };
            edit(app, |p| {
                if let Some(c) = p.clip_mut(cid) {
                    if let Some(v) = d(input, "volume") { c.volume = v.clamp(0.0, 4.0) }
                    if let Some(v) = d(input, "opacity") { c.opacity = v.clamp(0.0, 1.0) }
                    if let Some(v) = d(input, "scale") { c.scale = v.clamp(0.05, 8.0) }
                    if let Some(v) = d(input, "offset_x") { c.offset_x = v }
                    if let Some(v) = d(input, "offset_y") { c.offset_y = v }
                    if let Some(v) = d(input, "fade_in") { c.fade_in = v.max(0.0) }
                    if let Some(v) = d(input, "fade_out") { c.fade_out = v.max(0.0) }
                    if let (Some(v), ClipKind::Text) = (s(input, "text"), c.kind) { c.text = v.to_string() }
                }
            });
            ("클립 속성 변경".into(), false)
        }

        "delete_clips" => {
            let p = project(app);
            let ids: HashSet<Id> = input.get("clip_ids").and_then(Value::as_array).into_iter().flatten()
                .filter_map(Value::as_str).filter_map(|k| find_clip(k, &p)).collect();
            if ids.is_empty() {
                return err("클립을 찾지 못했습니다");
            }
            let ripple = b(input, "ripple").unwrap_or(false);
            edit(app, |p| p.delete_clips(&ids, ripple));
            changed(format!("{}개 클립 삭제", ids.len()))
        }

        "move_clip" => {
            let p = project(app);
            let (Some(cid), Some(st)) = (s(input, "clip_id").and_then(|k| find_clip(k, &p)), d(input, "start")) else { return err("클립을 찾지 못했습니다") };
            let track = i(input, "track").map(|t| t.max(0) as usize).or_else(|| p.locate(cid).map(|l| l.0)).unwrap_or(0);
            edit(app, |p| p.move_clip(cid, track, st));
            ("클립 이동".into(), false)
        }

        "add_text" => {
            let (Some(text), Some(st)) = (s(input, "text"), d(input, "start")) else { return err("text, start가 필요합니다") };
            edit(app, |p| {
                let ti = p.tracks.len().saturating_sub(1).max(1);
                let id = p.insert_text(text, ti, st, d(input, "duration").unwrap_or(4.0));
                if let Some(c) = p.clip_mut(id) {
                    if let Some(y) = d(input, "position_y") { c.text_style.position_y = y }
                    if let Some(f) = d(input, "font_size") { c.text_style.font_size = f }
                    if let Some(col) = s(input, "color").and_then(hex_color) { c.text_style.text_color = col }
                }
            });
            (format!("텍스트 추가: {text}"), false)
        }

        "generate_captions" => {
            let max = i(input, "max_chars").unwrap_or(20).max(4) as usize;
            let caps = project(app).generated_captions(max, 4.5, 0.6);
            if caps.is_empty() {
                return err("대본이 없어 자막을 만들 수 없습니다");
            }
            let n = caps.len();
            edit(app, |p| {
                p.captions = caps;
                p.show_captions = true;
            });
            (format!("자막 {n}개 생성"), false)
        }

        "edit_captions" => {
            let (mut added, mut updated, mut deleted) = (0, 0, 0);
            edit(app, |p| {
                let snapshot = p.captions.clone();
                let mut remove = HashSet::new();
                for n in input.get("delete").and_then(Value::as_array).into_iter().flatten().filter_map(Value::as_f64) {
                    if let Some(c) = snapshot.get(n as usize) {
                        remove.insert(c.id);
                        deleted += 1;
                    }
                }
                for u in input.get("update").and_then(Value::as_array).into_iter().flatten() {
                    let Some(n) = u.get("index").and_then(Value::as_f64) else { continue };
                    let Some(id) = snapshot.get(n as usize).map(|c| c.id) else { continue };
                    let Some(c) = p.captions.iter_mut().find(|c| c.id == id) else { continue };
                    if let Some(t) = u.get("text").and_then(Value::as_str) { c.text = t.to_string() }
                    if let Some(v) = u.get("start").and_then(Value::as_f64) { c.start = v }
                    if let Some(v) = u.get("end").and_then(Value::as_f64) { c.end = v }
                    updated += 1;
                }
                p.captions.retain(|c| !remove.contains(&c.id));
                for a in input.get("add").and_then(Value::as_array).into_iter().flatten() {
                    let (Some(st), Some(en), Some(t)) = (a.get("start").and_then(Value::as_f64), a.get("end").and_then(Value::as_f64), a.get("text").and_then(Value::as_str)) else { continue };
                    p.captions.push(Caption::new(st, en.max(st + 0.2), t));
                    added += 1;
                }
            });
            (format!("자막 추가 {added} · 수정 {updated} · 삭제 {deleted}"), false)
        }

        "cut_captions" => {
            let p = project(app);
            let mut sorted = p.captions.clone();
            sorted.sort_by(|a, b| a.start.total_cmp(&b.start));
            let ids: HashSet<Id> = input.get("indices").and_then(Value::as_array).into_iter().flatten()
                .filter_map(Value::as_f64).filter_map(|n| sorted.get(n as usize).map(|c| c.id)).collect();
            if ids.is_empty() {
                return err("유효한 자막 번호가 없습니다");
            }
            edit(app, |p| crate::edits::delete_captions(p, &ids, true));
            changed(format!("자막 {}개와 영상 구간 삭제", ids.len()))
        }

        "move_caption" => {
            let (Some(from), Some(to)) = (i(input, "index"), i(input, "to_index")) else { return err("index, to_index가 필요합니다") };
            edit(app, |p| crate::edits::move_caption(p, from.max(0) as usize, to.max(0) as usize));
            (format!("자막 {from}번을 {to}번 자리로 옮김"), false)
        }

        "set_caption_style" => {
            edit(app, |p| {
                let cs = &mut p.caption_style;
                if let Some(v) = d(input, "font_size") { cs.font_size = v }
                if let Some(c) = s(input, "text_color").and_then(hex_color) { cs.text_color = c }
                if let Some(c) = s(input, "background_color").and_then(hex_color) {
                    let a = cs.background_color.a;
                    cs.background_color = Rgba { a: if a > 0.0 { a } else { 0.6 }, ..c };
                }
                if let Some(v) = d(input, "background_opacity") { cs.background_color.a = v.clamp(0.0, 1.0) }
                if let Some(v) = b(input, "outline") { cs.outline = v }
                if let Some(c) = s(input, "outline_color").and_then(hex_color) {
                    cs.outline_color = c;
                    cs.outline = true;
                }
                if let Some(v) = s(input, "font_name") { cs.font_name = v.to_string() }
                if let Some(v) = b(input, "bold") { cs.bold = v }
                if let Some(v) = d(input, "position_y") { cs.position_y = v.clamp(0.03, 0.97) }
                if let Some(v) = b(input, "visible") { p.show_captions = v }
            });
            ("자막 스타일 변경".into(), false)
        }

        "set_canvas" => {
            let (Some(w), Some(h)) = (d(input, "width"), d(input, "height")) else { return err("width, height가 필요합니다") };
            if w < 16.0 || h < 16.0 {
                return err("width, height가 필요합니다");
            }
            edit(app, |p| {
                p.canvas_width = w.round();
                p.canvas_height = h.round();
            });
            (format!("화면 크기 {}×{}", w.round(), h.round()), false)
        }

        "set_playhead" => {
            let Some(t) = d(input, "time") else { return err("time이 필요합니다") };
            let _ = app.emit("ui-command", json!({ "action": "seek", "time": t }));
            (format!("재생헤드 {}", clock(t)), false)
        }

        "set_playback_speed" => {
            let Some(sp) = d(input, "speed") else { return err("speed가 필요합니다") };
            let sp = sp.clamp(0.25, 16.0);
            let _ = app.emit("ui-command", json!({ "action": "speed", "speed": sp, "play": b(input, "play") }));
            (format!("미리보기 {sp}배속 재생 속도"), false)
        }

        "import_url" => {
            let Some(u) = s(input, "url").filter(|u| crate::link::is_link(u)) else { return err("올바른 링크가 필요합니다") };
            let opts = crate::link::Options {
                quality: s(input, "quality").unwrap_or("1080p").to_string(),
                start: d(input, "start"),
                end: d(input, "end"),
            };
            match crate::link::import_blocking(app, u, &opts) {
                Ok(name) => changed(format!("가져옴: {name}")),
                Err(e) => (format!("가져오기 실패: {e}"), true),
            }
        }

        "transcribe" => {
            let p = project(app);
            let used: HashSet<Id> = p.tracks.iter().flat_map(|t| &t.clips).filter_map(|c| c.asset_id).collect();
            let targets: Vec<Id> = p.assets.iter().filter(|a| used.contains(&a.id) && a.has_audio && a.words.is_none()).map(|a| a.id).collect();
            if targets.is_empty() {
                return ("인식할 새 미디어가 없습니다 (이미 대본이 있거나 오디오 없음)".into(), false);
            }
            if !crate::stt::model_ready() {
                let a2 = app.clone();
                if let Err(e) = crate::stt::download_model(|v| job(&a2, "model", v, "Whisper 모델 받는 중…")) {
                    return (format!("음성 인식 모델을 받지 못했습니다: {e}"), true);
                }
            }
            let lang = app.state::<AppState>().ui.lock().unwrap().language.clone();
            for id in targets {
                if let Err(e) = transcribe_blocking(app, id, &lang) {
                    emit_state(app);
                    return (format!("음성 인식 실패: {e}"), true);
                }
            }
            // 자막이 없으면 대본으로 만든다 (앱에서 처음 인식할 때와 같음)
            let caps = { let p = project(app); if p.captions.is_empty() { p.generated_captions_default() } else { vec![] } };
            let made = caps.len();
            if made > 0 {
                edit(app, |p| {
                    p.captions = caps;
                    p.show_captions = true;
                });
            } else {
                emit_state(app);
            }
            let words = project(app).timeline_words().len();
            (if made > 0 { format!("음성 인식 완료: 대본 단어 {words}개, 자막 {made}개 생성") } else { format!("음성 인식 완료: 대본 단어 {words}개") }, false)
        }

        "undo" => {
            let n = i(input, "steps").unwrap_or(1).clamp(1, 50);
            {
                let st = app.state::<AppState>();
                let mut e = st.editor.lock().unwrap();
                for _ in 0..n {
                    e.undo_step();
                }
            }
            emit_state(app);
            changed(format!("{n}단계 되돌림"))
        }

        _ => (format!("알 수 없는 도구: {name}"), true),
    }
}

fn project_state(app: &AppHandle) -> String {
    let st = app.state::<AppState>();
    let p = st.editor.lock().unwrap().project.clone();
    let ui = st.ui.lock().unwrap().clone();
    let mut o = vec![];
    o.push(format!("전체 길이 {:.2}초, 재생헤드 {:.2}초, 캔버스 {}×{}, {}fps", p.duration(), ui.time, p.canvas_width as i64, p.canvas_height as i64, p.fps));
    let kind = |k: MediaKind| match k {
        MediaKind::Video => "video",
        MediaKind::Audio => "audio",
        MediaKind::Image => "image",
    };
    o.push(format!(
        "미디어: {}",
        p.assets
            .iter()
            .map(|a| format!("{}({}, {:.1}초, 대본 {})", a.name, kind(a.kind), a.duration, a.words.as_ref().map_or("없음".into(), |w| format!("{}단어", w.len()))))
            .collect::<Vec<_>>()
            .join(", ")
    ));
    for (ti, t) in p.tracks.iter().enumerate() {
        o.push(format!("트랙 {ti}{}{}{}: 클립 {}개", if ti == 0 { " (기본)" } else { "" }, if t.muted { " 음소거" } else { "" }, if t.hidden { " 숨김" } else { "" }, t.clips.len()));
        let shown: Vec<_> = if t.clips.len() > 30 {
            o.push("  (많아서 처음 15개와 마지막 5개만 표시. 특정 시간대 클립은 편집 도구에 시간으로 지정하세요)".into());
            t.clips[..15].iter().chain(&t.clips[t.clips.len() - 5..]).collect()
        } else {
            t.clips.iter().collect()
        };
        for c in shown {
            let label = if c.kind == ClipKind::Text {
                format!("텍스트 \"{}\"", c.text)
            } else {
                let a = p.asset(c.asset_id);
                format!("{} {}", a.map_or("?", |a| kind(a.kind)), a.map_or("", |a| a.name.as_str()))
            };
            o.push(format!(
                "  - id {} | {} | {:.2}~{:.2}초 | 원본 {:.2}~{:.2} | {}배속 | 볼륨 {:.0}% | 크기 {:.0}%",
                &c.id.to_string()[..8], label, c.start, c.end(), c.source_in, c.source_out, c.speed, c.volume * 100.0, c.scale * 100.0
            ));
        }
    }
    o.push(format!("자막 {}개 (표시 {}, 크기 {}, 위치 {:.2})", p.captions.len(), if p.show_captions { "켬" } else { "끔" }, p.caption_style.font_size as i64, p.caption_style.position_y));
    for (n, c) in p.captions.iter().take(20).enumerate() {
        o.push(format!("  [{n}] {:.2}~{:.2} {}", c.start, c.end, c.text));
    }
    if p.captions.len() > 20 {
        o.push(format!("  … 이하 {}개 생략 (자막 내용은 대본과 같습니다)", p.captions.len() - 20));
    }
    o.push(format!("대본 단어 {}개", p.timeline_words().len()));
    if !ui.selection.is_empty() {
        o.push(format!("선택된 클립: {}", ui.selection.iter().map(|s| s.chars().take(8).collect::<String>()).collect::<Vec<_>>().join(", ")));
    }
    if let (Some(a), Some(b)) = (ui.mark_in, ui.mark_out) {
        if (b - a).abs() > 0.02 {
            o.push(format!("In/Out 구간: {:.2}~{:.2}", a.min(b), a.max(b)));
        }
    }
    o.join("\n")
}
