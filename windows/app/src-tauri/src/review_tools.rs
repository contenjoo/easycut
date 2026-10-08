//! 편집 결과를 검토하고 고치는 AI 도구 (맥 AIReviewTools.swift와 이름·입력·출력이 같다):
//! 전체 자막 읽기, 클립 경계·원본 연결 보기, 구간 소리 듣기, 경계 조정·잘린 말 되살리기.
use crate::{emit_state, media, stt, tools, AppState};
use easycut_core::silence::{auto_threshold, loudness, HOP};
use easycut_core::{Clip, ClipKind, MediaAsset, MediaKind, Project, Word};
use serde_json::{json, Value};
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

fn tool(name: &str, desc: &str, props: Value, required: &[&str]) -> Value {
    json!({ "name": name, "description": desc, "input_schema": { "type": "object", "properties": props, "required": required } })
}

fn num(d: &str) -> Value {
    json!({ "type": "number", "description": d })
}

pub fn definitions() -> Vec<Value> {
    vec![
        tool("get_captions", "자막 전체를 번호·시작~끝·내용으로 돌려준다(get_project_state는 처음 20개만 보여 준다). 길면 from/to(초)나 start_index로 나눠 읽는다. 번호는 edit_captions·cut_captions에 그대로 쓴다.",
             json!({ "from": num("시작 시간(초), 선택"), "to": num("끝 시간(초), 선택"),
                     "start_index": { "type": "integer", "description": "이 번호부터, 선택" }, "limit": { "type": "integer", "description": "최대 개수 (기본 300)" } }), &[]),
        tool("get_clips", "구간 안 클립의 상세: 트랙, 타임라인 시작~끝, 원본 시작~끝, 속도, 그리고 같은 원본을 잘라 붙인 경계마다 잘린 원본 구간과 그 안에 있던 말, 경계에 걸쳐 일부만 남은 말. 말이 잘렸는지 볼 때 쓴다.",
             json!({ "from": num("시작(초), 선택"), "to": num("끝(초), 선택"), "track": { "type": "integer", "description": "트랙 번호, 선택" } }), &[]),
        tool("listen_range", "타임라인 구간의 실제 소리를 확인한다: 원본 대본 단어를 남은 말/잘린 말/경계에 걸린 말로 표시하고, 클립 경계 앞뒤의 소리 크기로 말소리 중간에서 잘렸는지 알려 준다. recognize=true면 그 구간 원음을 Whisper로 다시 받아써 자막과 비교할 수 있다(수 초 걸림).",
             json!({ "start": num("시작(초)"), "end": num("끝(초)"), "pad": num("클립 경계 바깥(잘린 쪽)으로 더 볼 원본 초 (기본 1.0)"),
                     "recognize": { "type": "boolean", "description": "원음을 다시 받아쓰기 (기본 false)" } }), &["start", "end"]),
        tool("adjust_clip_edge", "클립 가장자리를 원본 기준으로 늘리거나(seconds>0, 잘린 말 되살리기) 줄인다(seconds<0). 뒤의 영상·오디오·자막 시간도 함께 밀리거나 당겨진다.",
             json!({ "clip_id": { "type": "string", "description": "클립 id" }, "edge": { "type": "string", "enum": ["start", "end"] }, "seconds": num("원본 초. +늘리기, -줄이기") }),
             &["clip_id", "edge", "seconds"]),
        tool("restore_cut", "같은 원본을 잘라 붙인 경계에서 잘라낸 원본을 되살린다. before/after를 모두 생략하면 잘린 구간 전체를 되살려 두 클립을 합친다. before=앞 클립 끝을 늘릴 원본 초, after=뒤 클립 시작을 당길 원본 초. 뒤의 영상·자막도 함께 밀린다. 되살린 말에는 자막이 없으므로 필요하면 edit_captions로 추가한다.",
             json!({ "time": num("경계 근처 타임라인 시간(초)"), "track": { "type": "integer", "description": "트랙 번호, 선택" },
                     "before": num("앞 클립 끝을 늘릴 원본 초, 선택"), "after": num("뒤 클립 시작을 당길 원본 초, 선택") }), &["time"]),
        tool("check_caption_sync", "자막 시작 시간과 실제 말소리가 시작되는 순간(소리 크기 기준)을 자막마다 비교해, 자막이 빠른지 늦은지와 그 차이가 일정한지 알려 준다. 미리보기 소리 출력 지연에 대한 안내도 함께 준다. 자막 시간을 고치기 전에 먼저 쓴다.",
             json!({ "from": num("시작(초), 선택"), "to": num("끝(초), 선택") }), &[]),
        tool("align_captions", "check_caption_sync와 같은 측정으로 자막 시간을 실제 말소리에 맞춘다. mode=auto(기본): 차이가 일정하면 한꺼번에 옮기고 아니면 자막마다 맞춤. shift: seconds만큼(생략하면 측정한 중앙값) 한꺼번에 옮김. snap: 잴 수 있는 자막마다 말 시작에 맞춤.",
             json!({ "mode": { "type": "string", "enum": ["auto", "shift", "snap"] }, "seconds": num("shift 때 옮길 초 (+늦추기, -앞당기기), 선택"),
                     "from": num("시작(초), 선택"), "to": num("끝(초), 선택") }), &[]),
        tool("export_range", "타임라인 구간만 짧게 MP4로 내보내 기본 플레이어로 연다. 미리보기에서만 어긋나는지, 내보낸 영상도 어긋나는지 사용자가 확인할 때 쓴다.",
             json!({ "start": num("시작(초)"), "end": num("끝(초)"), "captions": { "type": "boolean", "description": "자막 굽기 (기본 true)" },
                     "open": { "type": "boolean", "description": "내보낸 뒤 열기 (기본 true)" } }), &["start", "end"]),
    ]
}

/// 쓰인 미디어의 음량으로 자막 시간 측정
pub(crate) fn sync_report(app: &AppHandle, from: f64, to: f64) -> easycut_core::review_ops::SyncReport {
    let p = project(app);
    let used: std::collections::HashSet<_> = p.tracks.iter().flat_map(|t| &t.clips).filter_map(|c| c.asset_id).collect();
    let (mut loud, mut th) = (std::collections::HashMap::new(), std::collections::HashMap::new());
    for a in p.assets.iter().filter(|a| used.contains(&a.id) && a.has_audio) {
        if let Some(db) = asset_loudness(app, a) {
            th.insert(a.id, auto_threshold(&db));
            loud.insert(a.id, db);
        }
    }
    p.caption_sync(&loud, &th, from, to, 0.6)
}

/// 윈도우는 출력 장치 지연을 알 수 없어 안내만 한다
const OUTPUT_NOTE: &str = "미리보기 소리 출력: 윈도우에서는 장치 지연을 확인하지 못합니다. 블루투스 이어폰이면 미리보기 소리가 0.1~0.3초 늦게 들릴 수 있으니, 미리보기에서만 자막이 빠르게 느껴지면 자막을 옮기지 말고 export_range로 내보낸 영상을 확인하세요";

fn short(c: &Clip) -> String {
    c.id.to_string()[..8].to_string()
}

/// 원본 구간 안의 단어 (가운데가 구간 안)
fn words_in(a: Option<&MediaAsset>, r: (f64, f64)) -> Vec<Word> {
    a.and_then(|a| a.words.as_ref())
        .map(|ws| ws.iter().filter(|w| { let m = (w.start + w.end) / 2.0; m >= r.0 && m < r.1 }).cloned().collect())
        .unwrap_or_default()
}

fn join_text(ws: &[Word]) -> String {
    ws.iter().map(|w| w.text.as_str()).collect::<Vec<_>>().join(" ")
}

/// 한 미디어의 10ms 음량 (편집기에 없으면 계산해 둔다)
fn asset_loudness(app: &AppHandle, a: &MediaAsset) -> Option<Vec<f32>> {
    let st = app.state::<AppState>();
    if let Some(l) = st.editor.lock().unwrap().loudness.get(&a.id) {
        return Some(l.clone());
    }
    if !a.has_audio {
        return None;
    }
    let l = loudness(&media::pcm(&PathBuf::from(&a.path), 8000).ok()?);
    st.editor.lock().unwrap().loudness.insert(a.id, l.clone());
    Some(l)
}

/// 원본 [a, b] 구간을 Whisper로 다시 받아쓴다 (원본 시간으로 돌려준다)
pub(crate) fn recognize(a: &MediaAsset, wa: f64, wb: f64, language: &str) -> Result<Vec<Word>, String> {
    let ffmpeg = tools::find_tool("ffmpeg").ok_or("ffmpeg를 찾을 수 없습니다.")?;
    let wav = tools::temp_dir().join(format!("listen-{}.wav", std::process::id()));
    let out = tools::command(&ffmpeg)
        .args(["-y", "-v", "error", "-nostdin", "-ss", &format!("{wa:.3}"), "-t", &format!("{:.3}", wb - wa), "-i", &a.path, "-vn", "-ac", "1", "-ar", "16000"])
        .arg(&wav)
        .output()
        .map_err(|e| e.to_string())?;
    if !out.status.success() {
        return Err(String::from_utf8_lossy(&out.stderr).lines().last().unwrap_or("").to_string());
    }
    let r = stt::transcribe(&wav, if language.is_empty() { "ko" } else { language }, |_, _| {}, |_| {}, || false);
    let _ = std::fs::remove_file(&wav);
    Ok(r?.into_iter().map(|w| Word::new(w.text, w.start + wa, w.end + wa)).collect())
}

fn tag(c: &Clip, w: &Word) -> String {
    if w.end <= c.source_in + 0.01 || w.start >= c.source_out - 0.01 {
        return format!("✂ \"{}\" 잘림 (원본 {:.2}~{:.2})", w.text, w.start, w.end);
    }
    if w.start < c.source_in - 0.02 || w.end > c.source_out + 0.02 {
        return format!("◐ \"{}\" 일부 잘림 (원본 {:.2}~{:.2}, 남은 부분 타임라인 {:.2}~{:.2})", w.text, w.start, w.end,
            c.timeline_time(w.start.max(c.source_in)), c.timeline_time(w.end.min(c.source_out)));
    }
    format!("▶ \"{}\" {:.2}~{:.2}", w.text, c.timeline_time(w.start), c.timeline_time(w.end))
}

fn project(app: &AppHandle) -> Project {
    app.state::<AppState>().editor.lock().unwrap().project.clone()
}

/// 이 파일의 도구면 실행 결과, 아니면 None
pub fn execute(app: &AppHandle, name: &str, input: &Value) -> Option<(String, bool)> {
    let d = |k: &str| input.get(k).and_then(Value::as_f64);
    let i = |k: &str| input.get(k).and_then(Value::as_i64);
    let p = project(app);
    let ok = |s: String| Some((s, false));
    let err = |s: &str| Some((s.to_string(), true));
    match name {
        "get_captions" => {
            let (from, to) = (d("from").unwrap_or(0.0), d("to").unwrap_or(f64::INFINITY));
            let first = i("start_index").unwrap_or(0).max(0) as usize;
            let limit = i("limit").unwrap_or(300).max(1) as usize;
            let mut o = vec![format!("자막 {}개 (번호 시작~끝초 내용)", p.captions.len())];
            let (mut chars, mut shown) = (0, 0);
            for (n, c) in p.captions.iter().enumerate() {
                if n < first || c.end <= from || c.start >= to {
                    continue;
                }
                if shown >= limit || chars > 60_000 {
                    o.push(format!("… 이어서 보려면 start_index={n}"));
                    break;
                }
                let line = format!("[{n}] {:.2}~{:.2} {}", c.start, c.end, c.text);
                chars += line.chars().count();
                shown += 1;
                o.push(line);
            }
            if shown == 0 {
                o.push("(이 범위에 자막이 없습니다)".into());
            }
            ok(o.join("\n"))
        }

        "get_clips" => {
            let (from, to) = (d("from").unwrap_or(0.0), d("to").unwrap_or(f64::INFINITY));
            let only = i("track").map(|t| t.max(0) as usize);
            let cuts = p.cut_points(only);
            let mut o = vec![];
            let mut chars = 0;
            'tracks: for (ti, t) in p.tracks.iter().enumerate() {
                if only.is_some_and(|x| x != ti) {
                    continue;
                }
                for c in t.clips.iter().filter(|c| c.end() > from && c.start < to) {
                    let a = p.asset(c.asset_id);
                    let kind = |k: MediaKind| match k { MediaKind::Video => "video", MediaKind::Audio => "audio", MediaKind::Image => "image" };
                    let label = if c.kind == ClipKind::Text { format!("텍스트 \"{}\"", c.text) } else { format!("{} {}", a.map_or("?", |a| kind(a.kind)), a.map_or("", |a| a.name.as_str())) };
                    let mut line = format!("트랙 {ti} | id {} | {label} | 타임라인 {:.2}~{:.2} | 원본 {:.2}~{:.2} | {}배속", short(c), c.start, c.end(), c.source_in, c.source_out, c.speed);
                    if let (ClipKind::Media, Some(ws)) = (c.kind, a.and_then(|a| a.words.as_ref())) {
                        if let Some(w) = ws.iter().find(|w| w.start < c.source_in - 0.02 && w.end > c.source_in + 0.02) {
                            line += &format!("\n    시작 경계에 걸친 말 \"{}\" (원본 {:.2}~{:.2}, 앞 {:.2}초 잘림)", w.text, w.start, w.end, c.source_in - w.start);
                        }
                        if let Some(w) = ws.iter().find(|w| w.start < c.source_out - 0.02 && w.end > c.source_out + 0.02) {
                            line += &format!("\n    끝 경계에 걸친 말 \"{}\" (원본 {:.2}~{:.2}, 뒤 {:.2}초 잘림)", w.text, w.start, w.end, w.end - c.source_out);
                        }
                    }
                    if let Some(cp) = cuts.iter().find(|cp| cp.right == c.id) {
                        let gone = join_text(&words_in(a, cp.gap));
                        line += &format!("\n    ↑ 앞 클립과의 경계 {:.2}초: 원본 {:.2}~{:.2} ({:.2}초) 잘림{}", cp.time, cp.gap.0, cp.gap.1, cp.gap.1 - cp.gap.0,
                            if gone.is_empty() { " (말 없음)".to_string() } else { format!(" — 잘린 말: {gone}") });
                    }
                    chars += line.chars().count();
                    if chars > 60_000 {
                        o.push(format!("… 길어서 여기까지. 이어서 보려면 from={:.2}", c.start));
                        break 'tracks;
                    }
                    o.push(line);
                }
            }
            if o.is_empty() { ok("이 범위에 클립이 없습니다".into()) } else { ok(o.join("\n")) }
        }

        "listen_range" => {
            let (Some(st), Some(en)) = (d("start"), d("end")) else { return err("start < end 가 필요합니다") };
            if en <= st {
                return err("start < end 가 필요합니다");
            }
            let pad = d("pad").unwrap_or(1.0).clamp(0.0, 5.0);
            let rec = input.get("recognize").and_then(Value::as_bool).unwrap_or(false);
            let language = app.state::<AppState>().ui.lock().unwrap().language.clone();
            let mut o = vec![];
            for (ti, t) in p.tracks.iter().enumerate() {
                if t.muted {
                    continue;
                }
                for c in t.clips.iter().filter(|c| c.kind == ClipKind::Media && c.end() > st && c.start < en) {
                    let Some(a) = p.asset(c.asset_id).filter(|a| a.has_audio && c.volume > 0.001) else { continue };
                    let (ta, tb) = (st.max(c.start), en.min(c.end()));
                    let (at_start, at_end) = (ta <= c.start + 0.001, tb >= c.end() - 0.001);
                    let (sa, sb) = (c.source_time(ta), c.source_time(tb));
                    let wa = if at_start { (sa - pad).max(0.0) } else { sa };
                    let wb = if at_end { (sb + pad).min(a.duration) } else { sb };
                    o.push(format!("■ 트랙 {ti} 클립 {} ({}) 타임라인 {ta:.2}~{tb:.2} = 원본 {sa:.2}~{sb:.2}. 원본 {wa:.2}~{wb:.2} 구간 확인", short(c), a.name));
                    match &a.words {
                        None => o.push("  (대본 없음 — transcribe로 음성 인식을 먼저 하거나 recognize=true로 받아쓰기)".into()),
                        Some(ws) => {
                            let ws: Vec<String> = ws.iter().filter(|w| w.end > wa && w.start < wb).map(|w| tag(c, w)).collect();
                            o.push(format!("  대본 단어: {}", if ws.is_empty() { "(없음)".into() } else { ws.join(" · ") }));
                        }
                    }
                    if let Some(db) = asset_loudness(app, a).filter(|d| !d.is_empty()) {
                        let th = auto_threshold(&db);
                        let level = |x: f64, y: f64| -> f64 {
                            let (i0, i1) = (((x / HOP) as isize).max(0) as usize, ((y / HOP) as usize).min(db.len()));
                            if i1 <= i0 { -100.0 } else { db[i0..i1].iter().fold(-100f32, |m, v| m.max(*v)) as f64 }
                        };
                        let mut edge = |name: &str, s: f64, kept_after: bool| {
                            let (cut, kept) = if kept_after { (level(s - 0.2, s), level(s, s + 0.2)) } else { (level(s, s + 0.2), level(s - 0.2, s)) };
                            let verdict = if cut > th && kept > th { "말소리가 이어지는 중에 잘렸을 수 있음" } else if cut > th { "잘린 쪽에 소리가 있음" } else { "경계는 조용함" };
                            o.push(format!("  {name} 경계(원본 {s:.2}): 잘린 쪽 {cut:.0}dB, 남은 쪽 {kept:.0}dB (말소리 기준 {th:.0}dB) → {verdict}"));
                        };
                        if at_start && c.source_in > 0.05 {
                            edge("시작", c.source_in, true);
                        }
                        if at_end && c.source_out < a.duration - 0.05 {
                            edge("끝", c.source_out, false);
                        }
                    }
                    if rec {
                        if !stt::model_ready() || tools::find_tool("whisper-cli").is_none() {
                            o.push("  (Whisper가 준비되지 않아 받아쓰기를 못 했습니다)".into());
                        } else {
                            match recognize(a, wa, wb, &language) {
                                Ok(h) => o.push(format!("  다시 받아쓴 원음: {}", if h.is_empty() { "(말소리 없음)".into() } else { h.iter().map(|w| tag(c, w)).collect::<Vec<_>>().join(" · ") })),
                                Err(e) => o.push(format!("  받아쓰기 실패: {e}")),
                            }
                        }
                    }
                }
            }
            let caps: Vec<String> = p.captions.iter().enumerate().filter(|(_, c)| c.end > st && c.start < en).map(|(n, c)| format!("[{n}] {:.2}~{:.2} {}", c.start, c.end, c.text)).collect();
            if o.is_empty() {
                o.push("이 구간에 소리가 있는 클립이 없습니다".into());
            }
            o.push(format!("이 구간 자막: {}", if caps.is_empty() { "(없음)".into() } else { caps.join(" / ") }));
            ok(o.join("\n"))
        }

        "adjust_clip_edge" => {
            let Some(c) = input.get("clip_id").and_then(Value::as_str).and_then(|k| crate::ai_tools::find_clip(k, &p)).and_then(|id| p.clip(id)).filter(|c| c.kind == ClipKind::Media).cloned() else {
                return err("영상/오디오 클립을 찾지 못했습니다");
            };
            let Some(a) = p.asset(c.asset_id).cloned() else { return err("영상/오디오 클립을 찾지 못했습니다") };
            let Some(sec) = d("seconds").filter(|s| s.abs() > 0.0005) else { return err("seconds가 필요합니다") };
            if a.kind == MediaKind::Image {
                return err("사진 클립은 길이를 바꾸세요 (원본이 없습니다)");
            }
            let at_end = input.get("edge").and_then(Value::as_str) != Some("start");
            let before = p.duration();
            let mut done = 0.0;
            {
                let st = app.state::<AppState>();
                st.editor.lock().unwrap().apply(|q| done = q.adjust_edge(c.id, at_end, sec, a.duration));
            }
            emit_state(app);
            if done.abs() < 0.0005 {
                return err("더 늘리거나 줄일 수 없습니다 (원본 처음/끝 또는 최소 길이)");
            }
            let r = match (at_end, done > 0.0) {
                (true, true) => (c.source_out, c.source_out + done),
                (true, false) => (c.source_out + done, c.source_out),
                (false, true) => (c.source_in - done, c.source_in),
                (false, false) => (c.source_in, c.source_in - done),
            };
            let ws = join_text(&words_in(Some(&a), r));
            ok(format!("{} {} 원본 {:.2}초 {} (원본 {:.2}~{:.2}{}). 길이 {before:.2}초 → {:.2}초", if at_end { "끝" } else { "시작" }, if done > 0.0 { "늘림" } else { "줄임" },
                done.abs(), if done > 0.0 { "되살림" } else { "잘라냄" }, r.0, r.1, if ws.is_empty() { String::new() } else { format!(", 말: {ws}") }, project(app).duration()))
        }

        "restore_cut" => {
            let Some(t) = d("time") else { return err("time이 필요합니다") };
            let cuts = p.cut_points(i("track").map(|x| x.max(0) as usize));
            let Some(cp) = cuts.iter().min_by(|a, b| (a.time - t).abs().total_cmp(&(b.time - t).abs())).filter(|cp| (cp.time - t).abs() <= 1.5).cloned() else {
                return err(&format!("{t:.2}초 근처(±1.5초)에 같은 원본을 잘라 붙인 경계가 없습니다. get_clips로 경계를 확인하세요"));
            };
            let a = p.clip(cp.left).and_then(|c| p.asset(c.asset_id)).cloned();
            let before = p.duration();
            let mut restored = vec![];
            {
                let st = app.state::<AppState>();
                st.editor.lock().unwrap().apply(|q| restored = q.restore_cut(&cp, d("before"), d("after")));
            }
            emit_state(app);
            if restored.is_empty() {
                return err("되살릴 구간이 없습니다");
            }
            let ws = join_text(&restored.iter().flat_map(|r| words_in(a.as_ref(), *r)).collect::<Vec<_>>());
            let rs = restored.iter().map(|r| format!("{:.2}~{:.2}", r.0, r.1)).collect::<Vec<_>>().join(", ");
            ok(format!("{:.2}초 경계에서 원본 {rs} 되살림{}. 길이 {before:.2}초 → {:.2}초 (뒤 영상·자막도 밀림)", cp.time,
                if ws.is_empty() { " (말 없음)".to_string() } else { format!(" — 되살린 말: {ws} (이 말이 자막에 없으면 edit_captions로 추가)") }, project(app).duration()))
        }

        "check_caption_sync" => {
            if p.captions.is_empty() {
                return err("자막이 없습니다");
            }
            let r = sync_report(app, d("from").unwrap_or(0.0), d("to").unwrap_or(f64::INFINITY));
            let mut o = vec![];
            if r.measures.is_empty() {
                o.push(format!("잴 수 있는 자막이 없습니다 (자막 앞에 조용한 틈이 있어야 말 시작을 찾을 수 있습니다). 건너뜀 {}개", r.skipped));
            } else {
                let dir = if r.median.abs() < 0.03 { "차이 없음" } else if r.median > 0.0 { "빠름 (늦춰야 함)" } else { "늦음 (앞당겨야 함)" };
                let verdict = if r.consistent() {
                    if r.median.abs() < 0.05 { "자막 시간은 맞습니다" } else { "차이가 일정하므로 align_captions mode=shift로 한꺼번에 옮기면 됩니다" }
                } else {
                    "구간마다 달라서 align_captions mode=snap으로 자막마다 맞추는 게 좋습니다"
                };
                o.push(format!("자막 {}개를 잼 (건너뜀 {}개): 자막이 말보다 중앙값 {:.2}초 {dir}, 편차 {:.2}초 → {verdict}", r.measures.len(), r.skipped, r.median.abs(), r.spread));
                for m in r.measures.iter().take(60) {
                    o.push(format!("  [{}] 자막 {:.2} / 말 시작 {:.2} → {:+.2}초", m.index, m.caption_start, m.onset, m.offset()));
                }
                if r.measures.len() > 60 {
                    o.push(format!("  … ({}개 더)", r.measures.len() - 60));
                }
            }
            o.push(OUTPUT_NOTE.into());
            ok(o.join("\n"))
        }

        "align_captions" => {
            if p.captions.is_empty() {
                return err("자막이 없습니다");
            }
            let (from, to) = (d("from").unwrap_or(0.0), d("to").unwrap_or(f64::INFINITY));
            let r = sync_report(app, from, to);
            let mut mode = input.get("mode").and_then(Value::as_str).unwrap_or("auto");
            if mode == "auto" {
                mode = if r.consistent() { "shift" } else { "snap" };
            }
            let st = app.state::<AppState>();
            if mode == "shift" {
                let Some(sec) = d("seconds").or(if r.measures.is_empty() { None } else { Some(r.median) }).filter(|s| s.abs() > 0.005) else {
                    return ok(format!("옮길 만큼의 차이가 없습니다 (잰 자막 {}개)", r.measures.len()));
                };
                st.editor.lock().unwrap().apply(|q| q.shift_captions(sec, from, to));
                emit_state(app);
                return ok(format!("자막을 {:.2}초 {} ({})", sec.abs(), if sec > 0.0 { "늦춤" } else { "앞당김" }, if d("seconds").is_none() { "측정한 중앙값" } else { "지정한 값" }));
            }
            if r.measures.is_empty() {
                return err("잴 수 있는 자막이 없어 맞추지 못했습니다");
            }
            st.editor.lock().unwrap().apply(|q| q.snap_captions(&r.measures));
            emit_state(app);
            let avg = r.measures.iter().map(|m| m.offset()).sum::<f64>() / r.measures.len() as f64;
            ok(format!("자막 {}개의 시작을 실제 말 시작에 맞춤 (평균 {avg:+.2}초). 잴 수 없던 {}개는 그대로", r.measures.len(), r.skipped))
        }

        "export_range" => {
            let (Some(st), Some(en)) = (d("start"), d("end")) else { return err("start < end 가 필요합니다") };
            let total = p.duration();
            if en - st <= 0.1 || st >= total {
                return err("구간이 올바르지 않습니다");
            }
            let en = en.min(total);
            let dir = dirs_videos().join("EasyCut 확인용");
            let _ = std::fs::create_dir_all(&dir);
            let stamp = chrono::Local::now().format("%H%M%S");
            let path = dir.join(format!("구간 {st:.1}-{en:.1}초 {stamp}.mp4"));
            let opts = crate::export::Options { path: path.to_string_lossy().to_string(), height: 720, burn_captions: input.get("captions").and_then(Value::as_bool).unwrap_or(true), format: "mp4".into(), range: Some((st, en)) };
            if let Err(e) = crate::export::export(&p, &opts, |_| {}, || false) {
                return err(&format!("내보내기 실패: {e}"));
            }
            let open = input.get("open").and_then(Value::as_bool).unwrap_or(true);
            if open {
                let _ = if cfg!(windows) { std::process::Command::new("explorer.exe").arg(&path).spawn() } else { std::process::Command::new("/usr/bin/open").arg(&path).spawn() };
            }
            ok(format!("{st:.2}~{en:.2}초를 내보냄: {}{}", path.display(), if open { " (기본 플레이어로 열었습니다. 사용자에게 내보낸 영상에서도 자막이 어긋나는지 물어보세요)" } else { "" }))
        }

        _ => None,
    }
}

/// 사용자 동영상 폴더 (없으면 홈)
fn dirs_videos() -> PathBuf {
    let home = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")).map(PathBuf::from).unwrap_or_else(std::env::temp_dir);
    let v = home.join(if cfg!(windows) { "Videos" } else { "Movies" });
    if v.is_dir() { v } else { home }
}
