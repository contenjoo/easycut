//! 미디어 정보 읽기와 오디오 추출 (ffprobe / ffmpeg)
use crate::tools;
use easycut_core::{Id, MediaAsset, MediaKind};
use std::io::Read;
use std::path::Path;
use std::process::Stdio;

const IMAGE_EXT: &[&str] = &["png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "bmp", "webp"];
const AUDIO_EXT: &[&str] = &["mp3", "wav", "m4a", "aac", "aif", "aiff", "flac", "ogg", "opus", "wma"];

pub fn probe(path: &Path) -> Result<MediaAsset, String> {
    let ffprobe = tools::find_tool("ffprobe").ok_or("ffprobe를 찾을 수 없습니다. EasyCut을 다시 설치해 주세요.")?;
    let out = tools::command(&ffprobe)
        .args(["-v", "error", "-show_entries", "stream=codec_type,width,height:format=duration", "-of", "json"])
        .arg(path)
        .output()
        .map_err(|e| format!("ffprobe 실행 실패: {e}"))?;
    if !out.status.success() {
        return Err(format!("지원하지 않는 파일 형식입니다: {}", name_of(path)));
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).map_err(|e| e.to_string())?;
    let streams = v["streams"].as_array().cloned().unwrap_or_default();
    let video = streams.iter().find(|s| s["codec_type"] == "video");
    let has_audio = streams.iter().any(|s| s["codec_type"] == "audio");
    let duration = v["format"]["duration"].as_str().and_then(|d| d.parse::<f64>().ok()).unwrap_or(0.0);
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    let kind = if IMAGE_EXT.contains(&ext.as_str()) {
        MediaKind::Image
    } else if video.is_some() && duration > 0.0 && !AUDIO_EXT.contains(&ext.as_str()) {
        MediaKind::Video
    } else if has_audio {
        MediaKind::Audio
    } else if video.is_some() {
        MediaKind::Image
    } else {
        return Err(format!("영상/오디오 트랙을 찾을 수 없습니다: {}", name_of(path)));
    };
    Ok(MediaAsset {
        id: Id::new(),
        path: path.to_string_lossy().to_string(),
        name: name_of(path),
        kind,
        duration: if kind == MediaKind::Image { 0.0 } else { duration },
        width: video.and_then(|s| s["width"].as_f64()).unwrap_or(0.0),
        height: video.and_then(|s| s["height"].as_f64()).unwrap_or(0.0),
        has_audio: has_audio && kind != MediaKind::Image,
        ..Default::default()
    })
}

pub fn name_of(path: &Path) -> String {
    path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default()
}

/// 모노 16bit PCM으로 오디오를 꺼낸다 (음성 인식 16kHz, 무음 분석 8kHz)
pub fn pcm(path: &Path, rate: u32) -> Result<Vec<i16>, String> {
    let ffmpeg = tools::find_tool("ffmpeg").ok_or("ffmpeg를 찾을 수 없습니다. EasyCut을 다시 설치해 주세요.")?;
    let mut child = tools::command(&ffmpeg)
        .args(["-v", "error", "-nostdin", "-i"])
        .arg(path)
        .args(["-vn", "-ac", "1", "-ar", &rate.to_string(), "-f", "s16le", "-"])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("ffmpeg 실행 실패: {e}"))?;
    let mut bytes = vec![];
    child.stdout.take().unwrap().read_to_end(&mut bytes).map_err(|e| e.to_string())?;
    let _ = child.wait();
    if bytes.is_empty() {
        return Err("오디오를 읽을 수 없습니다".into());
    }
    Ok(bytes.chunks_exact(2).map(|b| i16::from_le_bytes([b[0], b[1]])).collect())
}

/// 16kHz 모노 WAV 파일 쓰기
pub fn write_wav(path: &Path, samples: &[i16]) -> std::io::Result<()> {
    let data_len = (samples.len() * 2) as u32;
    let mut b = Vec::with_capacity(44 + data_len as usize);
    b.extend_from_slice(b"RIFF");
    b.extend_from_slice(&(36 + data_len).to_le_bytes());
    b.extend_from_slice(b"WAVEfmt ");
    b.extend_from_slice(&16u32.to_le_bytes());
    b.extend_from_slice(&1u16.to_le_bytes());
    b.extend_from_slice(&1u16.to_le_bytes());
    b.extend_from_slice(&16000u32.to_le_bytes());
    b.extend_from_slice(&32000u32.to_le_bytes());
    b.extend_from_slice(&2u16.to_le_bytes());
    b.extend_from_slice(&16u16.to_le_bytes());
    b.extend_from_slice(b"data");
    b.extend_from_slice(&data_len.to_le_bytes());
    for s in samples {
        b.extend_from_slice(&s.to_le_bytes());
    }
    std::fs::write(path, b)
}
