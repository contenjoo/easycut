use super::*;
use easycut_core::{Caption, MediaAsset, Word};
use std::path::{Path, PathBuf};
use std::process::Command;

#[test]
fn caption_ass_highlights_the_spoken_word() {
    let mut p = Project::default();
    p.captions.push(Caption::new(0.0, 2.0, "안녕 하세요"));
    audio_polish::set_word_highlight(&mut p.caption_style, true);
    let ass = build_ass(&p, 1920, 1080, true).unwrap();
    // 첫 어절 강조 → 1초에 둘째 어절 강조 (글자 수 비율 2:3 → 0.8초)
    assert!(ass.contains("{\\1c&H1AD6FF&}안녕{\\1c&HFFFFFF&} 하세요"), "{ass}");
    assert!(ass.contains("안녕 {\\1c&H1AD6FF&}하세요{\\1c&HFFFFFF&}"), "{ass}");
    assert!(ass.contains("0:00:00.80"), "{ass}");
    audio_polish::set_word_highlight(&mut p.caption_style, false);
    assert!(!build_ass(&p, 1920, 1080, true).unwrap().contains("\\1c"));
}

fn ffmpeg() -> Option<PathBuf> {
    std::env::var_os("EASYCUT_EFFECT_FFMPEG").map(PathBuf::from)
}

fn make(ff: &Path, out: &Path, args: &[&str]) {
    let o = Command::new(ff).args(["-y", "-v", "error"]).args(args).arg(out).output().unwrap();
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
}

fn rms(ff: &Path, path: &Path, a: f64, b: f64) -> f64 {
    let o = Command::new(ff)
        .args(["-nostdin", "-hide_banner", "-nostats", "-i"])
        .arg(path)
        .args(["-vn", "-af", &format!("atrim={a}:{b},astats=measure_perchannel=none"), "-f", "null", "-"])
        .output()
        .unwrap();
    String::from_utf8_lossy(&o.stderr)
        .lines()
        .find_map(|l| l.split("RMS level dB:").nth(1).and_then(|v| v.trim().parse().ok()))
        .unwrap_or(f64::NAN)
}

fn export_m4a(p: &Project, out: &Path) {
    export(p, &Options { path: out.to_string_lossy().into_owned(), height: 0, burn_captions: false, format: "m4a".into(), range: None }, |_| {}, || false)
        .unwrap_or_else(|e| panic!("{e}"));
}

fn asset(path: &Path, kind: MediaKind, dur: f64) -> MediaAsset {
    MediaAsset { path: path.to_string_lossy().into_owned(), kind, duration: dur, has_audio: true, ..Default::default() }
}

/// 맥과 같은 기준: 소음 -6 dB 이상 감소, -14 LUFS ±1.5, 말할 때 배경음악 -12 dB ±2
#[test]
fn real_ffmpeg_audio_polish() {
    let Some(ff) = ffmpeg() else {
        eprintln!("set EASYCUT_EFFECT_FFMPEG for real audio verification");
        return;
    };
    let dir = std::env::temp_dir().join(format!("easycut-audio-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();

    let noisy = dir.join("noisy.wav");
    make(&ff, &noisy, &["-f", "lavfi", "-i", "anoisesrc=d=4:c=pink:a=0.08:r=48000", "-f", "lavfi", "-i", "sine=f=330:d=4:r=48000",
        "-filter_complex", "[1]volume=0.4,adelay=1000|1000[s];[0][s]amix=inputs=2:normalize=0", "-ac", "1"]);
    let mut p = Project::default();
    let a = asset(&noisy, MediaKind::Audio, 5.0);
    p.assets.push(a.clone());
    p.insert(&a, 0, 0.0, 5.0);
    audio_polish::set_denoise(&mut p.tracks[0].clips[0], true);
    let out = dir.join("denoised.m4a");
    export_m4a(&p, &out);
    let (before, after) = (rms(&ff, &noisy, 0.2, 0.9), rms(&ff, &out, 0.2, 0.9));
    assert!(after < before - 6.0, "denoise {before} -> {after}");
    let (tb, ta) = (rms(&ff, &noisy, 2.0, 3.0), rms(&ff, &out, 2.0, 3.0));
    assert!((tb - ta).abs() < 4.0, "tone {tb} -> {ta}");

    let quiet = dir.join("quiet.m4a");
    make(&ff, &quiet, &["-f", "lavfi", "-i", "sine=f=440:d=5:r=48000", "-af", "volume=0.02", "-c:a", "aac"]);
    let mut q = Project::default();
    let a = asset(&quiet, MediaKind::Audio, 5.0);
    q.assets.push(a.clone());
    q.insert(&a, 0, 0.0, 5.0);
    audio_polish::set_loudness_target(&mut q, Some(-14.0));
    let out = dir.join("loud.m4a");
    export_m4a(&q, &out);
    let lufs = measure_loudness(&ff, &out.to_string_lossy()).unwrap();
    assert!((lufs + 14.0).abs() < 1.5, "loudness {lufs}");

    let voice = dir.join("voice.m4a");
    make(&ff, &voice, &["-f", "lavfi", "-i", "anullsrc=r=48000:cl=mono", "-t", "5", "-c:a", "aac"]);
    let music = dir.join("music.m4a");
    make(&ff, &music, &["-f", "lavfi", "-i", "sine=f=220:d=5:r=48000", "-af", "volume=0.3", "-c:a", "aac"]);
    let mut d = Project::default();
    let mut v = asset(&voice, MediaKind::Audio, 5.0);
    v.words = Some(vec![
        Word { text: "안녕".into(), start: 1.0, end: 1.4, ..Default::default() },
        Word { text: "하세요".into(), start: 1.5, end: 2.0, ..Default::default() },
    ]);
    let m = asset(&music, MediaKind::Audio, 5.0);
    d.assets = vec![v.clone(), m.clone()];
    d.insert(&v, 0, 0.0, 5.0);
    d.insert(&m, 1, 0.0, 5.0);
    let off = dir.join("duck-off.m4a");
    export_m4a(&d, &off);
    audio_polish::set_auto_duck(&mut d, true);
    let on = dir.join("duck-on.m4a");
    export_m4a(&d, &on);
    let drop = rms(&ff, &off, 1.3, 1.8) - rms(&ff, &on, 1.3, 1.8);
    assert!((drop - 12.0).abs() < 2.0, "duck drop {drop}");
    let same = rms(&ff, &off, 3.5, 4.5) - rms(&ff, &on, 3.5, 4.5);
    assert!(same.abs() < 0.6, "outside speech {same}");
    let _ = std::fs::remove_dir_all(&dir);
}
