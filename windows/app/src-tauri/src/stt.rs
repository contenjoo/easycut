//! Whisper 음성 인식 (whisper-cli) 과 모델 내려받기
use crate::{media, tools};
use easycut_core::whisper::{clamp_to_duration, fix_overlaps, parse_progress, parse_whisper_full, whisper_chunks, MODELS};
use easycut_core::Word;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::Stdio;

pub fn model_path() -> PathBuf {
    tools::app_data().join("models").join(MODELS[0].file_name())
}

pub fn model_ready() -> bool {
    std::fs::metadata(model_path()).map(|m| m.len() > 100_000_000).unwrap_or(false)
}

/// 모델 받기 (curl: 윈도우 10 이상·맥에 기본으로 있음). progress(0~1)
pub fn download_model(progress: impl Fn(f64)) -> Result<(), String> {
    let dest = model_path();
    std::fs::create_dir_all(dest.parent().unwrap()).map_err(|e| e.to_string())?;
    let tmp = dest.with_extension("part");
    let _ = std::fs::remove_file(&tmp);
    let curl = if cfg!(windows) { PathBuf::from("curl.exe") } else { PathBuf::from("/usr/bin/curl") };
    let mut child = tools::command(&curl)
        .args(["-L", "--fail", "-s", "-o"])
        .arg(&tmp)
        .arg(MODELS[0].url())
        .spawn()
        .map_err(|e| format!("모델 다운로드를 시작하지 못했습니다: {e}"))?;
    let expected = 574_000_000f64;
    loop {
        if let Some(status) = child.try_wait().map_err(|e| e.to_string())? {
            if !status.success() {
                return Err("모델 다운로드 실패: 인터넷 연결을 확인하세요.".into());
            }
            break;
        }
        let got = std::fs::metadata(&tmp).map(|m| m.len() as f64).unwrap_or(0.0);
        progress((got / expected).min(0.99));
        std::thread::sleep(std::time::Duration::from_millis(400));
    }
    std::fs::rename(&tmp, &dest).map_err(|e| e.to_string())?;
    progress(1.0);
    Ok(())
}

/// 파일 하나를 10분 안팎으로 나눠 인식. 조각이 끝날 때마다 partial로 지금까지의 단어를 넘긴다.
pub fn transcribe(
    path: &Path,
    language: &str,
    progress: impl Fn(f64, String),
    partial: impl Fn(&[Word]),
    cancel: impl Fn() -> bool,
) -> Result<Vec<Word>, String> {
    let whisper = tools::find_tool("whisper-cli").ok_or("Whisper 엔진을 찾을 수 없습니다. EasyCut을 다시 설치해 주세요.")?;
    if !model_ready() {
        return Err("Whisper 모델이 없습니다. 먼저 모델을 받아 주세요.".into());
    }
    progress(0.0, "오디오 추출 중…".into());
    let samples = media::pcm(path, 16000)?;
    let chunks = whisper_chunks(&samples);
    let work = tools::temp_dir().join(format!("stt-{}", std::process::id()));
    let _ = std::fs::create_dir_all(&work);
    let mut all: Vec<Word> = vec![];
    let n = chunks.len().max(1);
    for (i, r) in chunks.iter().enumerate() {
        if cancel() {
            break;
        }
        let offset = r.start as f64 / 16000.0;
        let wav = work.join(format!("c{i}.wav"));
        media::write_wav(&wav, &samples[r.clone()]).map_err(|e| e.to_string())?;
        let out_base = work.join(format!("c{i}"));
        let mut child = tools::command(&whisper)
            .arg("-m").arg(model_path())
            .args(["-l", language, "-ojf", "-pp", "--dtw", MODELS[0].dtw, "-nfa", "-mc", "0", "-of"])
            .arg(&out_base)
            .arg("-f").arg(&wav)
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("Whisper 실행 실패: {e}"))?;
        let stderr = child.stderr.take().unwrap();
        let mut tail = String::new();
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            if let Some(p) = parse_progress(&line) {
                progress((i as f64 + p) / n as f64, format!("Whisper 인식 중 ({}/{})", i + 1, n));
            }
            if cancel() {
                let _ = child.kill();
            }
            tail = line;
        }
        let status = child.wait().map_err(|e| e.to_string())?;
        if cancel() {
            break;
        }
        if !status.success() {
            return Err(format!("Whisper 실행 실패\n{tail}"));
        }
        let data = std::fs::read(out_base.with_extension("json")).unwrap_or_default();
        let mut words = parse_whisper_full(&data);
        clamp_to_duration(&mut words, r.len() as f64 / 16000.0);
        for mut w in words {
            w.start += offset;
            w.end += offset;
            all.push(w);
        }
        all = fix_overlaps(all);
        partial(&all);
    }
    let _ = std::fs::remove_dir_all(&work);
    Ok(all)
}
