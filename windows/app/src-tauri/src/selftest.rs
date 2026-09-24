//! `easycut-windows --selftest <폴더>`: 화면 없이 가져오기 → 편집 → 무음 컷 → 자막 → 내보내기를 검사한다.
//! GitHub Actions 윈도우 러너에서도 돌려 설치본과 같은 도구로 동작하는지 확인한다.
use crate::{export, media, stt, tools};
use easycut_core::silence::{auto_threshold, loudness, SilenceSettings};
use easycut_core::{Caption, MediaKind, Project};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

struct Checker {
    failed: usize,
}

impl Checker {
    fn check(&mut self, ok: bool, msg: &str) {
        println!("  {} {msg}", if ok { "OK  " } else { "FAIL" });
        if !ok {
            self.failed += 1;
        }
    }
}

fn run_ffmpeg(args: &[&str]) -> Result<(), String> {
    let ffmpeg = tools::find_tool("ffmpeg").ok_or("ffmpeg not found")?;
    let out = tools::command(&ffmpeg).args(args).output().map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(())
    } else {
        Err(String::from_utf8_lossy(&out.stderr).lines().last().unwrap_or("").to_string())
    }
}

/// 10초 테스트 영상: 0~3초 소리, 3~5초 무음, 5~10초 소리
fn make_media(dir: &Path) -> Result<PathBuf, String> {
    let out = dir.join("sample.mp4");
    run_ffmpeg(&[
        "-y", "-v", "error",
        "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=10",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=10",
        "-filter_complex", "[1:a]volume='if(between(t,3,5),0,0.5)':eval=frame[a]",
        "-map", "0:v", "-map", "[a]", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
        out.to_str().unwrap(),
    ])?;
    Ok(out)
}

pub fn run(dir: &Path) -> i32 {
    let _ = std::fs::create_dir_all(dir);
    let mut c = Checker { failed: 0 };
    println!("EasyCut for Windows self-test ({})", std::env::consts::OS);
    println!("1) tools");
    for t in ["ffmpeg", "ffprobe", "whisper-cli"] {
        let p = tools::find_tool(t);
        c.check(p.is_some() || t == "whisper-cli", &format!("{t}: {}", p.map(|p| p.display().to_string()).unwrap_or("-".into())));
    }

    c.check(crate::update::is_newer("0.2.0", "0.1.9") && !crate::update::is_newer("0.1.0", "0.1.0"), "update version compare");
    println!("2) import");
    let sample = match make_media(dir) {
        Ok(p) => p,
        Err(e) => {
            c.check(false, &format!("test media: {e}"));
            return 1;
        }
    };
    let asset = match media::probe(&sample) {
        Ok(a) => a,
        Err(e) => {
            c.check(false, &format!("probe: {e}"));
            return 1;
        }
    };
    c.check(asset.kind == MediaKind::Video && (asset.duration - 10.0).abs() < 0.2 && asset.width == 1280.0 && asset.has_audio,
        &format!("probe: {:?} {:.2}s {}x{} audio={}", asset.kind, asset.duration, asset.width, asset.height, asset.has_audio));

    println!("3) edit");
    let mut p = Project::default();
    p.canvas_width = 1280.0;
    p.canvas_height = 720.0;
    p.assets.push(asset.clone());
    let id = p.insert(&asset, 0, 0.0, 5.0);
    p.normalize();
    let right = p.split(id, 8.0);
    c.check(right.is_some() && p.tracks[0].clips.len() == 2, "split at 8s");
    if let Some(r) = right {
        p.delete_clips(&HashSet::from([r]), true);
    }
    c.check((p.duration() - 8.0).abs() < 1e-6, &format!("delete right part → {:.2}s", p.duration()));

    println!("4) silence cut");
    match media::pcm(&sample, 8000) {
        Ok(s) => {
            let db = loudness(&s);
            let mut settings = SilenceSettings { threshold: auto_threshold(&db), ..Default::default() };
            settings.min_silence = 0.6;
            let map = HashMap::from([(asset.id, db)]);
            let ranges = p.audio_silence_ranges(&map, &settings);
            let removed: f64 = ranges.iter().map(|r| r.len()).sum();
            c.check(ranges.len() == 1 && (removed - 1.76).abs() < 0.3, &format!("found {} silence(s), {:.2}s", ranges.len(), removed));
            p.ripple_delete_ranges(&ranges);
            c.check((p.duration() - (8.0 - removed)).abs() < 0.05, &format!("after cut {:.2}s", p.duration()));
        }
        Err(e) => c.check(false, &format!("pcm: {e}")),
    }

    println!("5) captions + text");
    p.captions = vec![Caption::new(0.5, 2.0, "안녕하세요 EasyCut"), Caption::new(2.5, 4.0, "Windows test")];
    p.show_captions = true;
    p.insert_text("제목", 1, 1.0, 2.0);
    p.normalize();
    let json = p.to_json().unwrap_or_default();
    let back = Project::from_json(&json);
    c.check(back.map(|b| b == p).unwrap_or(false), &format!("project JSON roundtrip ({} bytes)", json.len()));

    println!("6) export");
    if let Some(ff) = tools::find_tool("ffmpeg") {
        let subs = export::has_subtitles_filter(&ff);
        if subs { c.check(true, "ffmpeg has libass (captions burn in)") } else { println!("  note: this ffmpeg has no libass → captions/text not burned in") }
    }
    let out = dir.join("export.mp4");
    let opts = export::Options { path: out.to_string_lossy().to_string(), height: 720, burn_captions: true };
    let t0 = std::time::Instant::now();
    match export::export(&p, &opts, |_| {}, || false) {
        Ok(()) => match media::probe(&out) {
            Ok(a) => {
                c.check((a.duration - p.duration()).abs() < 0.25, &format!("export {:.2}s (project {:.2}s) in {:.1}s", a.duration, p.duration(), t0.elapsed().as_secs_f64()));
                c.check(a.width == 1280.0 && a.height == 720.0 && a.has_audio, &format!("output {}x{} audio={}", a.width, a.height, a.has_audio));
            }
            Err(e) => c.check(false, &format!("probe export: {e}")),
        },
        Err(e) => c.check(false, &e),
    }

    println!("7) speech recognition");
    if stt::model_ready() && tools::find_tool("whisper-cli").is_some() {
        match stt::transcribe(&sample, "en", |_, _| {}, |_| {}, || false) {
            Ok(w) => c.check(true, &format!("whisper ran ({} words on a sine tone)", w.len())),
            Err(e) => c.check(false, &format!("whisper: {e}")),
        }
    } else {
        println!("  skip (no model/engine)");
    }

    println!("\n{}", if c.failed == 0 { "ALL PASSED".to_string() } else { format!("{} FAILED", c.failed) });
    if c.failed == 0 { 0 } else { 1 }
}
